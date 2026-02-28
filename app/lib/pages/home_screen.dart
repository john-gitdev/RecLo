import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:reclo/services/audio_chunk_manager.dart';

class HomeScreen extends StatelessWidget {
  final bool isConnected;
  final bool isRecording;
  final bool isScanning;
  final List<Conversation> conversations;
  final List<AudioChunk> pendingChunks;
  final VoidCallback onFinalizePressed;
  final VoidCallback onScanPressed;
  final VoidCallback onSettingsPressed;
  final void Function(Conversation) onConversationTapped;

  const HomeScreen({
    super.key,
    required this.isConnected,
    required this.isRecording,
    required this.isScanning,
    required this.conversations,
    required this.pendingChunks,
    required this.onFinalizePressed,
    required this.onScanPressed,
    required this.onSettingsPressed,
    required this.onConversationTapped,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: SafeArea(
        child: Column(
          children: [
            _Header(
              isConnected: isConnected,
              isRecording: isRecording,
              isScanning: isScanning,
              onScanPressed: onScanPressed,
              onSettingsPressed: onSettingsPressed,
            ),
            Expanded(
              child: conversations.isEmpty && pendingChunks.isEmpty
                  ? _EmptyState(
                      isConnected: isConnected,
                      isScanning: isScanning,
                      onScanPressed: onScanPressed,
                    )
                  : _ConversationList(
                      conversations: conversations,
                      pendingChunks: pendingChunks,
                      onConversationTapped: onConversationTapped,
                    ),
            ),
            if (pendingChunks.isNotEmpty)
              _FinalizeBar(
                chunkCount: pendingChunks.length,
                onPressed: onFinalizePressed,
              ),
          ],
        ),
      ),
    );
  }
}

// ─── Header ──────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final bool isConnected;
  final bool isRecording;
  final bool isScanning;
  final VoidCallback onScanPressed;
  final VoidCallback onSettingsPressed;

  const _Header({
    required this.isConnected,
    required this.isRecording,
    required this.isScanning,
    required this.onScanPressed,
    required this.onSettingsPressed,
  });

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final dateStr = _formatDate(now);

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 16, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'RecLo',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    letterSpacing: -0.5,
                    fontFamily: 'SF Pro Display',
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  dateStr,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Colors.white38,
                    fontFamily: 'SF Pro Display',
                  ),
                ),
              ],
            ),
          ),
          // Device button
          GestureDetector(
            onTap: () {
              HapticFeedback.lightImpact();
              onScanPressed();
            },
            child: _StatusChip(
              isConnected: isConnected,
              isRecording: isRecording,
              isScanning: isScanning,
            ),
          ),
          const SizedBox(width: 8),
          // Settings button
          GestureDetector(
            onTap: () {
              HapticFeedback.lightImpact();
              onSettingsPressed();
            },
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A1A),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white10),
              ),
              child: const Icon(
                Icons.tune_rounded,
                color: Colors.white54,
                size: 18,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime dt) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return '${days[dt.weekday - 1]}, ${months[dt.month - 1]} ${dt.day}';
  }
}

class _StatusChip extends StatefulWidget {
  final bool isConnected;
  final bool isRecording;
  final bool isScanning;

  const _StatusChip({
    required this.isConnected,
    required this.isRecording,
    required this.isScanning,
  });

  @override
  State<_StatusChip> createState() => _StatusChipState();
}

class _StatusChipState extends State<_StatusChip>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _animation = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String label;
    Color dotColor;
    bool animate;

    if (widget.isScanning) {
      label = 'Scanning...';
      dotColor = Colors.blueAccent;
      animate = true;
    } else if (widget.isRecording) {
      label = 'Recording';
      dotColor = const Color(0xFF4ADE80);
      animate = true;
    } else if (widget.isConnected) {
      label = 'Connected';
      dotColor = Colors.white38;
      animate = false;
    } else {
      label = 'Tap to connect';
      dotColor = Colors.white24;
      animate = false;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          animate
              ? AnimatedBuilder(
                  animation: _animation,
                  builder: (_, __) => Opacity(
                    opacity: _animation.value,
                    child: _dot(dotColor),
                  ),
                )
              : _dot(dotColor),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: Colors.white70,
              fontFamily: 'SF Pro Display',
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _dot(Color c) => Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(color: c, shape: BoxShape.circle),
      );
}

