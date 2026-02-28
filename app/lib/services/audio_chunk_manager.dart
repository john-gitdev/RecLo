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

  DateTime get endTime => startTime.add(const Duration(seconds: 30));

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
