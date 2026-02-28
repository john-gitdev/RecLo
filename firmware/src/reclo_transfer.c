#include "reclo_transfer.h"

#include <zephyr/kernel.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/fs/fs.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/crc.h>
#include <string.h>
#include <stdio.h>

LOG_MODULE_REGISTER(reclo_transfer, LOG_LEVEL_INF);

/* ── Time ────────────────────────────────────────────────────────────────────*/

static uint32_t _epoch_base;      /* UTC epoch at the moment _uptime_base was recorded */
static int64_t  _uptime_base_ms;  /* k_uptime_get() value when _epoch_base was set    */
static bool     _time_synced;

uint32_t reclo_time_get(void)
{
    if (!_time_synced) {
        /* Not yet synced — return uptime seconds as a monotonic fallback */
        return (uint32_t)(k_uptime_get() / 1000);
    }
    int64_t elapsed_ms = k_uptime_get() - _uptime_base_ms;
    return _epoch_base + (uint32_t)(elapsed_ms / 1000);
}

void reclo_time_set(uint32_t epoch_seconds)
{
    _epoch_base     = epoch_seconds;
    _uptime_base_ms = k_uptime_get();
    _time_synced    = true;
    LOG_INF("Time synced: epoch=%u", epoch_seconds);
}

/* ── BLE state ───────────────────────────────────────────────────────────────*/

static struct bt_conn *_conn;
static bool _notify_enabled;
static bool _upload_active;

/* ── Upload thread ───────────────────────────────────────────────────────────*/

#define UPLOAD_STACK_SIZE  4096
#define UPLOAD_THREAD_PRIO    5

K_THREAD_STACK_DEFINE(_upload_stack, UPLOAD_STACK_SIZE);
static struct k_thread _upload_thread;
static K_SEM_DEFINE(_upload_sem, 0, 1);

/* ── Forward declarations ────────────────────────────────────────────────────*/

static void upload_thread_fn(void *a, void *b, void *c);
static int  send_packet(const RecloPacket *pkt);
static int  upload_one_chunk(const char *path, uint16_t idx, uint16_t total);

/* ── GATT UUIDs ──────────────────────────────────────────────────────────────*/

#define RECLO_SVC_UUID \
    BT_UUID_DECLARE_128(BT_UUID_128_ENCODE( \
        0x5c7d0001, 0xb5a3, 0x4f43, 0xc0a9, 0xe50e24dc0000ULL))

#define RECLO_DATA_UUID \
    BT_UUID_DECLARE_128(BT_UUID_128_ENCODE( \
        0x5c7d0001, 0xb5a3, 0x4f43, 0xc0a9, 0xe50e24dc0001ULL))

#define RECLO_CTRL_UUID \
    BT_UUID_DECLARE_128(BT_UUID_128_ENCODE( \
        0x5c7d0001, 0xb5a3, 0x4f43, 0xc0a9, 0xe50e24dc0002ULL))

/* ── GATT: data CCC ──────────────────────────────────────────────────────────*/

static void data_ccc_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
    _notify_enabled = (value == BT_GATT_CCC_NOTIFY);
    LOG_INF("Data notifications: %s", _notify_enabled ? "on" : "off");
}

/* ── GATT: control write ─────────────────────────────────────────────────────*/

static ssize_t ctrl_write(struct bt_conn *conn, const struct bt_gatt_attr *attr,
                           const void *buf, uint16_t len,
                           uint16_t offset, uint8_t flags)
{
    ARG_UNUSED(attr); ARG_UNUSED(offset); ARG_UNUSED(flags);

    if (len == 0) return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);

    const uint8_t *data = (const uint8_t *)buf;

    switch (data[0]) {
    case RECLO_CMD_REQUEST_UPLOAD:
        if (!_upload_active) {
            _upload_active = true;
            k_sem_give(&_upload_sem);
            LOG_INF("Upload requested by phone");
        }
        break;

    case RECLO_CMD_ACK_CHUNK:
        if (len >= 5) {
            uint32_t ts;
            memcpy(&ts, &data[1], sizeof(ts));
            /* Delete the chunk file with this timestamp */
            char path[64];
            snprintf(path, sizeof(path), "%s/%010u.bin", RECLO_STORAGE_DIR, ts);
            int err = fs_unlink(path);
            if (err) {
                LOG_WRN("Delete chunk ts=%u: %d", ts, err);
            } else {
                LOG_INF("Deleted chunk ts=%u", ts);
            }
        }
        break;

    case RECLO_CMD_ABORT:
        _upload_active = false;
        LOG_INF("Upload aborted by phone");
        break;

    default:
        LOG_WRN("Unknown control command: 0x%02x", data[0]);
        break;
    }

    return (ssize_t)len;
}

