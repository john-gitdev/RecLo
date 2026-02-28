#ifndef RECLO_RECORDER_H
#define RECLO_RECORDER_H

#include <stdint.h>

/*
 * reclo_recorder — 15-second offline Opus chunk recorder.
 *
 * Hooks into the Omi codec pipeline via set_codec_callback().
 * Each encoded Opus frame is stored with a 2-byte LE length prefix
 * and accumulated into a buffer. Every RECLO_CHUNK_DURATION_S seconds
 * the buffer is handed to reclo_transfer_store_chunk() and reset.
 *
 * Call order:
 *   reclo_recorder_init()   — once at boot
 *   reclo_recorder_start()  — begins recording (sets codec callback)
 *   reclo_recorder_stop()   — flushes partial chunk, clears callback
 */

/* Omi consumer codec: 320 samples/frame (20ms), 32kbps VBR Opus, CODEC_ID=21
 * 15s / 0.02s = 750 frames; avg ~60KB Opus + 1.5KB length prefixes = ~62KB
 * 65000 gives ~5% headroom over typical VBR output.                         */
#define RECLO_CHUNK_DURATION_S  15
#define RECLO_CHUNK_MAX_BYTES   65000

int  reclo_recorder_init(void);
void reclo_recorder_start(void);
void reclo_recorder_stop(void);
int  reclo_recorder_chunk_count(void);

#endif /* RECLO_RECORDER_H */
