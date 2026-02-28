#ifndef RECLO_RECORDER_H
#define RECLO_RECORDER_H

#include <stdint.h>
#include <stddef.h>

/*
 * reclo_recorder — 15-second offline Opus chunk recorder
 *
 * Hooks into the Omi codec pipeline via set_codec_callback().
 * Accumulates length-prefixed Opus frames into a buffer.
 * Every 15 seconds, flushes the buffer to flash via reclo_transfer_store_chunk().
 *
 * Frame storage format (sent to reclo_transfer_store_chunk):
 *   Repeating: [2-byte LE frame_len][frame_len bytes of Opus data]
 *
 * Thread safety: codec callback fires from the codec thread; internals use a mutex.
 */

/* Chunk duration in seconds */
#define RECLO_CHUNK_DURATION_S  15

/*
 * Maximum Opus data bytes per chunk.
 * 32 kbps × 15 s = 60,000 bytes; add 25% headroom for peaks.
 */
#define RECLO_CHUNK_MAX_BYTES   75000

/*
 * Initialize the recorder.  Must be called once before codec_start().
 * Returns 0 on success, negative errno on error.
 */
int reclo_recorder_init(void);

/*
 * Start recording.  Registers the codec callback and arms the 15-second timer.
 * Safe to call after BLE connects (recording is independent of BLE state).
 */
void reclo_recorder_start(void);

/*
 * Stop recording and flush any partial chunk to flash.
 */
void reclo_recorder_stop(void);

/*
 * Return the number of complete chunks currently stored on flash.
 * Thread-safe.
 */
int reclo_recorder_chunk_count(void);

#endif /* RECLO_RECORDER_H */
