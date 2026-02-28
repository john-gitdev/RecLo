# RecLo

A wearable audio recorder that captures continuously without a phone and syncs over BLE when you reconnect.

Built on the Omi nRF5340 hardware. The device records in 30-second Opus chunks, timestamps them with its RTC, and stores them on SD card. When you reconnect, everything uploads automatically and appears as clean conversation files in the app.

---

## How it works

**On device (always recording):**
- Encodes audio as 30-second Opus chunks (16 kHz, 32 kbps VBR)
- Timestamps each chunk from the onboard RTC at the moment recording starts
- Stores chunks on SD card under `/SD:/reclo/` as binary files with a 17-byte header

**On reconnect:**
- Phone sends `REQUEST_UPLOAD` over BLE
- Device streams all stored chunks using a 244-byte fixed packet protocol
- Phone reassembles packets, decodes Opus, and saves WAV files
- Silence detection splits recordings into conversation segments
- Audio stitcher removes silence and produces clean output files
- Device deletes each chunk after the phone ACKs it

---

## Repo structure

```
omi/firmware/omi/src/
  reclo_recorder.h/.c     — 30-second chunk recorder (hooks into codec via set_codec_callback)
  reclo_transfer.h/.c     — BLE GATT service + chunk upload protocol + SD card storage
  lib/core/
    transport.c           — Omi GATT services (audio, settings, time sync, features)
    settings.c            — LED dimming + mic gain persistence (Zephyr settings subsystem)
    codec.c               — Opus encoder pipeline
    mic.c                 — PDM microphone driver

app/lib/
  services/
    chunk_upload_service.dart        — BLE packet reassembly, Opus decode, WAV save
    audio_stitcher.dart              — Combines speech segments, removes silence
    silence_detection_service.dart   — RMS-based silence/speech segmentation
    audio_chunk_manager.dart         — Chunk + conversation data models
  services/devices/
    device_connection.dart           — BleTransport + DeviceConnection base classes
    omi_connection.dart              — Omi GATT connection (time sync, battery, settings)
    models.dart                      — BLE UUID constants
  pages/
    device_settings_screen.dart      — LED brightness + mic gain controls (auto-detected)
```

---

## BLE transfer protocol

**RecLo GATT service:** `5c7d0001-b5a3-4f43-c0a9-e50e24dc0000`

| Characteristic | UUID suffix | Direction |
|---|---|---|
| Data | `...0001` | Device → Phone (NOTIFY) |
| Control | `...0002` | Phone → Device (WRITE) |

**Fixed 244-byte packet layout:**

```
[0]       packet_type     (0x01=HEADER, 0x02=DATA, 0x03=DONE)
[1..4]    chunk_timestamp (Unix epoch seconds, uint32 LE)
[5..6]    chunk_index     (uint16 LE, 0-based)
[7..8]    total_chunks    (uint16 LE)
[9..10]   seq             (uint16 LE, 0=header packet)
[11..12]  total_seqs      (uint16 LE)
[13..14]  payload_len     (uint16 LE, bytes used in payload)
[15..243] payload         (229 bytes)
```

HEADER payload (13 bytes): `data_size(4) + codec_id(1) + sample_rate(4) + crc32(4)`

**Control commands (phone → device):**
- `0x01` — REQUEST_UPLOAD: start sending all stored chunks
- `0x02 + timestamp(4 bytes LE)` — ACK_CHUNK: chunk received, device deletes it
- `0x03` — ABORT: stop upload

**Chunk file format on SD card** (`/SD:/reclo/XXXXXXXXXX.bin`):

17-byte header: `RCLO`(4) + unix_ts(4) + codec_id(1) + sample_rate(4) + data_size(4)

Followed by length-prefixed Opus frames: `[2-byte LE length][frame bytes]` repeated.

---

## Device settings

The app detects LED brightness and mic gain support at connect time by probing the settings GATT service (`19b10010-...`). If the device responds, slider controls appear in Device Settings automatically.

| Setting | BLE characteristic | Range |
|---|---|---|
| LED Brightness | `19b10011-...` | 0–100% |
| Mic Gain | `19b10012-...` | Mute, -20 dB … +40 dB |

Changes are written immediately and persisted to flash on the device.

---

## Flutter app

```bash
cd app
flutter pub get
flutter run
```

Requires Flutter 3.x. Key dependencies: `flutter_blue_plus` (BLE), `opus_dart` (Opus decoding), `provider` (state management).

WAV files are saved to `<documents>/audio_chunks/`. Stitched conversations go to `<documents>/conversations/`.

---

## Firmware

Zephyr RTOS on nRF5340. The RecLo recorder hooks into the existing Omi codec pipeline — PCM flows from the PDM mic through the Opus encoder, and `set_codec_callback` delivers encoded frames directly to the chunk recorder instead of streaming over BLE.

Build and flash instructions: [`omi/firmware/BUILD_AND_OTA_FLASH.md`](omi/firmware/BUILD_AND_OTA_FLASH.md)

---

## License

MIT