/* ── GATT service definition ─────────────────────────────────────────────────
 *
 * Attribute table layout (0-based indices):
 *   0  primary service declaration
 *   1  data characteristic declaration
 *   2  data characteristic value          ← bt_gatt_notify target
 *   3  data CCC descriptor
 *   4  control characteristic declaration
 *   5  control characteristic value
 */
BT_GATT_SERVICE_DEFINE(reclo_svc,
    BT_GATT_PRIMARY_SERVICE(RECLO_SVC_UUID),

    /* Data: device → phone (notify) */
    BT_GATT_CHARACTERISTIC(RECLO_DATA_UUID,
        BT_GATT_CHRC_NOTIFY,
        BT_GATT_PERM_NONE,
        NULL, NULL, NULL),
    BT_GATT_CCC(data_ccc_changed,
        BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),

    /* Control: phone → device (write, write-without-response) */
    BT_GATT_CHARACTERISTIC(RECLO_CTRL_UUID,
        BT_GATT_CHRC_WRITE | BT_GATT_CHRC_WRITE_WITHOUT_RESP,
        BT_GATT_PERM_WRITE,
        NULL, ctrl_write, NULL),
);

/* Data characteristic value is at attrs[2] */
#define DATA_ATTR  (&reclo_svc.attrs[2])

/* ── Packet transmission ─────────────────────────────────────────────────────*/

static int send_packet(const RecloPacket *pkt)
{
    if (!_conn || !_notify_enabled) return -ENOTCONN;

    int err = bt_gatt_notify(_conn, DATA_ATTR, pkt, RECLO_PACKET_SIZE);
    if (err && err != -EAGAIN) {
        LOG_ERR("bt_gatt_notify: %d", err);
    }
    return err;
}

/* ── Storage ─────────────────────────────────────────────────────────────────*/

int reclo_transfer_store_chunk(uint32_t ts, const uint8_t *data, size_t len)
{
    /* Ensure storage directory exists */
    struct fs_dirent ent;
    if (fs_stat(RECLO_STORAGE_DIR, &ent) != 0) {
        fs_mkdir(RECLO_STORAGE_DIR);
    }

    char path[64];
    snprintf(path, sizeof(path), "%s/%010u.bin", RECLO_STORAGE_DIR, ts);

    struct fs_file_t f;
    fs_file_t_init(&f);

    int err = fs_open(&f, path, FS_O_CREATE | FS_O_WRITE | FS_O_TRUNC);
    if (err) {
        LOG_ERR("fs_open(%s): %d", path, err);
        return err;
    }

    /*
     * File header (17 bytes):
     *   [0..3]   magic      'RCLO'
     *   [4..7]   timestamp  uint32 LE
     *   [8]      codec_id   20 (Opus)
     *   [9..12]  sample_rate uint32 LE  (16000)
     *   [13..16] data_size  uint32 LE
     */
    uint8_t hdr[17];
    hdr[0] = 'R'; hdr[1] = 'C'; hdr[2] = 'L'; hdr[3] = 'O';

    uint32_t ts_le = ts;
    memcpy(&hdr[4], &ts_le, 4);

    hdr[8] = 20;  /* CODEC_ID Opus */

    uint32_t sr = 16000U;
    memcpy(&hdr[9], &sr, 4);

    uint32_t ds = (uint32_t)len;
    memcpy(&hdr[13], &ds, 4);

    fs_write(&f, hdr, sizeof(hdr));
    fs_write(&f, data, len);
    fs_close(&f);

    LOG_INF("Stored chunk ts=%u (%zu bytes) → %s", ts, len, path);
    return 0;
}

int reclo_transfer_count_chunks(void)
{
    struct fs_dir_t dir;
    struct fs_dirent ent;
    fs_dir_t_init(&dir);

    if (fs_opendir(&dir, RECLO_STORAGE_DIR) != 0) return 0;

    int count = 0;
    while (fs_readdir(&dir, &ent) == 0 && ent.name[0] != '\0') {
        if (ent.type == FS_DIR_ENTRY_FILE) count++;
    }
    fs_closedir(&dir);
    return count;
}

/* ── Upload logic ────────────────────────────────────────────────────────────*/

