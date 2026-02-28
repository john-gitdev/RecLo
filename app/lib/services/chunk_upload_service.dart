import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;
import 'package:opus_dart/opus_dart.dart';

import 'package:reclo/backend/schema/bt_device/bt_device.dart';
import 'package:reclo/services/audio_chunk_manager.dart';
import 'package:reclo/services/audio_stitcher.dart';
import 'package:reclo/services/devices/device_connection.dart';
import 'package:reclo/services/silence_detection_service.dart';

// ─── Protocol constants ───────────────────────────────────────────────────────

/// BLE service and characteristic UUIDs exposed by the RecLo firmware.
const String recloTransferServiceUuid  = '5c7d0001-b5a3-4f43-c0a9-e50e24dc0000';
const String recloDataCharUuid         = '5c7d0001-b5a3-4f43-c0a9-e50e24dc0001';
const String recloControlCharUuid      = '5c7d0001-b5a3-4f43-c0a9-e50e24dc0002';

const int _kPacketSize  = 244;
const int _kHeaderSize  = 15;
const int _kPayloadSize = 229; // _kPacketSize - _kHeaderSize

// Packet types (device → phone)
const int _kPktChunkHeader = 0x01;
const int _kPktChunkData   = 0x02;
const int _kPktUploadDone  = 0x03;

// Control commands (phone → device)
const int _kCmdRequestUpload = 0x01;
const int _kCmdAckChunk      = 0x02; // + 4-byte LE timestamp
const int _kCmdAbort         = 0x03;

// ─── Progress model ───────────────────────────────────────────────────────────

class UploadProgress {
  final int chunksReceived;
  final int totalChunks;
  final bool isComplete;
  final String? error;

  const UploadProgress({
    required this.chunksReceived,
    required this.totalChunks,
    this.isComplete = false,
    this.error,
  });

  double get fraction =>
      totalChunks == 0 ? 0.0 : chunksReceived / totalChunks;

  @override
  String toString() =>
      'UploadProgress($chunksReceived/$totalChunks, complete=$isComplete)';
}

// ─── Internal chunk assembly state ───────────────────────────────────────────

class _IncomingChunk {
  final int timestamp;    // Unix epoch seconds
  final int chunkIndex;
  final int totalChunks;
  final int totalSeqs;    // total packets including the header packet
  final int dataSize;     // expected Opus byte count
  final int codecId;
  final int sampleRate;
  final int expectedCrc32;

  final List<int> buffer = []; // accumulates raw Opus bytes
  int seqsReceived = 1;        // header is seq 0 and already "processed"

  _IncomingChunk({
    required this.timestamp,
    required this.chunkIndex,
    required this.totalChunks,
    required this.totalSeqs,
    required this.dataSize,
    required this.codecId,
    required this.sampleRate,
    required this.expectedCrc32,
  });

  bool get isComplete => seqsReceived >= totalSeqs;
}

// ─── ChunkUploadService ───────────────────────────────────────────────────────

/// Manages the offline BLE chunk upload from a RecLo device.
///
/// Usage:
/// ```dart
/// final svc = ChunkUploadService(transport: transport);
/// svc.progress.listen((p) => print(p));
/// await svc.start();
/// // … wait for isComplete …
/// await svc.dispose();
/// ```
///
/// The service:
///   1. Subscribes to the RecLo data characteristic.
///   2. Writes REQUEST_UPLOAD to the control characteristic.
///   3. Reassembles 244-byte packets into Opus chunks.
///   4. Decodes Opus → PCM16, runs silence analysis, saves WAV files.
///   5. ACKs each chunk so the device can delete it from flash.
///   6. On UPLOAD_DONE, groups chunks into conversations and stitches them.
class ChunkUploadService {
  final DeviceTransport _transport;
  final double silenceThresholdDb;
  final Duration conversationGapThreshold;
  final void Function(Conversation conversation)? onConversationReady;

  final _silenceService = SilenceDetectionService();
  final _stitcher = AudioStitcher();

  final _progressController = StreamController<UploadProgress>.broadcast();
  Stream<UploadProgress> get progress => _progressController.stream;

  StreamSubscription<List<int>>? _dataSub;
  _IncomingChunk? _current;
  final List<AudioChunk> _completedChunks = [];

  bool _opusReady = false;
  SimpleOpusDecoder? _opusDecoder;

  ChunkUploadService({
    required DeviceTransport transport,
    this.silenceThresholdDb = -40.0,
    this.conversationGapThreshold = const Duration(minutes: 2),
    this.onConversationReady,
  }) : _transport = transport;