// ─── Empty State ─────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final bool isConnected;
  final bool isScanning;
  final VoidCallback onScanPressed;

  const _EmptyState({
    required this.isConnected,
    required this.isScanning,
    required this.onScanPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isConnected
                ? Icons.mic_none_rounded
                : Icons.bluetooth_disabled_rounded,
            size: 48,
            color: Colors.white12,
          ),
          const SizedBox(height: 16),
          Text(
            isConnected
                ? 'Listening...'
                : isScanning
                    ? 'Looking for Omi...'
                    : 'No device connected',
            style: const TextStyle(
              fontSize: 16,
              color: Colors.white38,
              fontFamily: 'SF Pro Display',
            ),
          ),
          const SizedBox(height: 6),
          Text(
            isConnected
                ? 'Conversations will appear here'
                : isScanning
                    ? 'Make sure your Omi is nearby'
                    : 'Tap the status chip to scan',
            style: const TextStyle(
              fontSize: 13,
              color: Colors.white24,
              fontFamily: 'SF Pro Display',
            ),
          ),
          if (!isConnected && !isScanning) ...[
            const SizedBox(height: 24),
            GestureDetector(
              onTap: () {
                HapticFeedback.mediumImpact();
                onScanPressed();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 24, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1A1A),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white10),
                ),
                child: const Text(
                  'Scan for device',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.white70,
                    fontFamily: 'SF Pro Display',
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Conversation List ────────────────────────────────────────────────────────

class _ConversationList extends StatelessWidget {
  final List<Conversation> conversations;
  final List<AudioChunk> pendingChunks;
  final void Function(Conversation) onConversationTapped;

  const _ConversationList({
    required this.conversations,
    required this.pendingChunks,
    required this.onConversationTapped,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        if (pendingChunks.isNotEmpty) ...[
          _SectionLabel(label: 'In Progress'),
          _PendingChunksCard(chunks: pendingChunks),
          const SizedBox(height: 8),
        ],
        if (conversations.isNotEmpty) ...[
          _SectionLabel(label: 'Today'),
          ...conversations.reversed.map(
            (c) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _ConversationCard(
                conversation: c,
                onTap: () => onConversationTapped(c),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 0, 10),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          color: Colors.white38,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w600,
          fontFamily: 'SF Pro Display',
        ),
      ),
    );
  }
}

class _PendingChunksCard extends StatelessWidget {
  final List<AudioChunk> chunks;
  const _PendingChunksCard({required this.chunks});

  @override
  Widget build(BuildContext context) {
    final speechChunks = chunks.where((c) => c.hasSpeech).length;
    final totalChunks = chunks.length;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF111111),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: const Color(0xFF4ADE80).withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.graphic_eq_rounded,
              color: Color(0xFF4ADE80),
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Recording in progress',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.white,
                    fontWeight: FontWeight.w500,
                    fontFamily: 'SF Pro Display',
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$speechChunks of $totalChunks chunks have speech',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.white38,
                    fontFamily: 'SF Pro Display',
                  ),
                ),
              ],
            ),
          ),
          _PulsingDot(),
        ],
      ),
    );
  }
}

class _PulsingDot extends StatefulWidget {
  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, __) => Opacity(
        opacity: 0.4 + (_controller.value * 0.6),
        child: Container(
          width: 8,
          height: 8,
          decoration: const BoxDecoration(
            color: Color(0xFF4ADE80),
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}

class _ConversationCard extends StatelessWidget {
  final Conversation conversation;
  final VoidCallback onTap;

  const _ConversationCard({
    required this.conversation,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final timeStr = _formatTime(conversation.startTime);
    final durationStr = _formatDuration(conversation.totalSpeech);
    final chunkCount = conversation.chunks.length;

    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF111111),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white10),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.chat_bubble_outline_rounded,
                color: Colors.white54,
                size: 18,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Conversation · $timeStr',
                    style: const TextStyle(
                      fontSize: 14,
                      color: Colors.white,
                      fontWeight: FontWeight.w500,
                      fontFamily: 'SF Pro Display',
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '$durationStr · $chunkCount chunk${chunkCount == 1 ? '' : 's'}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.white38,
                      fontFamily: 'SF Pro Display',
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.chevron_right_rounded,
              color: Colors.white24,
              size: 20,
            ),
          ],
        ),
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
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
    if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
    return '${d.inSeconds}s';
  }
}

// ─── Finalize Bar ─────────────────────────────────────────────────────────────

class _FinalizeBar extends StatelessWidget {
  final int chunkCount;
  final VoidCallback onPressed;

  const _FinalizeBar({
    required this.chunkCount,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      decoration: const BoxDecoration(
        color: Color(0xFF0A0A0A),
        border: Border(top: BorderSide(color: Colors.white10)),
      ),
      child: GestureDetector(
        onTap: () {
          HapticFeedback.mediumImpact();
          onPressed();
        },
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Center(
            child: Text(
              'Finalize  ·  $chunkCount chunk${chunkCount == 1 ? '' : 's'}',
              style: const TextStyle(
                fontSize: 15,
                color: Colors.black,
                fontWeight: FontWeight.w600,
                fontFamily: 'SF Pro Display',
              ),
            ),
          ),
        ),
      ),
    );
  }
}
