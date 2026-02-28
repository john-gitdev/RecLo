#ifndef RECLO_TRANSFER_H
#define RECLO_TRANSFER_H

#include <zephyr/bluetooth/conn.h>
#include <stdint.h>
#include <stddef.h>

/*
 * reclo_transfer — BLE chunk upload protocol
 *
 * Provides a GATT service with two characteristics:
 *   • Data (NOTIFY):   device → phone, fixed 244-byte packets
 *   • Control (WRITE): phone → device, command bytes
 *
 * Protocol overview:
 *   1. Phone connects, writes REQUEST_UPLOAD to control char.
 *   2. Device enumerates stored chunks (sorted by timestamp).
 *   3. For each chunk, device sends:
 *        - One CHUNK_HEADER packet (metadata + no Opus payload)
 *        - N CHUNK_DATA packets   (229 bytes of Opus data each, last may be shorter)
 *   4. Phone sends ACK_CHUNK (control write) after saving each chunk.
 *      Device deletes the chunk on receipt of its ACK.
 *   5. After the last chunk, device sends one UPLOAD_DONE packet.
 *
 * Packet layout (244 bytes, all multi-byte fields little-endian):
 *   [0]      pkt_type      — RECLO_PKT_*
 *   [1..4]   chunk_ts      — Unix epoch seconds (uint32)
 *   [5..6]   chunk_idx     — 0-based chunk index in this upload batch (uint16)
 *   [7..8]   total_chunks  — total chunks in this batch (uint16)
 *   [9..10]  seq           — 0-based packet sequence within this chunk (uint16)
 *   [11..12] total_seqs    — total packets for this chunk (uint16)
 *   [13..14] payload_len   — bytes used in payload[] (uint16, 0–229)
 *   [15..243] payload      — 229 bytes of data
 *
 * CHUNK_HEADER payload (13 bytes):
 *   [0..3]   data_size    — total Opus data bytes for this chunk (uint32)
 *   [4]      codec_id     — 20 = Opus
 *   [5..8]   sample_rate  — 16000 (uint32)
 *   [9..12]  crc32        — CRC-32/ISO-HDLC of the Opus data bytes (uint32)
 *
 * CHUNK_DATA payload:
 *   Raw Opus bytes (length-prefixed frames as stored on flash).
 *
 * Control commands (phone → device, 1–5 bytes):
 *   0x01                   — REQUEST_UPLOAD
 *   0x02 [ts:4 bytes LE]   — ACK_CHUNK   (5 bytes total)
 *   0x03                   — ABORT
 *
 * BLE Service UUIDs:
 *   Service:  5c7d0001-b5a3-4f43-c0a9-e50e24dc0000
 *   Data:     5c7d0001-b5a3-4f43-c0a9-e50e24dc0001
 *   Control:  5c7d0001-b5a3-4f43-c0a9-e50e24dc0002
 */

/* ── Packet constants ───────────────────────────────────────────────────────*/

#define RECLO_PACKET_SIZE    244
#define RECLO_HEADER_SIZE     15
#define RECLO_PAYLOAD_SIZE   229   /* PACKET_SIZE - HEADER_SIZE */

/* Packet types */
#define RECLO_PKT_CHUNK_HEADER  0x01
#define RECLO_PKT_CHUNK_DATA    0x02
#define RECLO_PKT_UPLOAD_DONE   0x03

/* Control commands (phone → device) */
#define RECLO_CMD_REQUEST_UPLOAD  0x01
#define RECLO_CMD_ACK_CHUNK       0x02   /* followed by 4-byte timestamp LE */
#define RECLO_CMD_ABORT           0x03

/* Maximum chunks the upload queue can hold */
#define RECLO_MAX_CHUNKS  64

/* Storage directory on flash filesystem */
#define RECLO_STORAGE_DIR  "/lfs/reclo"

/* ── Packed structures ──────────────────────────────────────────────────────*/

/** Payload of a CHUNK_HEADER packet (13 bytes). */
typedef struct __attribute__((packed)) {
    uint32_t data_size;    /* total Opus data bytes                  */
    uint8_t  codec_id;     /* 20 = Opus                              */
    uint32_t sample_rate;  /* Hz, always 16000                       */
    uint32_t crc32;        /* CRC-32 of the Opus data                */
} RecloChunkMeta;

/** Full 244-byte BLE data packet. */
typedef struct __attribute__((packed)) {
    uint8_t  pkt_type;        /* RECLO_PKT_*                              */
    uint32_t chunk_ts;        /* Unix epoch seconds (LE)                  */
    uint16_t chunk_idx;       /* 0-based index in this upload batch       */
    uint16_t total_chunks;    /* total chunks queued                      */
    uint16_t seq;             /* 0-based sequence within this chunk       */
    uint16_t total_seqs;      /* total seqs for this chunk (header + data)*/
    uint16_t payload_len;     /* bytes used in payload[]                  */
    uint8_t  payload[RECLO_PAYLOAD_SIZE];
} RecloPacket;

_Static_assert(sizeof(RecloPacket) == RECLO_PACKET_SIZE,
               "RecloPacket must be exactly 244 bytes");

/* ── Public API ─────────────────────────────────────────────────────────────*/

/**
 * Initialize the transfer service.
 * Spawns the upload thread. BT connection callbacks are registered
 * automatically via BT_CONN_CB_DEFINE — no manual wiring needed.
 * Must be called once during boot, before codec_start().
 */
int reclo_transfer_init(void);

/**
 * Store a completed audio chunk to flash.
 * Called by reclo_recorder after each 15-second chunk is ready.
 *
 * @param ts    Unix epoch seconds when the chunk recording started.
 * @param data  Length-prefixed Opus frames:
 *              [2-byte LE frame_len][frame bytes][2-byte LE frame_len]...
 * @param len   Total byte count of data.
 * @return 0 on success, negative errno on failure.
 */
int reclo_transfer_store_chunk(uint32_t ts, const uint8_t *data, size_t len);

/**
 * Return the number of chunk files currently on flash.
 */
int reclo_transfer_count_chunks(void);

/**
 * Get the current Unix epoch time in seconds.
 * Updated by the phone on BLE connect; falls back to uptime if not yet set.
 */
uint32_t reclo_time_get(void);

/**
 * Set the Unix epoch time (called by the BLE time-sync write handler).
 */
void reclo_time_set(uint32_t epoch_seconds);

#endif /* RECLO_TRANSFER_H */