  // ─── Lifecycle ──────────────────────────────────────────────────────────────

  /// Subscribe to BLE notifications and request the upload.
  Future<void> start() async {
    await _initOpus();
    _completedChunks.clear();
    _current = null;

    _dataSub = _transport
        .getCharacteristicStream(recloTransferServiceUuid, recloDataCharUuid)
        .listen(_onPacket, onError: (e) {
      debugPrint('ChunkUploadService: stream error: $e');
      _progressController.add(UploadProgress(
        chunksReceived: _completedChunks.length,
        totalChunks: _completedChunks.length,
        error: e.toString(),
      ));
    });

    // Small delay so notification subscription is confirmed before we request.
    await Future.delayed(const Duration(milliseconds: 150));

    await _transport.writeCharacteristic(
      recloTransferServiceUuid,
      recloControlCharUuid,
      [_kCmdRequestUpload],
    );
    debugPrint('ChunkUploadService: upload requested');
  }

  /// Abort the upload and release resources.
  Future<void> stop() async {
    try {
      await _transport.writeCharacteristic(
        recloTransferServiceUuid,
        recloControlCharUuid,
        [_kCmdAbort],
      );
    } catch (_) {}
    await _dataSub?.cancel();
    _dataSub = null;
  }

  Future<void> dispose() async {
    await stop();
    _opusDecoder?.destroy();
    _opusDecoder = null;
    await _progressController.close();
  }

  // ─── Packet dispatch ─────────────────────────────────────────────────────────

  void _onPacket(List<int> rawBytes) {
    if (rawBytes.length != _kPacketSize) {
      debugPrint('ChunkUploadService: unexpected packet size ${rawBytes.length}');
      return;
    }
    final data = Uint8List.fromList(rawBytes);
    final pktType = data[0];

    switch (pktType) {
      case _kPktChunkHeader:
        _handleHeader(data);
      case _kPktChunkData:
        _handleData(data);
      case _kPktUploadDone:
        _handleUploadDone();
      default:
        debugPrint('ChunkUploadService: unknown packet type 0x${pktType.toRadixString(16)}');
    }
  }

  // ─── Header packet ────────────────────────────────────────────────────────────
  //
  // Byte layout (matches RecloPacket in reclo_transfer.h):
  //   [0]      pkt_type
  //   [1..4]   chunk_ts     (uint32 LE)
  //   [5..6]   chunk_idx    (uint16 LE)
  //   [7..8]   total_chunks (uint16 LE)
  //   [9..10]  seq          (uint16 LE)  — always 0 for header
  //   [11..12] total_seqs   (uint16 LE)
  //   [13..14] payload_len  (uint16 LE)
  //   [15..]   payload      (RecloChunkMeta, 13 bytes):
  //     [15..18] data_size   (uint32 LE)
  //     [19]     codec_id
  //     [20..23] sample_rate (uint32 LE)
  //     [24..27] crc32       (uint32 LE)

  void _handleHeader(Uint8List data) {
    final v = ByteData.sublistView(data);

    final ts          = v.getUint32(1,  Endian.little);
    final chunkIdx    = v.getUint16(5,  Endian.little);
    final totalChunks = v.getUint16(7,  Endian.little);
    final totalSeqs   = v.getUint16(11, Endian.little);
    final payloadLen  = v.getUint16(13, Endian.little);

    if (payloadLen < 13) {
      debugPrint('ChunkUploadService: header payload too short ($payloadLen bytes)');
      return;
    }

    final dataSize   = v.getUint32(15, Endian.little);
    final codecId    = data[19];
    final sampleRate = v.getUint32(20, Endian.little);
    final crc32      = v.getUint32(24, Endian.little);

    _current = _IncomingChunk(
      timestamp:    ts,
      chunkIndex:   chunkIdx,
      totalChunks:  totalChunks,
      totalSeqs:    totalSeqs,
      dataSize:     dataSize,
      codecId:      codecId,
      sampleRate:   sampleRate,
      expectedCrc32: crc32,
    );

    debugPrint('ChunkUploadService: chunk $chunkIdx/$totalChunks '
        'ts=$ts size=$dataSize seqs=$totalSeqs');
  }

  // ─── Data packet ──────────────────────────────────────────────────────────────

