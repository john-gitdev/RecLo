#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/pm/device.h>

#include "button.h"
#include "codec.h"
#include "config.h"
#include "led.h"
#include "mic.h"
#include "transport.h"
#include "wdog_facade.h"

#include "reclo_recorder.h"
#include "reclo_transfer.h"

LOG_MODULE_REGISTER(main, CONFIG_LOG_DEFAULT_LEVEL);

#define BOOT_BLINK_MS  600
#define BOOT_PAUSE_MS  200

/* Shared with transport.c */
bool is_connected = false;
extern bool is_off;
extern bool usb_charge;

/* ── Boot sequence ───────────────────────────────────────────────────────────*/

static void print_reset_reason(void)
{
    uint32_t reas = NRF_POWER->RESETREAS;
    NRF_POWER->RESETREAS = reas;

    if      (reas & POWER_RESETREAS_DOG_Msk)      printk("Reset: watchdog\n");
    else if (reas & POWER_RESETREAS_RESETPIN_Msk)  printk("Reset: pin\n");
    else if (reas & POWER_RESETREAS_SREQ_Msk)      printk("Reset: soft\n");
    else if (reas & POWER_RESETREAS_LOCKUP_Msk)    printk("Reset: lockup\n");
    else if (reas)                                  printk("Reset: 0x%08X\n", reas);
    else                                            printk("Reset: power-on\n");
}

static void boot_led_sequence(void)
{
    /* R → G → B → all on → all off */
    set_led_red(true);   k_msleep(BOOT_BLINK_MS); set_led_red(false);   k_msleep(BOOT_PAUSE_MS);
    set_led_green(true); k_msleep(BOOT_BLINK_MS); set_led_green(false); k_msleep(BOOT_PAUSE_MS);
    set_led_blue(true);  k_msleep(BOOT_BLINK_MS); set_led_blue(false);  k_msleep(BOOT_PAUSE_MS);
    set_led_red(true); set_led_green(true); set_led_blue(true);
    k_msleep(BOOT_BLINK_MS);
    set_led_red(false); set_led_green(false); set_led_blue(false);
}

/* ── LED state ───────────────────────────────────────────────────────────────
 *
 * RecLo LED meanings (checked every 500 ms in main loop):
 *   Blue steady  — recording to flash (always, while powered and not off)
 *   Green blink  — BLE connected / syncing with phone
 *   Green steady — USB charging
 *   All off      — device powered off (button hold)
 */
static bool _charging_led = false;

static void update_led_state(void)
{
    if (is_off) {
        set_led_red(false);
        set_led_blue(false);
        set_led_green(false);
        return;
    }

    /* Green: charging blink takes priority over connected blink */
    if (usb_charge) {
        _charging_led = !_charging_led;
        set_led_green(_charging_led);
    } else if (is_connected) {
        /* Slow blink to indicate active sync */
        static bool _sync_led = false;
        _sync_led = !_sync_led;
        set_led_green(_sync_led);
    } else {
        set_led_green(false);
    }

    /* Blue: always on while recording */
    set_led_blue(true);
    set_led_red(false);
}

/* ── Mic → codec passthrough ─────────────────────────────────────────────────*/

static void mic_handler(int16_t *buffer)
{
    codec_receive_pcm(buffer, MIC_BUFFER_SAMPLES);
}

/* ── main ────────────────────────────────────────────────────────────────────*/

int main(void)
{
    int err;

    print_reset_reason();

    /* Enable DC/DC converters for lower power draw */
    NRF_POWER->DCDCEN  = 1;
    NRF_POWER->DCDCEN0 = 1;

    LOG_INF("RecLo booting — fw %s hw %s",
            CONFIG_BT_DIS_FW_REV_STR, CONFIG_BT_DIS_HW_REV_STR);

    /* Suspend unused QSPI flash to save power */
    const struct device *qspi = DEVICE_DT_GET(DT_NODELABEL(p25q16h));
    if (device_is_ready(qspi)) {
        pm_device_action_run(qspi, PM_DEVICE_ACTION_SUSPEND);
    }

    /* LEDs */
    err = led_start();
    if (err) { LOG_ERR("LED init failed (%d)", err); return err; }
    boot_led_sequence();

    /* Watchdog */
    err = watchdog_init();
    if (err) { LOG_WRN("Watchdog init failed (%d), continuing", err); }

    /* Battery */
#ifdef CONFIG_OMI_ENABLE_BATTERY
    err = battery_init();
    if (err) { LOG_ERR("Battery init failed (%d)", err); return err; }
    battery_charge_start();
    LOG_INF("Battery ready");
#endif

    /* Button */
#ifdef CONFIG_OMI_ENABLE_BUTTON
    err = button_init();
    if (err) { LOG_ERR("Button init failed (%d)", err); return err; }
    activate_button_work();
    LOG_INF("Button ready");
#endif

    /* BLE transport — starts advertising and GATT server.
     * RecLo GATT service (reclo_transfer) is registered automatically
     * via BT_GATT_SERVICE_DEFINE at link time, alongside Omi's services. */
    err = transport_start();
    if (err) { LOG_ERR("Transport failed (%d)", err); return err; }
    LOG_INF("Transport ready");

    /* RecLo transfer service — spawns upload thread.
     * BT connection callbacks registered automatically via BT_CONN_CB_DEFINE. */
    err = reclo_transfer_init();
    if (err) { LOG_ERR("RecLo transfer init failed (%d)", err); return err; }

    /* Codec — start without a callback; recorder will set it below */
    err = codec_start();
    if (err) { LOG_ERR("Codec start failed (%d)", err); return err; }
    LOG_INF("Codec ready");

    /* RecLo recorder — takes ownership of the codec callback.
     * All encoded frames go to flash; live BLE streaming is not used. */
    err = reclo_recorder_init();
    if (err) { LOG_ERR("Recorder init failed (%d)", err); return err; }
    reclo_recorder_start();
    LOG_INF("Recorder started — %d chunk(s) on flash",
            reclo_recorder_chunk_count());

    /* Microphone */
    set_mic_callback(mic_handler);
    err = mic_start();
    if (err) { LOG_ERR("Mic start failed (%d)", err); return err; }
    LOG_INF("Mic ready");

    LOG_INF("RecLo ready");
    set_led_blue(true);
    k_msleep(500);
    set_led_blue(false);

    /* Main loop */
    while (1) {
        watchdog_feed();
        update_led_state();
        k_msleep(500);
    }

    return 0;
}
