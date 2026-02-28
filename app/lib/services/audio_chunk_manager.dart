import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;
import 'package:opus_dart/opus_dart.dart';

import 'package:reclo/backend/schema/bt_device/bt_device.dart';
import 'package:reclo/services/silence_detection_service.dart';

class AudioChunk {
  final String id;
  final DateTime startTime;
  final String filePath;
  final BleAudioCodec codec;
  final int sampleRate;
  SilenceAnalysisResult? silenceAnalysis;
  bool isComplete;

  AudioChunk({
    required this.id,
    required this.startTime,
    required this.filePath,
    required this.codec,
    required this.sampleRate,
    this.silenceAnalysis,
    this.isComplete = false,
  });

  DateTime get endTime => startTime.add(const Duration(seconds: 15));

  bool get hasSpeech => silenceAnalysis != null && !silenceAnalysis!.isEntirelySilent;
}

class Conversation {
  final String id;
  final DateTime startTime;
  final DateTime endTime;
  final List<AudioChunk> chunks;
  String? stitchedFilePath;

  Conversation({
    required this.id,
    required this.startTime,
    required this.endTime,
    required this.chunks,
    this.stitchedFilePath,
  });

  Duration get duration => endTime.difference(startTime);

  Duration get totalSpeech => chunks.fold(
        Duration.zero,
        (sum, c) => sum + (c.silenceAnalysis?.totalSpeech ?? Duration.zero),
      );
}

class AudioChunkManager {
  final SilenceDetectionService _silenceService = SilenceDetectionService();

  double silenceThresholdDb;
  Duration conversationGapThreshold;

  BleAudioCodec? _codec;
  SimpleOpusDecoder? _opusDecoder;
  bool _isOpusInitialized = false;
  
  final List<int> _currentBuffer = [];
  final List<int> _audioPacketBuffer = []; // NEW: Holds fragmented packets
  DateTime? _chunkStartTime;
  Timer? _chunkTimer;

  final List<AudioChunk> _completedChunks = [];
  final List<SilenceAnalysisResult> _recentAnalyses = [];

  final void Function(AudioChunk chunk)? onChunkCompleted;
  final void Function(Conversation conversation)? onConversationDetected;

  static const int _maxRecentAnalyses = 10;

  AudioChunkManager({
    this.silenceThresholdDb = -40.0,
    this.conversationGapThreshold = const Duration(minutes: 2),
    this.onChunkCompleted,
    this.onConversationDetected,
  });

  Future<void> start(BleAudioCodec codec) async {
    _codec = codec;
    
    if (_codec == BleAudioCodec.opus || _codec == BleAudioCodec.opusFS320) {
      if (!_isOpusInitialized) {
        try {
          initOpus(await opus_flutter.load());
          _isOpusInitialized = true;
        } catch (e) {
          debugPrint('AudioChunkManager: Opus Init Note: $e');
        }
      }
      _opusDecoder = SimpleOpusDecoder(sampleRate: 16000, channels: 1);
      debugPrint('AudioChunkManager: Opus Decoder Initialized');
    } else {
      _opusDecoder = null;
    }
    
    _startNewChunk();
  }

  void addAudioBytes(List<int> bytes) {
    if (_codec == null || bytes.length < 3) return;

    // The Omi device uses a 3-byte header for all audio packets
    // bytes[0] & bytes[1]: Sequence Number
    // bytes[2]: Fragment Index
    int index = bytes[2];

    if (index == 0) {
      // A new packet has started. Decode the accumulated previous packet if it exists.
      if (_audioPacketBuffer.isNotEmpty) {
        _decodeAndAppend(_audioPacketBuffer);
        _audioPacketBuffer.clear();
      }
    }
    
    // Append the payload (strip the 3-byte header)
    _audioPacketBuffer.addAll(bytes.sublist(3));
  }

  void _decodeAndAppend(List<int> payload) {
    if (_opusDecoder != null) {
      try {
        final pcm = _opusDecoder!.decode(input: Uint8List.fromList(payload));
        _currentBuffer.addAll(pcm.buffer.asUint8List());
      } catch (e) {
        debugPrint('AudioChunkManager: Opus decode error: $e');
      }
    } else {
      _currentBuffer.addAll(payload);
    }
  }

  void stop() {
    _chunkTimer?.cancel();
    _flushCurrentChunk();
    _opusDecoder?.destroy();
    _opusDecoder = null;
  }