  void _handleData(Uint8List data) {
    if (_current == null) return;

    final v          = ByteData.sublistView(data);
    final payloadLen = v.getUint16(13, Endian.little);

    if (payloadLen == 0 || payloadLen > _kPayloadSize) return;

    _current!.buffer.addAll(data.sublist(_kHeaderSize, _kHeaderSize + payloadLen));
    _current!.seqsReceived++;

    if (_current!.isComplete) {
      final chunk = _current!;
      _current = null;
      _finalizeChunk(chunk);
    }
  }

  // ─── Chunk finalization ───────────────────────────────────────────────────────

  Future<void> _finalizeChunk(_IncomingChunk incoming) async {
    final opusBytes = Uint8List.fromList(incoming.buffer);

    // Decode length-prefixed Opus frames → interleaved PCM16 samples
    final pcmBytes = _decodeOpusFrames(opusBytes);

    // Derive a DateTime from the device-side Unix timestamp
    final startTime = DateTime.fromMillisecondsSinceEpoch(
      incoming.timestamp * 1000,
      isUtc: true,
    ).toLocal();

    final chunkId  = 'chunk_${incoming.timestamp}';
    final filePath = await _saveWav(pcmBytes, chunkId, incoming.sampleRate);

    final analysis = _silenceService.analyze(
      pcmBytes: pcmBytes,
      format:   PcmFormat.pcm16bit,
      silenceThresholdDb: silenceThresholdDb,
    );

    final chunk = AudioChunk(
      id:             chunkId,
      startTime:      startTime,
      filePath:       filePath,
      codec:          BleAudioCodec.opusFS320,
      sampleRate:     incoming.sampleRate,
      silenceAnalysis: analysis,
      isComplete:     true,
    );

    _completedChunks.add(chunk);

    // ACK the device so it can free the flash storage
    await _sendAck(incoming.timestamp);

    _progressController.add(UploadProgress(
      chunksReceived: _completedChunks.length,
      totalChunks:    incoming.totalChunks,
    ));

    debugPrint('ChunkUploadService: saved $chunkId '
        '(speech=${analysis.totalSpeech.inSeconds}s)');
  }

  // ─── Upload done ──────────────────────────────────────────────────────────────

  void _handleUploadDone() {
    debugPrint('ChunkUploadService: upload done — '
        '${_completedChunks.length} chunk(s) received');

    _progressController.add(UploadProgress(
      chunksReceived: _completedChunks.length,
      totalChunks:    _completedChunks.length,
      isComplete:     true,
    ));

    _processConversations();
  }

  // ─── Post-processing: group + stitch ─────────────────────────────────────────

  Future<void> _processConversations() async {
    if (_completedChunks.isEmpty) return;

    // Walk the chunks chronologically, splitting on silence boundaries.
    final List<List<AudioChunk>> groups = [];
    List<AudioChunk> currentGroup = [];
    final List<SilenceAnalysisResult> recentAnalyses = [];

    for (final chunk in _completedChunks) {
      currentGroup.add(chunk);

      if (chunk.silenceAnalysis != null) {
        recentAnalyses.add(chunk.silenceAnalysis!);
      }

      final isBoundary = _silenceService.isConversationBoundary(
        recentChunks:    recentAnalyses,
        silenceThreshold: conversationGapThreshold,
      );

      if (isBoundary) {
        groups.add(List.from(currentGroup));
        currentGroup = [];
        recentAnalyses.clear();
      }
    }

    if (currentGroup.isNotEmpty) groups.add(currentGroup);

    // Stitch each group into a single WAV
    for (final group in groups) {
      final speechChunks = group.where((c) => c.hasSpeech).toList();
      if (speechChunks.isEmpty) continue;

      final conv = Conversation(
        id:        'conv_${speechChunks.first.startTime.millisecondsSinceEpoch}',
        startTime: speechChunks.first.startTime,
        endTime:   speechChunks.last.endTime,
        chunks:    speechChunks,
      );

      final result = await _stitcher.stitch(
        conversation:       conv,
        silenceThresholdDb: silenceThresholdDb,
      );

      if (result.success) {
        debugPrint('ChunkUploadService: stitched ${conv.id} '
            '→ ${result.outputPath} '
            '(${result.totalDuration.inSeconds}s speech, '
            '${result.silenceRemoved.inSeconds}s silence removed)');
        conv.stitchedFilePath = result.outputPath;
        onConversationReady?.call(conv);
      } else {
        debugPrint('ChunkUploadService: stitch failed: ${result.error}');
      }
    }
  }

  // ─── Helpers ─────────────────────────────────────────────────────────────────

