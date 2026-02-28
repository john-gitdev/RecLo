#ifndef RECLO_RECORDER_H
#define RECLO_RECORDER_H

#include <stdint.h>

/*
 * reclo_recorder — 30-second direct-to-SD Opus chunk recorder.
 *
 * Hooks into the Omi codec pipeline via set_codec_callback().
 * Each encoded Opus frame is stored with a 2-byte LE length prefix
 * and accumulated into a 4KB RAM buffer. When the buffer fills it is
 * flushed to an open SD card file. Every RECLO_CHUNK_DURATION_S seconds
 * the file is finalised (data_size header field back-filled) and a new
 * file is opened for the next chunk.
 *
 * RAM usage: ~4KB (vs 65KB with the old accumulate-then-save approach).
 * A crash or power loss loses at most ~1 second of audio (one buffer).
 *
 * Call order:
 *   reclo_recorder_init()   — once at boot
 *   reclo_recorder_start()  — opens first chunk file, sets codec callback
 *   reclo_recorder_stop()   — finalises current chunk, clears callback
 */

/* Omi consumer codec: 320 samples/frame (20ms), 32kbps VBR Opus, CODEC_ID=21
 * 30s / 0.02s = 1500 frames; 4KB write buffer flushes roughly every 1 second. */
#define RECLO_CHUNK_DURATION_S  30
#define RECLO_STREAM_BUF_SIZE   4096

int  reclo_recorder_init(void);
void reclo_recorder_start(void);
void reclo_recorder_stop(void);
int  reclo_recorder_chunk_count(void);

#endif /* RECLO_RECORDER_H */
