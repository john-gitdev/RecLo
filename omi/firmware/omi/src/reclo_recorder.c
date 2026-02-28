#include "reclo_recorder.h"
#include "reclo_transfer.h"

#include <zephyr/kernel.h>
#include <zephyr/fs/fs.h>
#include <zephyr/logging/log.h>
#include <string.h>
#include <stdio.h>

#include "lib/core/codec.h"
#include "rtc.h"

LOG_MODULE_REGISTER(reclo_recorder, LOG_LEVEL_INF);

/* ── State ──────────────────────────────────────────────────────────────────── */

static struct fs_file_t _active_file;
static bool             _file_open;
static uint8_t          _write_buf[RECLO_STREAM_BUF_SIZE];
static size_t           _write_buf_len;
static uint32_t         _total_bytes_in_chunk;
static char             _active_path[64];
static uint32_t         _chunk_start_ts;
static bool             _recording;

static K_MUTEX_DEFINE(_mutex);
static K_TIMER_DEFINE(_chunk_timer, NULL, NULL);

/* ── Header helper ───────────────────────────────────────────────────────────
 * Writes the 17-byte RCLO file header with data_size = 0.
 * reclo_transfer.c reads: magic[4] + ts[4] + codec_id[1] + sr[4] + data_size[4]
 * data_size (offset 13) is back-filled in finalize_chunk().
 */
static void write_initial_header(struct fs_file_t *f, uint32_t ts)
{
    uint8_t hdr[17];
    hdr[0] = 'R'; hdr[1] = 'C'; hdr[2] = 'L'; hdr[3] = 'O';
    memcpy(&hdr[4], &ts, 4);
    hdr[8] = 21;                   /* CODEC_ID — Omi consumer opusFS320 */
    uint32_t sr = 16000U;
    memcpy(&hdr[9], &sr, 4);
    uint32_t ds = 0U;
    memcpy(&hdr[13], &ds, 4);     /* placeholder; updated by finalize_chunk */
    fs_write(f, hdr, sizeof(hdr));
}

/* ── Open a new chunk file ───────────────────────────────────────────────────*/

static int open_chunk_file(uint32_t ts)
{
    struct fs_dirent ent;
    if (fs_stat(RECLO_STORAGE_DIR, &ent) != 0) {
        fs_mkdir(RECLO_STORAGE_DIR);
    }

    snprintf(_active_path, sizeof(_active_path),
             "%s/%010u.bin", RECLO_STORAGE_DIR, ts);

    fs_file_t_init(&_active_file);
    int err = fs_open(&_active_file, _active_path,
                      FS_O_CREATE | FS_O_WRITE | FS_O_TRUNC);
    if (err) {
        LOG_ERR("fs_open(%s): %d", _active_path, err);
        return err;
    }

    write_initial_header(&_active_file, ts);
    _file_open            = true;
    _write_buf_len        = 0;
    _total_bytes_in_chunk = 0;
    _chunk_start_ts       = ts;
    return 0;
}

/* ── Finalise the current chunk file ─────────────────────────────────────────
 * Must be called with _mutex held.
 */
static void finalize_chunk(void)
{
    /* Flush any remaining RAM buffer */
    if (_write_buf_len > 0) {
        fs_write(&_active_file, _write_buf, _write_buf_len);
        _write_buf_len = 0;
    }

    /* Back-fill data_size at offset 13 so reclo_transfer can read it */
    fs_seek(&_active_file, 13, FS_SEEK_SET);
    fs_write(&_active_file, &_total_bytes_in_chunk,
             sizeof(_total_bytes_in_chunk));

    fs_close(&_active_file);
    _file_open = false;

    LOG_INF("Finalized chunk ts=%u (%u bytes) → %s",
            _chunk_start_ts, _total_bytes_in_chunk, _active_path);
}

/* ── Codec callback ──────────────────────────────────────────────────────────
 * Called by the Omi codec thread after each Opus frame is encoded.
 * Prepends a 2-byte LE length prefix, buffers the frame, and flushes
 * the 4KB buffer to the open SD card file when it gets full.
 */
