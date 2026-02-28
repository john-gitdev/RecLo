import 'dart:math';
import 'dart:typed_data';

class AudioSegment {
  final Duration start;
  final Duration end;
  final bool isSilent;

  AudioSegment({required this.start, required this.end, required this.isSilent});

  Duration get duration => end - start;

  @override
  String toString() => 'AudioSegment(${start.inMilliseconds}ms-${end.inMilliseconds}ms, silent: $isSilent)';
}

class SilenceAnalysisResult {
  final List<AudioSegment> segments;
  final Duration totalSilence;
  final Duration totalSpeech;
  final bool isEntirelySilent;
  final Duration longestSilenceGap;

  SilenceAnalysisResult({
    required this.segments,
    required this.totalSilence,
    required this.totalSpeech,
    required this.isEntirelySilent,
    required this.longestSilenceGap,
  });

  @override
  String toString() =>
      'SilenceAnalysisResult(speech: ${totalSpeech.inSeconds}s, silence: ${totalSilence.inSeconds}s, entirelySilent: $isEntirelySilent)';
}

enum PcmFormat {
  pcm8bit,  // 8-bit unsigned PCM (Omi pcm8 codec)
  pcm16bit, // 16-bit signed PCM (Omi pcm16 codec, or decoded opus)
}

/// Detects silence in raw PCM audio data streamed from Omi device.
/// All Omi codecs output 16kHz sample rate.
class SilenceDetectionService {
  final int sampleRate;
  final int windowSizeMs;

  SilenceDetectionService({
    this.sampleRate = 16000,
    this.windowSizeMs = 100,
  });

  /// Analyze a PCM audio chunk for silence.
  ///
  /// [pcmBytes]            - Raw PCM audio bytes
  /// [format]              - PcmFormat.pcm8bit or PcmFormat.pcm16bit
  /// [silenceThresholdDb]  - dB below which audio is silent (e.g. -40.0). User-settable.
  /// [minSilenceDurationMs]- Minimum ms to count as a meaningful silence gap.
  SilenceAnalysisResult analyze({
    required Uint8List pcmBytes,
    required PcmFormat format,
    required double silenceThresholdDb,
  }) {
    if (pcmBytes.isEmpty) {
      return SilenceAnalysisResult(
        segments: [],
        totalSilence: Duration.zero,
        totalSpeech: Duration.zero,
        isEntirelySilent: true,
        longestSilenceGap: Duration.zero,
      );
    }

    final samples = format == PcmFormat.pcm8bit
        ? _bytes8ToSamples(pcmBytes)
        : _bytes16ToSamples(pcmBytes);

    final samplesPerWindow = (sampleRate * windowSizeMs / 1000).round();
    final List<bool> windowSilence = [];

    int wi = 0;
    while (wi * samplesPerWindow < samples.length) {
      final start = wi * samplesPerWindow;
      final end = min(start + samplesPerWindow, samples.length);
      final window = samples.sublist(start, end);
      windowSilence.add(_calculateRmsDb(window) < silenceThresholdDb);
      wi++;
    }

    if (windowSilence.isEmpty) {
      return SilenceAnalysisResult(
        segments: [],
        totalSilence: Duration.zero,
        totalSpeech: Duration.zero,
        isEntirelySilent: true,
        longestSilenceGap: Duration.zero,
      );
    }

    final List<AudioSegment> segments = [];
    Duration totalSilence = Duration.zero;
    Duration totalSpeech = Duration.zero;
    Duration longestSilenceGap = Duration.zero;

    bool currentState = windowSilence[0];
    int segmentStartWindow = 0;

    for (int i = 1; i <= windowSilence.length; i++) {
      final isLast = i == windowSilence.length;
      final stateChanged = !isLast && windowSilence[i] != currentState;

      if (stateChanged || isLast) {
        final segStart = Duration(milliseconds: segmentStartWindow * windowSizeMs);
        final segEnd = Duration(milliseconds: i * windowSizeMs);
        final segDuration = segEnd - segStart;

        segments.add(AudioSegment(start: segStart, end: segEnd, isSilent: currentState));
        if (currentState) {
          totalSilence += segDuration;
          if (segDuration > longestSilenceGap) longestSilenceGap = segDuration;
        } else {
          totalSpeech += segDuration;
        }

        if (!isLast) {
          currentState = windowSilence[i];
          segmentStartWindow = i;
        }
      }
    }

    return SilenceAnalysisResult(
      segments: segments,
      totalSilence: totalSilence,
      totalSpeech: totalSpeech,
      isEntirelySilent: totalSpeech == Duration.zero,
      longestSilenceGap: longestSilenceGap,
    );
  }

  /// Returns true if trailing silence across recent chunks exceeds [silenceThreshold].
  /// Call this after every new chunk to detect conversation boundaries.
  bool isConversationBoundary({
    required List<SilenceAnalysisResult> recentChunks,
    required Duration silenceThreshold,
  }) {
    Duration accumulated = Duration.zero;

    for (int i = recentChunks.length - 1; i >= 0; i--) {
      final chunk = recentChunks[i];
      if (chunk.isEntirelySilent) {
        accumulated += chunk.totalSilence;
      } else {
        if (chunk.segments.isNotEmpty && chunk.segments.last.isSilent) {
          accumulated += chunk.segments.last.duration;
        }
        break;
      }
      if (accumulated >= silenceThreshold) return true;
    }

    return accumulated >= silenceThreshold;
  }

  List<double> _bytes8ToSamples(Uint8List bytes) =>
      bytes.map((b) => (b - 128) / 128.0).toList();

  List<double> _bytes16ToSamples(Uint8List bytes) {
    final samples = <double>[];
    for (int i = 0; i + 1 < bytes.length; i += 2) {
      int raw = bytes[i] | (bytes[i + 1] << 8);
      if (raw > 32767) raw -= 65536;
      samples.add(raw / 32768.0);
    }
    return samples;
  }

  double _calculateRmsDb(List<double> samples) {
    if (samples.isEmpty) return -100.0;
    double sumSquares = 0;
    for (final s in samples) sumSquares += s * s;
    final rms = sqrt(sumSquares / samples.length);
    if (rms == 0) return -100.0;
    return 20 * log(rms) / ln10;
  }
}
