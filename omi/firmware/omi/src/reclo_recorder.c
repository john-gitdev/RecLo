#include "reclo_recorder.h"
#include "reclo_transfer.h"

#include <zephyr/kernel.h>
#include <zephyr/fs/fs.h>
#include <zephyr/logging/log.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

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

static bool             _chunk_unsynced; /* true when _chunk_start_ts is uptime-s, not UTC */

static K_MUTEX_DEFINE(_mutex);
static K_TIMER_DEFINE(_chunk_timer, NULL, NULL);
static struct k_work    _retimestamp_work;

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
    /* Always use uptime seconds as the chunk timestamp so that stale RTC
     * epochs (e.g. after battery drain) don't corrupt filenames.
     * reclo_recorder_retimestamp() corrects all .upt files on every sync. */
    ARG_UNUSED(ts);
    bool unsynced = true;
    ts = (uint32_t)(k_uptime_get() / 1000);

    struct fs_dirent ent;
    if (fs_stat(RECLO_STORAGE_DIR, &ent) != 0) {
        fs_mkdir(RECLO_STORAGE_DIR);
    }

    snprintf(_active_path, sizeof(_active_path),
             "%s/%010u.tmp", RECLO_STORAGE_DIR, ts);

    fs_file_t_init(&_active_file);
    int err = fs_open(&_active_file, _active_path,
                      FS_O_CREATE | FS_O_WRITE | FS_O_TRUNC);
    if (err) {
        LOG_ERR("fs_open(%s): %d", _active_path, err);
        return err;
    }

    write_initial_header(&_active_file, ts);
    _file_open            = true;
    _chunk_unsynced       = unsynced;
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

    /* Atomically publish the chunk.  Use .upt extension when the timestamp is
     * uptime-based (UTC was not synced); reclo_transfer ignores .upt files
     * until reclo_recorder_retimestamp() renames them to .bin. */
    char final_path[64];
    snprintf(final_path, sizeof(final_path),
             "%s/%010u.%s", RECLO_STORAGE_DIR, _chunk_start_ts,
             _chunk_unsynced ? "upt" : "bin");
    int rename_err = fs_rename(_active_path, final_path);
    if (rename_err) {
        LOG_ERR("fs_rename(%s → %s): %d", _active_path, final_path, rename_err);
    }

    LOG_INF("Finalized chunk ts=%u (%u bytes) → %s%s",
            _chunk_start_ts, _total_bytes_in_chunk, final_path,
            _chunk_unsynced ? " [unsynced]" : "");
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

#define FLUSH_THREAD_STACK  4096
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

/* ── Retimestamp ─────────────────────────────────────────────────────────────
 * Corrects uptime-based timestamps on chunk files once UTC is known.
 *
 * For any chunk recorded while UTC was unsynced:
 *   real_ts = now_utc_s - (now_uptime_s - file_uptime_ts)
 *
 * Handles both the currently-open .tmp file and any finalized .upt files.
 */

