import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'package:reclo/backend/schema/bt_device/bt_device.dart';
import 'package:reclo/services/audio_chunk_manager.dart';
import 'package:reclo/services/silence_detection_service.dart';

/// Result of a stitch operation
class StitchResult {
  final bool success;
  final String? outputPath;
  final Duration totalDuration;
  final Duration silenceRemoved;
  final String? error;

  StitchResult({
    required this.success,
    this.outputPath,
    required this.totalDuration,
    required this.silenceRemoved,
    this.error,
  });
}

/// Stitches audio chunks into a single WAV file, stripping silence
class AudioStitcher {
  /// Stitch a conversation's chunks into one WAV file.
  ///
  /// [conversation]         - The conversation to stitch
  /// [silenceThresholdDb]   - dB threshold (user-settable, same as detection)
  /// [outputFileName]       - Optional custom output filename
  Future<StitchResult> stitch({
    required Conversation conversation,
    required double silenceThresholdDb,
    String? outputFileName,
  }) async {
    try {
      final List<Uint8List> speechSegments = [];
      Duration totalSilenceRemoved = Duration.zero;
      Duration totalSpeech = Duration.zero;

      for (final chunk in conversation.chunks) {
        // Skip chunks with no speech
        if (!chunk.hasSpeech) continue;

        // Read raw bytes from disk
        final file = File(chunk.filePath);
        if (!await file.exists()) continue;
        final raw = await file.readAsBytes();

        // Strip the 44-byte WAV header so we only process PCM samples
        const int wavHeaderBytes = 44;
        final bytes = raw.length > wavHeaderBytes
            ? raw.sublist(wavHeaderBytes)
            : raw;

        final analysis = chunk.silenceAnalysis;
        if (analysis == null) {
          // No analysis — include entire chunk
          speechSegments.add(bytes);
          continue;
        }

        // Extract only speech segments from this chunk
        final extracted = _extractSpeechBytes(
          bytes: bytes,
          analysis: analysis,
          codec: chunk.codec,
          sampleRate: chunk.sampleRate,
        );

        speechSegments.addAll(extracted.segments);
        totalSilenceRemoved += extracted.silenceRemoved;
        totalSpeech += extracted.speechDuration;
      }

      if (speechSegments.isEmpty) {
        return StitchResult(
          success: false,
          totalDuration: Duration.zero,
          silenceRemoved: Duration.zero,
          error: 'No speech segments found',
        );
      }

      // Combine all speech segments
      final combined = _combineSegments(speechSegments);

      // Get sample rate and bit depth from first chunk with speech
      final firstChunk = conversation.chunks.firstWhere((c) => c.hasSpeech);
      final sampleRate = firstChunk.sampleRate;
      final bitDepth = mapCodecToBitDepth(firstChunk.codec);

      // Write WAV file
      final outputPath = await _writeWavFile(
        pcmBytes: combined,
        sampleRate: sampleRate,
        bitDepth: bitDepth,
        channels: 1,
        fileName: outputFileName ?? 'conversation_${conversation.id}.wav',
      );

      return StitchResult(
        success: true,
        outputPath: outputPath,
        totalDuration: totalSpeech,
        silenceRemoved: totalSilenceRemoved,
      );
    } catch (e) {
      return StitchResult(
        success: false,
        totalDuration: Duration.zero,
        silenceRemoved: Duration.zero,
        error: e.toString(),
      );
    }
  }

  // ─── Private ───────────────────────────────────────────────────────────────