  Future<void> _initOpus() async {
    if (_opusReady) return;
    try {
      initOpus(await opus_flutter.load());
      _opusDecoder = SimpleOpusDecoder(sampleRate: 16000, channels: 1);
      _opusReady = true;
    } catch (e) {
      debugPrint('ChunkUploadService: Opus init error: $e');
    }
  }

  /// Decode a buffer of length-prefixed Opus frames into raw PCM16 bytes.
  ///
  /// Storage format: [2-byte LE frame_len][frame bytes] repeated.
  /// Each frame is decoded individually by the Opus decoder.
  Uint8List _decodeOpusFrames(Uint8List opusData) {
    if (_opusDecoder == null) return opusData; // fallback: return raw bytes

    final pcm = BytesBuilder();
    int offset = 0;

    while (offset + 2 <= opusData.length) {
      final frameLen = opusData[offset] | (opusData[offset + 1] << 8);
      offset += 2;

      if (frameLen == 0 || offset + frameLen > opusData.length) break;

      try {
        final frame    = opusData.sublist(offset, offset + frameLen);
        final decoded  = _opusDecoder!.decode(input: frame);
        pcm.add(decoded.buffer.asUint8List());
      } catch (e) {
        debugPrint('ChunkUploadService: frame decode error at offset $offset: $e');
      }

      offset += frameLen;
    }

    return pcm.toBytes();
  }

  /// Save raw PCM16 bytes as a WAV file in the audio_chunks directory.
  Future<String> _saveWav(Uint8List pcmBytes, String chunkId, int sampleRate) async {
    final dir       = await getApplicationDocumentsDirectory();
    final chunksDir = Directory('${dir.path}/audio_chunks');
    if (!await chunksDir.exists()) await chunksDir.create(recursive: true);

    final file    = File('${chunksDir.path}/$chunkId.wav');
    final builder = BytesBuilder();
    builder.add(_buildWavHeader(pcmBytes.length, sampleRate, channels: 1, bitDepth: 16));
    builder.add(pcmBytes);
    await file.writeAsBytes(builder.toBytes());
    return file.path;
  }

  /// Send a 5-byte ACK_CHUNK command to the device.
  Future<void> _sendAck(int timestamp) async {
    final ack = ByteData(5)
      ..setUint8(0,  _kCmdAckChunk)
      ..setUint32(1, timestamp, Endian.little);
    try {
      await _transport.writeCharacteristic(
        recloTransferServiceUuid,
        recloControlCharUuid,
        ack.buffer.asUint8List(),
      );
    } catch (e) {
      debugPrint('ChunkUploadService: ACK write failed: $e');
    }
  }

  /// Build a standard 44-byte WAV header for PCM audio.
  Uint8List _buildWavHeader(
    int dataSize,
    int sampleRate, {
    required int channels,
    required int bitDepth,
  }) {
    final bytesPerSample = bitDepth ~/ 8;
    final byteRate       = sampleRate * channels * bytesPerSample;
    final blockAlign     = channels * bytesPerSample;
    final hdr            = ByteData(44);

    // RIFF chunk descriptor
    hdr.setUint8(0, 0x52); hdr.setUint8(1, 0x49); // 'R','I'
    hdr.setUint8(2, 0x46); hdr.setUint8(3, 0x46); // 'F','F'
    hdr.setUint32(4, dataSize + 36, Endian.little);
    hdr.setUint8(8, 0x57); hdr.setUint8(9, 0x41);  // 'W','A'
    hdr.setUint8(10, 0x56); hdr.setUint8(11, 0x45); // 'V','E'

    // fmt sub-chunk
    hdr.setUint8(12, 0x66); hdr.setUint8(13, 0x6D); // 'f','m'
    hdr.setUint8(14, 0x74); hdr.setUint8(15, 0x20); // 't',' '
    hdr.setUint32(16, 16,          Endian.little); // PCM fmt size
    hdr.setUint16(20, 1,           Endian.little); // PCM format
    hdr.setUint16(22, channels,    Endian.little);
    hdr.setUint32(24, sampleRate,  Endian.little);
    hdr.setUint32(28, byteRate,    Endian.little);
    hdr.setUint16(32, blockAlign,  Endian.little);
    hdr.setUint16(34, bitDepth,    Endian.little);

    // data sub-chunk
    hdr.setUint8(36, 0x64); hdr.setUint8(37, 0x61); // 'd','a'
    hdr.setUint8(38, 0x74); hdr.setUint8(39, 0x61); // 't','a'
    hdr.setUint32(40, dataSize, Endian.little);

    return hdr.buffer.asUint8List();
  }
}