static void on_codec_output(uint8_t *data, size_t len)
{
    if (!_recording || len == 0 || len > UINT16_MAX) return;

    k_mutex_lock(&_mutex, K_FOREVER);

    if (!_file_open) {
        k_mutex_unlock(&_mutex);
        return;
    }

    /* Guard: a single frame larger than the buffer can never be buffered */
    if (2 + len > RECLO_STREAM_BUF_SIZE) {
        LOG_WRN("Frame too large for write buffer (%zu bytes); dropping", len);
        k_mutex_unlock(&_mutex);
        return;
    }

    /* Flush buffer to SD before it would overflow */
    if (_write_buf_len + 2 + len > RECLO_STREAM_BUF_SIZE) {
        fs_write(&_active_file, _write_buf, _write_buf_len);
        _write_buf_len = 0;
    }

    /* Append 2-byte LE length prefix + frame bytes */
    _write_buf[_write_buf_len]     = (uint8_t)(len & 0xFF);
    _write_buf[_write_buf_len + 1] = (uint8_t)((len >> 8) & 0xFF);
    _write_buf_len += 2;
    memcpy(&_write_buf[_write_buf_len], data, len);
    _write_buf_len        += len;
    _total_bytes_in_chunk += (uint32_t)(2 + len);

    k_mutex_unlock(&_mutex);
}

/* ── Chunk rotation ──────────────────────────────────────────────────────────
 * Finalises the current file and opens a new one.
 * Called by the flush thread every RECLO_CHUNK_DURATION_S seconds.
 */
static void rotate_chunk(void)
{
    k_mutex_lock(&_mutex, K_FOREVER);

    if (_file_open) {
        finalize_chunk();
    }

    uint32_t ts = get_utc_time();
    int err = open_chunk_file(ts);
    if (err) {
        LOG_ERR("rotate: failed to open next chunk: %d", err);
    }

    k_mutex_unlock(&_mutex);
}

/* ── Flush thread ────────────────────────────────────────────────────────────*/

#define FLUSH_THREAD_STACK  2048
#define FLUSH_THREAD_PRIO   6

K_THREAD_STACK_DEFINE(_flush_stack, FLUSH_THREAD_STACK);
static struct k_thread _flush_thread;

static void flush_thread_fn(void *a, void *b, void *c)
{
    ARG_UNUSED(a); ARG_UNUSED(b); ARG_UNUSED(c);

    while (true) {
        k_timer_status_sync(&_chunk_timer);
        if (_recording) {
            rotate_chunk();
        }
    }
}

/* ── Public API ──────────────────────────────────────────────────────────────*/

int reclo_recorder_init(void)
{
    _file_open            = false;
    _recording            = false;
    _write_buf_len        = 0;
    _total_bytes_in_chunk = 0;

    k_timer_init(&_chunk_timer, NULL, NULL);

    k_thread_create(
        &_flush_thread, _flush_stack, FLUSH_THREAD_STACK,
        flush_thread_fn, NULL, NULL, NULL,
        FLUSH_THREAD_PRIO, 0, K_NO_WAIT
    );
    k_thread_name_set(&_flush_thread, "reclo_flush");

    LOG_INF("RecLo recorder initialized (chunk=%ds, stream_buf=%d bytes)",
            RECLO_CHUNK_DURATION_S, RECLO_STREAM_BUF_SIZE);
    return 0;
}

void reclo_recorder_start(void)
{
    if (_recording) return;

    k_mutex_lock(&_mutex, K_FOREVER);

    uint32_t ts = get_utc_time();
    int err = open_chunk_file(ts);
    if (err) {
        LOG_ERR("RecLo: failed to open initial chunk file: %d", err);
        k_mutex_unlock(&_mutex);
        return;
    }

    _recording = true;
    k_mutex_unlock(&_mutex);

    set_codec_callback(on_codec_output);

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
    set_codec_callback(NULL);

    k_mutex_lock(&_mutex, K_FOREVER);
    if (_file_open) {
        finalize_chunk();
    }
    k_mutex_unlock(&_mutex);

    LOG_INF("RecLo recorder stopped");
}

int reclo_recorder_chunk_count(void)
{
    return reclo_transfer_count_chunks();
}