static void reclo_recorder_retimestamp(void)
{
    uint32_t now_utc_s = get_utc_time();
    if (now_utc_s == 0) {
        return;
    }
    uint32_t now_up_s = (uint32_t)(k_uptime_get() / 1000);

    /* ── Patch the currently-open chunk file if it was unsynced ─────────── */
    k_mutex_lock(&_mutex, K_FOREVER);

    if (_file_open && _chunk_unsynced) {
        uint32_t uptime_ts = _chunk_start_ts;
        uint32_t elapsed   = (now_up_s >= uptime_ts) ? (now_up_s - uptime_ts) : 0;
        uint32_t real_ts   = now_utc_s - elapsed;

        /* Flush write buffer before closing */
        if (_write_buf_len > 0) {
            fs_write(&_active_file, _write_buf, _write_buf_len);
            _write_buf_len = 0;
        }

        /* Patch timestamp at file header offset 4 */
        fs_seek(&_active_file, 4, FS_SEEK_SET);
        fs_write(&_active_file, &real_ts, sizeof(real_ts));

        /* Close → rename → reopen (FAT FS requires file closed for rename) */
        fs_close(&_active_file);

        char new_path[64];
        snprintf(new_path, sizeof(new_path),
                 "%s/%010u.tmp", RECLO_STORAGE_DIR, real_ts);

        if (fs_rename(_active_path, new_path) == 0) {
            memcpy(_active_path, new_path, sizeof(_active_path));
        } else {
            LOG_ERR("retimestamp: rename open file failed");
        }

        fs_file_t_init(&_active_file);
        int err = fs_open(&_active_file, _active_path, FS_O_WRITE);
        if (err) {
            LOG_ERR("retimestamp: reopen %s failed: %d", _active_path, err);
            _file_open = false;
        } else {
            fs_seek(&_active_file, 0, FS_SEEK_END);
        }

        _chunk_start_ts = real_ts;
        _chunk_unsynced = false;
        LOG_INF("Retimestamped open chunk: uptime=%u → utc=%u", uptime_ts, real_ts);
    }

    k_mutex_unlock(&_mutex);

    /* ── Scan for .upt files; collect then rename outside enumeration ────── */
    static uint32_t upt_ts[RECLO_MAX_CHUNKS];
    int upt_count = 0;

    struct fs_dir_t  dir;
    struct fs_dirent ent;
    fs_dir_t_init(&dir);

    if (fs_opendir(&dir, RECLO_STORAGE_DIR) == 0) {
        while (upt_count < RECLO_MAX_CHUNKS &&
               fs_readdir(&dir, &ent) == 0 && ent.name[0] != '\0') {
            size_t nlen = strlen(ent.name);
            /* Expect exactly "0123456789.upt" = 14 chars */
            if (ent.type == FS_DIR_ENTRY_FILE && nlen == 14 &&
                strcmp(ent.name + 10, ".upt") == 0) {
                char ts_str[11];
                memcpy(ts_str, ent.name, 10);
                ts_str[10] = '\0';
                upt_ts[upt_count++] = (uint32_t)strtoul(ts_str, NULL, 10);
            }
        }
        fs_closedir(&dir);
    }

    for (int i = 0; i < upt_count; i++) {
        uint32_t elapsed = (now_up_s >= upt_ts[i]) ? (now_up_s - upt_ts[i]) : 0;
        uint32_t real_ts = now_utc_s - elapsed;

        char old_path[64], new_path[64];
        snprintf(old_path, sizeof(old_path),
                 "%s/%010u.upt", RECLO_STORAGE_DIR, upt_ts[i]);
        snprintf(new_path, sizeof(new_path),
                 "%s/%010u.bin", RECLO_STORAGE_DIR, real_ts);

        /* Patch timestamp in file header */
        struct fs_file_t f;
        fs_file_t_init(&f);
        if (fs_open(&f, old_path, FS_O_RDWR) == 0) {
            fs_seek(&f, 4, FS_SEEK_SET);
            fs_write(&f, &real_ts, sizeof(real_ts));
            fs_close(&f);
        }

        int err = fs_rename(old_path, new_path);
        if (err) {
            LOG_ERR("retimestamp: %s → %s failed: %d", old_path, new_path, err);
        } else {
            LOG_INF("Retimestamped chunk: uptime=%u → utc=%u", upt_ts[i], real_ts);
        }
    }

    /* If we hit the max array size, there might be more .upt files waiting.
     * Resubmit the work item to process the next batch. */
    if (upt_count == RECLO_MAX_CHUNKS) {
        k_work_submit(&_retimestamp_work);
    }
}

static void retimestamp_work_fn(struct k_work *work)
{
    ARG_UNUSED(work);
    reclo_recorder_retimestamp();
}

void reclo_recorder_schedule_retimestamp(void)
{
    k_work_submit(&_retimestamp_work);
}

/* ── Public API ──────────────────────────────────────────────────────────────*/

int reclo_recorder_init(void)
{
    _file_open            = false;
    _recording            = false;
    _chunk_unsynced       = false;
    _write_buf_len        = 0;
    _total_bytes_in_chunk = 0;

    k_work_init(&_retimestamp_work, retimestamp_work_fn);

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