/*
 * Upload a single chunk file.
 *
 * Sends:
 *   - 1 CHUNK_HEADER packet  (seq=0, metadata in payload)
 *   - N CHUNK_DATA  packets  (seq=1..N, raw Opus bytes in payload)
 *
 * Does NOT delete the file; deletion happens after ACK from phone.
 */
static int upload_one_chunk(const char *path, uint16_t idx, uint16_t total)
{
    struct fs_file_t f;
    fs_file_t_init(&f);

    int err = fs_open(&f, path, FS_O_READ);
    if (err) {
        LOG_ERR("Cannot open %s: %d", path, err);
        return err;
    }

    /* Read file header */
    uint8_t file_hdr[17];
    if (fs_read(&f, file_hdr, sizeof(file_hdr)) != (ssize_t)sizeof(file_hdr)) {
        fs_close(&f);
        return -EIO;
    }

    if (file_hdr[0] != 'R' || file_hdr[1] != 'C' ||
        file_hdr[2] != 'L' || file_hdr[3] != 'O') {
        LOG_ERR("Bad magic in %s", path);
        fs_close(&f);
        return -EILSEQ;
    }

    uint32_t ts, sample_rate, data_size;
    uint8_t  codec_id;
    memcpy(&ts,          &file_hdr[4],  4);
    codec_id = file_hdr[8];
    memcpy(&sample_rate, &file_hdr[9],  4);
    memcpy(&data_size,   &file_hdr[13], 4);
    fs_close(&f);

    /* Compute CRC-32 over the Opus data bytes (not the file header) */
    uint32_t crc = 0;
    {
        struct fs_file_t f2;
        fs_file_t_init(&f2);
        fs_open(&f2, path, FS_O_READ);
        fs_seek(&f2, sizeof(file_hdr), FS_SEEK_SET);

        uint8_t tmp[256];
        ssize_t n;
        while ((n = fs_read(&f2, tmp, sizeof(tmp))) > 0) {
            crc = crc32_ieee_update(crc, tmp, (size_t)n);
        }
        fs_close(&f2);
    }

    /*
     * total_seqs = 1 (header) + ceil(data_size / RECLO_PAYLOAD_SIZE)
     */
    uint16_t data_seqs  = (uint16_t)((data_size + RECLO_PAYLOAD_SIZE - 1) / RECLO_PAYLOAD_SIZE);
    uint16_t total_seqs = 1 + data_seqs;

    /* ── Send CHUNK_HEADER ── */
    RecloPacket pkt;
    memset(&pkt, 0, sizeof(pkt));
    pkt.pkt_type     = RECLO_PKT_CHUNK_HEADER;
    pkt.chunk_ts     = ts;
    pkt.chunk_idx    = idx;
    pkt.total_chunks = total;
    pkt.seq          = 0;
    pkt.total_seqs   = total_seqs;

    RecloChunkMeta meta = {
        .data_size   = data_size,
        .codec_id    = codec_id,
        .sample_rate = sample_rate,
        .crc32       = crc,
    };
    memcpy(pkt.payload, &meta, sizeof(meta));
    pkt.payload_len = sizeof(meta);

    err = send_packet(&pkt);
    if (err) return err;

    k_msleep(10);   /* brief pause so phone can process the header */

    /* ── Send CHUNK_DATA packets ── */
    struct fs_file_t fd;
    fs_file_t_init(&fd);
    err = fs_open(&fd, path, FS_O_READ);
    if (err) return err;
    fs_seek(&fd, sizeof(file_hdr), FS_SEEK_SET);

    uint16_t seq = 1;
    uint8_t  buf[RECLO_PAYLOAD_SIZE];
    ssize_t  n;

    while ((n = fs_read(&fd, buf, RECLO_PAYLOAD_SIZE)) > 0) {
        if (!_upload_active) {
            fs_close(&fd);
            return -ECANCELED;
        }

        memset(&pkt, 0, sizeof(pkt));
        pkt.pkt_type     = RECLO_PKT_CHUNK_DATA;
        pkt.chunk_ts     = ts;
        pkt.chunk_idx    = idx;
        pkt.total_chunks = total;
        pkt.seq          = seq++;
        pkt.total_seqs   = total_seqs;
        pkt.payload_len  = (uint16_t)n;
        memcpy(pkt.payload, buf, (size_t)n);

        err = send_packet(&pkt);
        if (err && err != -EAGAIN) {
            fs_close(&fd);
            return err;
        }

        /* Pace the BLE TX queue: ~244 bytes @ ~90 KB/s ≈ 3ms; 8ms gives headroom */
        k_msleep(8);
    }

    fs_close(&fd);
    LOG_INF("Uploaded chunk %u/%u ts=%u (%u seqs)", idx + 1, total, ts, seq);
    return 0;
}

