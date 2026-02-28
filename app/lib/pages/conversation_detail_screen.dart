import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:share_plus/share_plus.dart';

import 'package:reclo/services/audio_chunk_manager.dart';
import 'package:reclo/services/audio_stitcher.dart';

class ConversationDetailScreen extends StatefulWidget {
  final Conversation conversation;
  final double silenceThresholdDb;

  const ConversationDetailScreen({
    super.key,
    required this.conversation,
    required this.silenceThresholdDb,
  });

  @override
  State<ConversationDetailScreen> createState() =>
      _ConversationDetailScreenState();
}

class _ConversationDetailScreenState extends State<ConversationDetailScreen> {
  final AudioPlayer _player = AudioPlayer();
  final AudioStitcher _stitcher = AudioStitcher();

  bool _isStitching = false;
  bool _isPlaying = false;
  String? _stitchedPath;
  StitchResult? _stitchResult;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _setupPlayer();
    // Auto-stitch on open if not already done
    if (widget.conversation.stitchedFilePath != null) {
      _stitchedPath = widget.conversation.stitchedFilePath;
      _loadAudio(_stitchedPath!);
    } else {
      _stitch();
    }
  }

  void _setupPlayer() {
    _player.positionStream.listen((pos) {
      if (mounted) setState(() => _position = pos);
    });
    _player.durationStream.listen((dur) {
      if (mounted && dur != null) setState(() => _duration = dur);
    });
    _player.playerStateStream.listen((state) {
      if (mounted) {
        setState(() => _isPlaying = state.playing);
        if (state.processingState == ProcessingState.completed) {
          _player.seek(Duration.zero);
          setState(() => _isPlaying = false);
        }
      }
    });
  }

  Future<void> _stitch() async {
    setState(() => _isStitching = true);
    final result = await _stitcher.stitch(
      conversation: widget.conversation,
      silenceThresholdDb: widget.silenceThresholdDb,
    );
    if (mounted) {
      setState(() {
        _isStitching = false;
        _stitchResult = result;
        _stitchedPath = result.outputPath;
      });
      if (result.success && result.outputPath != null) {
        await _loadAudio(result.outputPath!);
      }
    }
  }

  Future<void> _loadAudio(String path) async {
    try {
      await _player.setFilePath(path);
    } catch (e) {
      debugPrint('Error loading audio: $e');
    }
  }

  Future<void> _togglePlayback() async {
    HapticFeedback.lightImpact();
    if (_isPlaying) {
      await _player.pause();
    } else {
      await _player.play();
    }
  }

  Future<void> _export() async {
    if (_stitchedPath == null) return;
    HapticFeedback.mediumImpact();
    final file = XFile(_stitchedPath!);
    await Share.shareXFiles(
      [file],
      subject: 'RecLo conversation ${_formatDate(widget.conversation.startTime)}',
    );
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(context),
            Expanded(
              child: _isStitching
                  ? _buildStitchingState()
                  : _buildContent(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 16, 8),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.arrow_back_ios_new_rounded,
                color: Colors.white54, size: 20),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _formatDate(widget.conversation.startTime),
                  style: const TextStyle(
                    fontSize: 16,
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'SF Pro Display',
                  ),
                ),
                Text(
                  _formatTimeRange(
                      widget.conversation.startTime,
                      widget.conversation.endTime),
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.white38,
                    fontFamily: 'SF Pro Display',
                  ),
                ),
              ],
            ),
          ),
          if (_stitchedPath != null)
            GestureDetector(
              onTap: _export,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1A1A),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white10),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.ios_share_rounded,
                        color: Colors.white70, size: 14),
                    SizedBox(width: 6),
                    Text(
                      'Export',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.white70,
                        fontFamily: 'SF Pro Display',
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStitchingState() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white24,
            ),
          ),
          SizedBox(height: 16),
          Text(
            'Stitching audio...',
            style: TextStyle(
              fontSize: 14,
              color: Colors.white38,
              fontFamily: 'SF Pro Display',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    return Column(
      children: [
        // Stats row
        _buildStatsRow(),
        const SizedBox(height: 8),
        // Chunk timeline
        Expanded(child: _buildChunkTimeline()),
        // Audio player
        if (_stitchedPath != null) _buildAudioPlayer(),
      ],
    );
  }

  Widget _buildStatsRow() {
    final chunkCount = widget.conversation.chunks.length;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          _StatChip(
            icon: Icons.view_week_rounded,
            label: '$chunkCount',
            sublabel: 'chunk${chunkCount == 1 ? '' : 's'}',
          ),
        ],
      ),
    );
  }

  Widget _buildChunkTimeline() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      itemCount: widget.conversation.chunks.length,
      itemBuilder: (context, index) {
        final chunk = widget.conversation.chunks[index];
        final analysis = chunk.silenceAnalysis;
        final speechPct = analysis == null
            ? 0.0
            : analysis.totalSpeech.inMilliseconds /
                (analysis.totalSpeech.inMilliseconds +
                    analysis.totalSilence.inMilliseconds +
                    1);

        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _ChunkRow(
            index: index + 1,
            startTime: chunk.startTime,
            hasSpeech: chunk.hasSpeech,
            speechPercent: speechPct,
          ),
        );
      },
    );
  }

  Widget _buildAudioPlayer() {
    final progress = _duration.inMilliseconds > 0
        ? _position.inMilliseconds / _duration.inMilliseconds
        : 0.0;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      decoration: const BoxDecoration(
        color: Color(0xFF0A0A0A),
        border: Border(top: BorderSide(color: Colors.white10)),
      ),
      child: Column(
        children: [
          // Progress bar
          SliderTheme(
            data: SliderThemeData(
              trackHeight: 3,
              thumbShape:
                  const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape:
                  const RoundSliderOverlayShape(overlayRadius: 14),
              activeTrackColor: Colors.white,
              inactiveTrackColor: Colors.white12,
              thumbColor: Colors.white,
              overlayColor: Colors.white12,
            ),
            child: Slider(
              value: progress.clamp(0.0, 1.0),
              onChanged: (val) {
                final seek = Duration(
                    milliseconds:
                        (val * _duration.inMilliseconds).round());
                _player.seek(seek);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _formatDuration(_position),
                  style: const TextStyle(
                      fontSize: 11,
                      color: Colors.white38,
                      fontFamily: 'SF Pro Display'),
                ),
                Text(
                  _formatDuration(_duration),
                  style: const TextStyle(
                      fontSize: 11,
                      color: Colors.white38,
                      fontFamily: 'SF Pro Display'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Play/Pause button
          GestureDetector(
            onTap: _togglePlayback,
            child: Container(
              width: 56,
              height: 56,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
              child: Icon(
                _isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                color: Colors.black,
                size: 28,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Helpers ───────────────────────────────────────────────────────────────

  String _formatDate(DateTime dt) {
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
  }

  String _formatTimeRange(DateTime start, DateTime end) {
    return '${_formatTime(start)} – ${_formatTime(end)}';
  }

  String _formatTime(DateTime dt) {
    final hour = dt.hour == 0
        ? 12
        : dt.hour > 12
            ? dt.hour - 12
            : dt.hour;
    final min = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return '$hour:$min $ampm';
  }

  String _formatDuration(Duration d) {
    if (d.inHours > 0) {
      return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
    }
    if (d.inMinutes > 0) {
      return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
    }
    return '${d.inSeconds}s';
  }
}

// ─── Stat Chip ────────────────────────────────────────────────────────────────

class _StatChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String sublabel;

  const _StatChip({
    required this.icon,
    required this.label,
    required this.sublabel,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF111111),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: Colors.white38, size: 16),
            const SizedBox(height: 6),
            Text(
              label,
              style: const TextStyle(
                fontSize: 15,
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontFamily: 'SF Pro Display',
              ),
            ),
            Text(
              sublabel,
              style: const TextStyle(
                fontSize: 11,
                color: Colors.white38,
                fontFamily: 'SF Pro Display',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Chunk Row ────────────────────────────────────────────────────────────────

class _ChunkRow extends StatelessWidget {
  final int index;
  final DateTime startTime;
  final bool hasSpeech;
  final double speechPercent;

  const _ChunkRow({
    required this.index,
    required this.startTime,
    required this.hasSpeech,
    required this.speechPercent,
  });

  @override
  Widget build(BuildContext context) {
    final timeStr = _formatTime(startTime);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF111111),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          // Chunk number
          SizedBox(
            width: 28,
            child: Text(
              '$index',
              style: const TextStyle(
                fontSize: 13,
                color: Colors.white38,
                fontFamily: 'SF Pro Display',
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Speech bar
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      timeStr,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white54,
                        fontFamily: 'SF Pro Display',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                // Speech percentage bar
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: speechPercent,
                    minHeight: 3,
                    backgroundColor: Colors.white10,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      hasSpeech
                          ? const Color(0xFF4ADE80)
                          : Colors.white12,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final hour = dt.hour == 0
        ? 12
        : dt.hour > 12
            ? dt.hour - 12
            : dt.hour;
    final min = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return '$hour:$min $ampm';
  }

  String _formatDuration(Duration d) {
    if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
    return '${d.inSeconds}s';
  }
}
