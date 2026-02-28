# RecLo

A wearable audio recorder that captures offline and syncs to your phone over BLE when you reconnect.

Built on the Omi nRF5340 hardware. The device records continuously without needing a phone present. When you reconnect, it batch-uploads everything.

---

## How it works

**On device:**
- Records audio as 15-second Opus chunks (16 kHz, 32 kbps)
- Timestamps each chunk with RTC at the moment recording started
- Stores chunks on flash (`/lfs/reclo/`) until the phone picks them up

**On connect:**
- Device uploads all stored chunks over BLE using a fixed 244-byte packet protocol
- Phone reassembles packets → decodes Opus → saves WAV files
- Silence detection splits recordings into conversations
- Audio stitcher removes silence and produces clean output files
- Device deletes each chunk after the phone ACKs it

---

## Repo structure

```
firmware/src/
  reclo_recorder.h/.c     — 15-second chunk recorder (hooks into Omi codec pipeline)
  reclo_transfer.h/.c     — BLE GATT service + chunk upload protocol

omi/firmware/             — Reference Omi firmware (not modified)

app/lib/
  services/
    chunk_upload_service.dart   — BLE packet reassembly, Opus decode, WAV save
    audio_chunk_manager.dart    — Live streaming chunk manager (reference)
    audio_stitcher.dart         — Combines speech segments, removes silence
    silence_detection_service.dart — RMS-based silence/speech segmentation
  services/devices/
    device_connection.dart      — BleTransport + DeviceConnection base
    omi_connection.dart         — Omi GATT connection (time sync, battery, audio)
    models.dart                 — BLE UUID constants
```

---

## BLE transfer protocol

Two new GATT characteristics on the device:

| Characteristic | UUID | Direction |
|---|---|---|
| Data | `5c7d0001-...-e50e24dc0001` | Device → Phone (NOTIFY) |
| Control | `5c7d0001-...-e50e24dc0002` | Phone → Device (WRITE) |

**Fixed 244-byte packet layout:**

```
[0]       packet_type     (0x01=HEADER, 0x02=DATA, 0x03=DONE)
[1..4]    chunk_timestamp (Unix epoch, uint32 LE)
[5..6]    chunk_index     (uint16 LE)
[7..8]    total_chunks    (uint16 LE)
[9..10]   seq             (uint16 LE, 0=header)
[11..12]  total_seqs      (uint16 LE)
[13..14]  payload_len     (uint16 LE)
[15..243] payload         (229 bytes)
```

HEADER payload (13 bytes): `data_size(4) + codec_id(1) + sample_rate(4) + crc32(4)`

**Control commands (phone → device):**
- `0x01` — REQUEST_UPLOAD
- `0x02 + timestamp(4)` — ACK_CHUNK (device deletes the chunk)
- `0x03` — ABORT

**Chunk storage on flash:**
17-byte header (`RCLO` magic + timestamp + codec + sample_rate + data_size) followed by length-prefixed Opus frames (`[2-byte LE len][frame bytes]` repeated).

---

## Flutter app setup

```bash
cd app
flutter pub get
flutter run
```

Requires Flutter 3.x. Uses `flutter_blue_plus` for BLE and `opus_dart` for decoding.

---

## Firmware

The RecLo firmware files (`firmware/src/`) are written for Zephyr RTOS on the nRF5340. They integrate with the Omi codec pipeline via `set_codec_callback()` and add a new GATT service on top of the existing Omi services.

See `omi/firmware/BUILD_AND_OTA_FLASH.md` for build and flash instructions.

---

## License

MIT