  _ExtractedAudio _extractSpeechBytes({
    required Uint8List bytes,
    required SilenceAnalysisResult analysis,
    required BleAudioCodec codec,
    required int sampleRate,
  }) {
    final bytesPerSample = mapCodecToBitDepth(codec) == 8 ? 1 : 2;
    final bytesPerMs = (sampleRate * bytesPerSample / 1000).round();

    final List<Uint8List> segments = [];
    Duration silenceRemoved = Duration.zero;
    Duration speechDuration = Duration.zero;

    for (final segment in analysis.segments) {
      if (segment.isSilent) {
        silenceRemoved += segment.duration;
        continue;
      }

      // Extract bytes for this speech segment
      final startByte = (segment.start.inMilliseconds * bytesPerMs)
          .clamp(0, bytes.length);
      final endByte = (segment.end.inMilliseconds * bytesPerMs)
          .clamp(0, bytes.length);

      if (endByte > startByte) {
        segments.add(bytes.sublist(startByte, endByte));
        speechDuration += segment.duration;
      }
    }

    return _ExtractedAudio(
      segments: segments,
      silenceRemoved: silenceRemoved,
      speechDuration: speechDuration,
    );
  }

  Uint8List _combineSegments(List<Uint8List> segments) {
    final totalLength = segments.fold(0, (sum, s) => sum + s.length);
    final combined = Uint8List(totalLength);
    int offset = 0;
    for (final segment in segments) {
      combined.setRange(offset, offset + segment.length, segment);
      offset += segment.length;
    }
    return combined;
  }

  Future<String> _writeWavFile({
    required Uint8List pcmBytes,
    required int sampleRate,
    required int bitDepth,
    required int channels,
    required String fileName,
  }) async {
    final dir = await getApplicationDocumentsDirectory();
    final convsDir = Directory('${dir.path}/conversations');
    if (!await convsDir.exists()) {
      await convsDir.create(recursive: true);
    }

    final outputPath = '${convsDir.path}/$fileName';
    final wavBytes = _buildWavFile(
      pcmBytes: pcmBytes,
      sampleRate: sampleRate,
      bitDepth: bitDepth,
      channels: channels,
    );

    await File(outputPath).writeAsBytes(wavBytes);
    return outputPath;
  }

  /// Build a standard WAV file from raw PCM bytes
  Uint8List _buildWavFile({
    required Uint8List pcmBytes,
    required int sampleRate,
    required int bitDepth,
    required int channels,
  }) {
    final byteRate = sampleRate * channels * (bitDepth ~/ 8);
    final blockAlign = channels * (bitDepth ~/ 8);
    final dataSize = pcmBytes.length;
    final chunkSize = 36 + dataSize;

    final header = ByteData(44);

    // RIFF chunk
    header.setUint8(0, 0x52); // R
    header.setUint8(1, 0x49); // I
    header.setUint8(2, 0x46); // F
    header.setUint8(3, 0x46); // F
    header.setUint32(4, chunkSize, Endian.little);
    header.setUint8(8, 0x57);  // W
    header.setUint8(9, 0x41);  // A
    header.setUint8(10, 0x56); // V
    header.setUint8(11, 0x45); // E

    // fmt chunk
    header.setUint8(12, 0x66); // f
    header.setUint8(13, 0x6D); // m
    header.setUint8(14, 0x74); // t
    header.setUint8(15, 0x20); // (space)
    header.setUint32(16, 16, Endian.little);         // Subchunk1Size (PCM = 16)
    header.setUint16(20, 1, Endian.little);           // AudioFormat (PCM = 1)
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, bitDepth, Endian.little);

    // data chunk
    header.setUint8(36, 0x64); // d
    header.setUint8(37, 0x61); // a
    header.setUint8(38, 0x74); // t
    header.setUint8(39, 0x61); // a
    header.setUint32(40, dataSize, Endian.little);

    final wav = Uint8List(44 + dataSize);
    wav.setRange(0, 44, header.buffer.asUint8List());
    wav.setRange(44, 44 + dataSize, pcmBytes);
    return wav;
  }
}

class _ExtractedAudio {
  final List<Uint8List> segments;
  final Duration silenceRemoved;
  final Duration speechDuration;

  _ExtractedAudio({
    required this.segments,
    required this.silenceRemoved,
    required this.speechDuration,
  });
}