  void dispose() {
    _chunkTimer?.cancel();
    _opusDecoder?.destroy();
  }

  void _startNewChunk() {
    _chunkTimer?.cancel();
    _currentBuffer.clear();
    _chunkStartTime = DateTime.now();
    _chunkTimer = Timer(const Duration(seconds: 15), _flushCurrentChunk);
  }

  Future<void> _flushCurrentChunk() async {
    // Flush any remaining packets in the buffer before closing the chunk
    if (_audioPacketBuffer.isNotEmpty) {
      _decodeAndAppend(_audioPacketBuffer);
      _audioPacketBuffer.clear();
    }

    if (_codec == null || _currentBuffer.isEmpty) {
      _startNewChunk();
      return;
    }

    final bytes = Uint8List.fromList(_currentBuffer);
    final startTime = _chunkStartTime ?? DateTime.now();
    final chunkId = 'chunk_${startTime.millisecondsSinceEpoch}';

    final filePath = await _saveChunkToDisk(bytes, chunkId);

    final format = _codec == BleAudioCodec.pcm8 ? PcmFormat.pcm8bit : PcmFormat.pcm16bit;
    final analysis = _silenceService.analyze(
      pcmBytes: bytes,
      format: format,
      silenceThresholdDb: silenceThresholdDb,
    );

    final chunk = AudioChunk(
      id: chunkId,
      startTime: startTime,
      filePath: filePath,
      codec: _codec!,
      sampleRate: 16000,
      silenceAnalysis: analysis,
      isComplete: true,
    );

    _completedChunks.add(chunk);
    _recentAnalyses.add(analysis);

    if (_recentAnalyses.length > _maxRecentAnalyses) {
      _recentAnalyses.removeAt(0);
    }

    onChunkCompleted?.call(chunk);

    final isBoundary = _silenceService.isConversationBoundary(
      recentChunks: _recentAnalyses,
      silenceThreshold: conversationGapThreshold,
    );

    if (isBoundary) {
      _finalizeConversation();
    }

    _startNewChunk();
  }

  void _finalizeConversation() {
    final speechChunks = _completedChunks.where((c) => c.hasSpeech).toList();

    if (speechChunks.isEmpty) return;

    final conversation = Conversation(
      id: 'conv_${speechChunks.first.startTime.millisecondsSinceEpoch}',
      startTime: speechChunks.first.startTime,
      endTime: speechChunks.last.endTime,
      chunks: List.from(speechChunks),
    );

    _completedChunks.removeWhere((c) => speechChunks.contains(c));
    _recentAnalyses.clear();

    onConversationDetected?.call(conversation);
  }

  void finalizeNow() {
    _flushCurrentChunk();
    _finalizeConversation();
  }

  Future<String> _saveChunkToDisk(Uint8List bytes, String chunkId) async {
    final dir = await getApplicationDocumentsDirectory();
    final chunksDir = Directory('${dir.path}/audio_chunks');
    if (!await chunksDir.exists()) {
      await chunksDir.create(recursive: true);
    }
    
    final file = File('${chunksDir.path}/$chunkId.wav');
    
    final bitDepth = _codec == BleAudioCodec.pcm8 ? 8 : 16;
    final builder = BytesBuilder();
    builder.add(_buildWavHeader(bytes.length, 16000, 1, bitDepth));
    builder.add(bytes);
    
    await file.writeAsBytes(builder.toBytes());
    return file.path;
  }

  Uint8List _buildWavHeader(int dataSize, int sampleRate, int channels, int bitDepth) {
    final bytesPerSample = bitDepth ~/ 8;
    final byteRate = sampleRate * channels * bytesPerSample;
    final blockAlign = channels * bytesPerSample;
    final fileSize = dataSize + 36;
    final header = ByteData(44);

    header.setUint8(0, 82); header.setUint8(1, 73); header.setUint8(2, 70); header.setUint8(3, 70);
    header.setUint32(4, fileSize, Endian.little);
    header.setUint8(8, 87); header.setUint8(9, 65); header.setUint8(10, 86); header.setUint8(11, 69);
    header.setUint8(12, 102); header.setUint8(13, 109); header.setUint8(14, 116); header.setUint8(15, 32);
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, bitDepth, Endian.little);
    header.setUint8(36, 100); header.setUint8(37, 97); header.setUint8(38, 116); header.setUint8(39, 97);
    header.setUint32(40, dataSize, Endian.little);

    return header.buffer.asUint8List();
  }
}