#include "button.h"

#include <zephyr/drivers/gpio.h>
#include <zephyr/input/input.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/pm/device_runtime.h>
#include <zephyr/sys/poweroff.h>

#include "haptic.h"
#include "led.h"
#include "mic.h"
#include "speaker.h"
#include "transport.h"
#include "wdog_facade.h"
#ifdef CONFIG_OMI_ENABLE_WIFI
#include "wifi.h"
#endif

#include "imu.h"
#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
#include "sd_card.h"
#endif

#include "reclo_recorder.h"

LOG_MODULE_REGISTER(button, CONFIG_LOG_DEFAULT_LEVEL);

extern bool is_off;
extern bool led_user_off;   /* defined in main.c; checked by set_led_state() */

static const struct device *const buttons = DEVICE_DT_GET(DT_ALIAS(buttons));
static const struct gpio_dt_spec usr_btn = GPIO_DT_SPEC_GET_OR(DT_NODELABEL(usr_btn), gpios, {0});

static bool was_pressed = false;

/* ── FSM ─────────────────────────────────────────────────────────────────────
 *
 *   Press release                  → do nothing
 *   Press hold ≥1s release         → toggle mute (short vibe=mute, long vibe=unmute)
 *   Press release, press release   → toggle LED on/off
 *   Press release, press hold ≥3s  → long vibe + power off
 */

#define BTN_CHECK_INTERVAL_MS  40

#define TAP_MAX_TICKS     (300  / BTN_CHECK_INTERVAL_MS)   /*  7 — max ticks for a short tap   */
#define MUTE_HOLD_TICKS   (1000 / BTN_CHECK_INTERVAL_MS)   /* 25 — hold duration for mute      */
#define DTAP_WINDOW_TICKS (600  / BTN_CHECK_INTERVAL_MS)   /* 15 — wait window after first tap */
#define POWER_OFF_TICKS   (3000 / BTN_CHECK_INTERVAL_MS)   /* 75 — second hold for power off   */

#define HAPTIC_SHORT_MS   100
#define HAPTIC_LONG_MS    400

typedef enum {
    BTN_IDLE,       /* waiting for first press                         */
    BTN_HOLD_1,     /* first press held (no prior tap in window)       */
    BTN_AFTER_TAP,  /* first tap released, watching for second press   */
    BTN_HOLD_2,     /* second press held (prior-tap context)           */
} BtnFsm;

static BtnFsm   _fsm         = BTN_IDLE;
static uint32_t _press_ticks = 0;
static uint32_t _idle_ticks  = 0;
static bool     _muted       = false;

/* ── FSM tick ────────────────────────────────────────────────────────────────*/

/* Forward declaration so K_WORK_DELAYABLE_DEFINE can reference the handler */
void check_button_level(struct k_work *work_item);
K_WORK_DELAYABLE_DEFINE(button_work, check_button_level);

void check_button_level(struct k_work *work_item)
{
    ARG_UNUSED(work_item);

    bool pressed = was_pressed;

    switch (_fsm) {

    case BTN_IDLE:
        if (pressed) {
            _fsm = BTN_HOLD_1;
            _press_ticks = 0;
        }
        break;

    case BTN_HOLD_1:
        if (!pressed) {
            if (_press_ticks < TAP_MAX_TICKS) {
                _fsm = BTN_AFTER_TAP;
                _idle_ticks = 0;
            } else {
                _fsm = BTN_IDLE;
            }
        } else {
            _press_ticks++;
            if (_press_ticks == MUTE_HOLD_TICKS) {
                if (_muted) {
                    play_haptic_milli(HAPTIC_LONG_MS);
                    reclo_recorder_start();
                    _muted = false;
                    LOG_INF("Button: unmuted");
                } else {
                    play_haptic_milli(HAPTIC_SHORT_MS);
                    reclo_recorder_stop();
                    _muted = true;
                    LOG_INF("Button: muted");
                }
            }
        }
        break;

    case BTN_AFTER_TAP:
        _idle_ticks++;
        if (pressed) {
            _fsm = BTN_HOLD_2;
            _press_ticks = 0;
        } else if (_idle_ticks >= DTAP_WINDOW_TICKS) {
            _fsm = BTN_IDLE;
        }
        break;

    case BTN_HOLD_2:
        if (!pressed) {
            if (_press_ticks < TAP_MAX_TICKS) {
                led_user_off = !led_user_off;
                LOG_INF("Button: LED %s", led_user_off ? "off" : "on");
            }
            _fsm = BTN_IDLE;
        } else {
            _press_ticks++;
            if (_press_ticks == POWER_OFF_TICKS) {
                turnoff_all();
            }
        }
        break;
    }

    k_work_reschedule(&button_work, K_MSEC(BTN_CHECK_INTERVAL_MS));
}

