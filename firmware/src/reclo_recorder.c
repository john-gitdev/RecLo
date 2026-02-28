#include "reclo_recorder.h"
#include "reclo_transfer.h"

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <string.h>

/* Reference Omi codec headers for integration */
#include "codec.h"
#include "config.h"

LOG_MODULE_REGISTER(reclo_recorder, LOG_LEVEL_INF);

/* ── State ──────────────────────────────────────────────────────────────────── */

static uint8_t  _buf[RECLO_CHUNK_MAX_BYTES];
static size_t   _buf_len;
static uint32_t _chunk_start_ts;   /* Unix epoch seconds when chunk started    */
static bool     _recording;

static K_MUTEX_DEFINE(_mutex);
static K_TIMER_DEFINE(_chunk_timer, NULL, NULL);

/* ── Time helper ─────────────────────────────────────────────────────────────
 * Returns current Unix epoch seconds.
 * The Omi BLE transport syncs time from the phone on connect; we read back
 * the same value here.  If not yet synced, falls back to uptime seconds
 * (so timestamps still monotonically increase and the app can re-anchor them).
 */
extern uint32_t reclo_time_get(void);  /* implemented in reclo_transfer.c */

/* ── Codec callback ──────────────────────────────────────────────────────────
 * Called by the Omi codec thread after each Opus frame is encoded.
 *
 * data:  raw Opus frame bytes (no length prefix; codec writes only frame bytes)
 * len:   byte count of this frame
 *
 * We prepend a 2-byte LE length prefix and append to the accumulation buffer.
 * This matches the frame-boundary format expected by ChunkUploadService on the
 * Flutter side.
 */
static void on_codec_output(uint8_t *data, size_t len)
{
    if (!_recording || len == 0 || len > UINT16_MAX) return;

    k_mutex_lock(&_mutex, K_FOREVER);

    /* Reserve space for prefix + frame */
    if (_buf_len + 2 + len > RECLO_CHUNK_MAX_BYTES) {
        LOG_WRN("Chunk buffer full; dropping frame (%zu bytes)", len);
        k_mutex_unlock(&_mutex);
        return;
    }

    /* 2-byte LE length prefix */
    _buf[_buf_len]     = (uint8_t)(len & 0xFF);
    _buf[_buf_len + 1] = (uint8_t)((len >> 8) & 0xFF);
    _buf_len += 2;

    memcpy(&_buf[_buf_len], data, len);
    _buf_len += len;

    k_mutex_unlock(&_mutex);
}

/* ── Chunk flush ─────────────────────────────────────────────────────────────
 * Saves the current buffer as a complete chunk and resets for the next one.
 * Must be called from a context that can sleep (not an ISR).
 */
static void flush_chunk(void)
{
    k_mutex_lock(&_mutex, K_FOREVER);

    if (_buf_len == 0) {
        /* Nothing recorded in this window — just re-arm the timer */
        _chunk_start_ts = reclo_time_get();
        k_mutex_unlock(&_mutex);
        return;
    }

    uint32_t ts  = _chunk_start_ts;
    size_t   len = _buf_len;

    /* Copy out so we can release the mutex before the (potentially slow) write */
    static uint8_t _flush_buf[RECLO_CHUNK_MAX_BYTES];
    memcpy(_flush_buf, _buf, len);

    _buf_len        = 0;
    _chunk_start_ts = reclo_time_get();

    k_mutex_unlock(&_mutex);

    int err = reclo_transfer_store_chunk(ts, _flush_buf, len);
    if (err) {
        LOG_ERR("Failed to store chunk ts=%u: %d", ts, err);
    } else {
        LOG_INF("Stored chunk ts=%u (%zu bytes)", ts, len);
    }
}

/* ── Timer/flush thread ──────────────────────────────────────────────────────
 * A dedicated thread wakes every RECLO_CHUNK_DURATION_S seconds to flush.
 */
#define FLUSH_THREAD_STACK  2048
#define FLUSH_THREAD_PRIO   6

K_THREAD_STACK_DEFINE(_flush_stack, FLUSH_THREAD_STACK);
static struct k_thread _flush_thread;

static void flush_thread_fn(void *a, void *b, void *c)
{
    ARG_UNUSED(a); ARG_UNUSED(b); ARG_UNUSED(c);

    while (true) {
        k_timer_status_sync(&_chunk_timer);   /* blocks until timer fires */
        if (_recording) {
            flush_chunk();
        }
    }
}

/* ── Public API ──────────────────────────────────────────────────────────────*/

int reclo_recorder_init(void)
{
    _buf_len   = 0;
    _recording = false;

    k_timer_init(&_chunk_timer, NULL, NULL);

    k_thread_create(
        &_flush_thread, _flush_stack, FLUSH_THREAD_STACK,
        flush_thread_fn, NULL, NULL, NULL,
        FLUSH_THREAD_PRIO, 0, K_NO_WAIT
    );
    k_thread_name_set(&_flush_thread, "reclo_flush");

    LOG_INF("RecLo recorder initialized (chunk=%ds, buf=%d bytes)",
            RECLO_CHUNK_DURATION_S, RECLO_CHUNK_MAX_BYTES);
    return 0;
}

void reclo_recorder_start(void)
{
    if (_recording) return;

    k_mutex_lock(&_mutex, K_FOREVER);
    _buf_len        = 0;
    _chunk_start_ts = reclo_time_get();
    _recording      = true;
    k_mutex_unlock(&_mutex);

    /* Register ourselves as the codec output handler */
    set_codec_callback(on_codec_output);

    /* Arm repeating 15-second timer */
    k_timer_start(&_chunk_timer,
                  K_SECONDS(RECLO_CHUNK_DURATION_S),
                  K_SECONDS(RECLO_CHUNK_DURATION_S));

    LOG_INF("RecLo recorder started");
}

void reclo_recorder_stop(void)
{
    if (!_recording) return;

    k_timer_stop(&_chunk_timer);
    _recording = false;

    /* Clear the codec callback so no more frames arrive */
    set_codec_callback(NULL);

    /* Flush whatever has accumulated */
    flush_chunk();

    LOG_INF("RecLo recorder stopped");
}

int reclo_recorder_chunk_count(void)
{
    return reclo_transfer_count_chunks();   /* delegated to transfer module */
}