/* ── Upload thread ───────────────────────────────────────────────────────────*/

static void upload_thread_fn(void *a, void *b, void *c)
{
    ARG_UNUSED(a); ARG_UNUSED(b); ARG_UNUSED(c);

    /* File paths sorted by name (= timestamp order) */
    static char paths[RECLO_MAX_CHUNKS][64];

    while (true) {
        k_sem_take(&_upload_sem, K_FOREVER);

        if (!_conn || !_notify_enabled) {
            _upload_active = false;
            continue;
        }

        /* Enumerate chunk files */
        struct fs_dir_t  dir;
        struct fs_dirent ent;
        fs_dir_t_init(&dir);

        int count = 0;
        if (fs_opendir(&dir, RECLO_STORAGE_DIR) == 0) {
            while (count < RECLO_MAX_CHUNKS &&
                   fs_readdir(&dir, &ent) == 0 &&
                   ent.name[0] != '\0') {
                if (ent.type == FS_DIR_ENTRY_FILE) {
                    snprintf(paths[count], sizeof(paths[count]),
                             "%s/%s", RECLO_STORAGE_DIR, ent.name);
                    count++;
                }
            }
            fs_closedir(&dir);
        }

        if (count == 0) {
            LOG_INF("No chunks to upload");
            /* Send UPLOAD_DONE immediately so the phone knows */
            RecloPacket done;
            memset(&done, 0, sizeof(done));
            done.pkt_type = RECLO_PKT_UPLOAD_DONE;
            send_packet(&done);
            _upload_active = false;
            continue;
        }

        /* Sort filenames ascending (strcmp on zero-padded timestamps = numeric order) */
        for (int i = 1; i < count; i++) {
            char tmp[64];
            int  j = i;
            while (j > 0 && strcmp(paths[j - 1], paths[j]) > 0) {
                memcpy(tmp,          paths[j - 1], sizeof(tmp));
                memcpy(paths[j - 1], paths[j],     sizeof(tmp));
                memcpy(paths[j],     tmp,           sizeof(tmp));
                j--;
            }
        }

        LOG_INF("Starting upload: %d chunk(s)", count);

        for (int i = 0; i < count && _upload_active; i++) {
            int err = upload_one_chunk(paths[i], (uint16_t)i, (uint16_t)count);
            if (err == -ECANCELED) break;
            if (err) LOG_WRN("Chunk %d upload error %d — continuing", i, err);

            k_msleep(20);   /* gap between chunks */
        }

        if (_upload_active) {
            RecloPacket done;
            memset(&done, 0, sizeof(done));
            done.pkt_type = RECLO_PKT_UPLOAD_DONE;
            send_packet(&done);
            LOG_INF("Upload complete");
        }

        _upload_active = false;
    }
}

/* ── BT connection callbacks (auto-registered) ───────────────────────────────*/

static void _on_connected(struct bt_conn *conn, uint8_t err)
{
    if (err) return;
    if (_conn) bt_conn_unref(_conn);
    _conn = bt_conn_ref(conn);
    LOG_INF("Transfer: device connected");
}

static void _on_disconnected(struct bt_conn *conn, uint8_t reason)
{
    _upload_active  = false;
    _notify_enabled = false;
    if (_conn) {
        bt_conn_unref(_conn);
        _conn = NULL;
    }
    LOG_INF("Transfer: device disconnected (reason %u)", reason);
}

BT_CONN_CB_DEFINE(reclo_conn_callbacks) = {
    .connected    = _on_connected,
    .disconnected = _on_disconnected,
};

/* ── Public API ──────────────────────────────────────────────────────────────*/

int reclo_transfer_init(void)
{
    _conn           = NULL;
    _notify_enabled = false;
    _upload_active  = false;
    _time_synced    = false;

    k_thread_create(
        &_upload_thread, _upload_stack, UPLOAD_STACK_SIZE,
        upload_thread_fn, NULL, NULL, NULL,
        UPLOAD_THREAD_PRIO, 0, K_NO_WAIT
    );
    k_thread_name_set(&_upload_thread, "reclo_upload");

    LOG_INF("RecLo transfer service initialized");
    return 0;
}