/* ── GPIO callback ───────────────────────────────────────────────────────────*/

static struct gpio_callback button_cb_data;

static void button_gpio_callback(const struct device *dev, struct gpio_callback *cb, uint32_t pins)
{
    ARG_UNUSED(dev); ARG_UNUSED(cb); ARG_UNUSED(pins);
    was_pressed = (gpio_pin_get_dt(&usr_btn) == 1);
}

/* ── Init ────────────────────────────────────────────────────────────────────*/

static int button_regist_callback(void)
{
    int ret;

    ret = gpio_pin_configure_dt(&usr_btn, GPIO_INPUT);
    if (ret < 0) {
        LOG_ERR("Failed to configure button GPIO (%d)", ret);
        return ret;
    }

    ret = gpio_pin_interrupt_configure_dt(&usr_btn, GPIO_INT_EDGE_BOTH);
    if (ret < 0) {
        LOG_ERR("Failed to configure button interrupt (%d)", ret);
        return ret;
    }

    gpio_init_callback(&button_cb_data, button_gpio_callback, BIT(usr_btn.pin));
    gpio_add_callback(usr_btn.port, &button_cb_data);

    return 0;
}

int button_init(void)
{
    int ret;

    if (!device_is_ready(buttons)) {
        LOG_ERR("Buttons device not ready");
        return -ENODEV;
    }

    ret = pm_device_runtime_get(buttons);
    if (ret < 0) {
        LOG_ERR("Failed to enable buttons device (%d)", ret);
        return ret;
    }

    return button_regist_callback();
}

void activate_button_work(void)
{
    k_work_schedule(&button_work, K_MSEC(BTN_CHECK_INTERVAL_MS));
}

void register_button_service(void) { /* no-op: BLE button service removed */ }

/* ── Legacy FSM API ──────────────────────────────────────────────────────────*/

static FSM_STATE_T current_button_state = IDLE;

FSM_STATE_T get_current_button_state(void) { return current_button_state; }
void force_button_state(FSM_STATE_T state) { current_button_state = state; }

/* ── Power off ───────────────────────────────────────────────────────────────*/

void turnoff_all(void)
{
    int rc;

    led_off();
    is_off = true;

#ifdef CONFIG_OMI_ENABLE_HAPTIC
    play_haptic_milli(1000);
    k_msleep(200);
    haptic_off();
#endif

    k_msleep(1000);

    transport_off();
    k_msleep(300);

    mic_off();
    k_msleep(100);

#ifdef CONFIG_OMI_ENABLE_SPEAKER
    speaker_off();
    k_msleep(100);
#endif

#ifdef CONFIG_OMI_ENABLE_ACCELEROMETER
    accel_off();
    k_msleep(100);
#endif

    if (is_sd_on()) {
        app_sd_off();
    }
    k_msleep(300);

#ifdef CONFIG_OMI_ENABLE_BUTTON
    pm_device_runtime_put(buttons);
    k_msleep(100);
#endif

#ifdef CONFIG_OMI_ENABLE_USB
    NRF_USBD->INTENCLR = 0xFFFFFFFF;
#endif

    LOG_INF("System powering off");

    rc = gpio_pin_configure_dt(&usr_btn, GPIO_INPUT);
    if (rc < 0) {
        LOG_ERR("Could not configure usr_btn GPIO (%d)", rc);
        return;
    }

    rc = gpio_pin_interrupt_configure_dt(&usr_btn, GPIO_INT_LEVEL_LOW);
    if (rc < 0) {
        LOG_ERR("Could not configure usr_btn GPIO interrupt (%d)", rc);
        return;
    }

#ifdef CONFIG_OMI_ENABLE_WIFI
    wifi_turn_off();
#endif

    rc = watchdog_deinit();
    if (rc < 0) {
        LOG_ERR("Failed to deinitialize watchdog (%d)", rc);
        return;
    }

    lsm6dsl_time_prepare_for_system_off();
    k_msleep(1000);
    LOG_INF("Entering system off; press usr_btn to restart");

    sys_poweroff();
}
