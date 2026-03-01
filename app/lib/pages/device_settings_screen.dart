import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:reclo/backend/schema/bt_device/bt_device.dart';
import 'package:reclo/services/devices/models.dart';
import 'package:reclo/providers/reclo_provider.dart';
import 'package:provider/provider.dart';

// Placeholder — replace with your GitHub releases URL
const String kFirmwareReleasesUrl =
    'https://github.com/YOUR_USERNAME/RecLo/releases';

class DeviceSettingsScreen extends StatefulWidget {
  const DeviceSettingsScreen({super.key});

  @override
  State<DeviceSettingsScreen> createState() => _DeviceSettingsScreenState();
}

class _DeviceSettingsScreenState extends State<DeviceSettingsScreen> {
  double _dimRatio = 100.0;
  double _micGain = 5.0;
  bool _dimLoaded = false;
  bool _micLoaded = false;
  bool _hasDimming = false;
  bool _hasMicGain = false;

  Timer? _dimDebounce;
  Timer? _micDebounce;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadDeviceFeatures());
  }

  @override
  void dispose() {
    _dimDebounce?.cancel();
    _micDebounce?.cancel();
    super.dispose();
  }

  Future<void> _loadDeviceFeatures() async {
    final provider = context.read<RecLoProvider>();
    final connection = provider.deviceConnection;
    if (connection == null) return;

    try {
      final features = await connection.getFeatures();
      final hasDim = (features & OmiFeatures.ledDimming) != 0;
      final hasMic = (features & OmiFeatures.micGain) != 0;

      if (!mounted) return;
      setState(() {
        _hasDimming = hasDim;
        _hasMicGain = hasMic;
      });

      if (hasDim) {
        final ratio = await connection.getLedDimRatio();
        if (mounted && ratio != null) {
          setState(() => _dimRatio = ratio.toDouble());
        }
      }
      if (mounted) setState(() => _dimLoaded = true);

      if (hasMic) {
        final gain = await connection.getMicGain();
        if (mounted && gain != null) {
          setState(() => _micGain = gain.toDouble());
        }
      }
      if (mounted) setState(() => _micLoaded = true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _dimLoaded = true;
          _micLoaded = true;
        });
      }
    }
  }

  Future<void> _setDimRatio(double value) async {
    final connection = context.read<RecLoProvider>().deviceConnection;
    await connection?.setLedDimRatio(value.toInt());
  }

  Future<void> _setMicGain(double value) async {
    final connection = context.read<RecLoProvider>().deviceConnection;
    await connection?.setMicGain(value.toInt());
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<RecLoProvider>();
    final device = provider.connectedDevice;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  const SizedBox(height: 8),
                  const _SectionLabel(label: 'Device Info'),
                  _buildDeviceInfoCard(device),
                  const SizedBox(height: 8),
                  const _SectionLabel(label: 'Hardware'),
                  _buildHardwareCard(device),
                  if (_hasDimming || _hasMicGain) ...[
                    const SizedBox(height: 8),
                    const _SectionLabel(label: 'Controls'),
                    _buildControlsCard(),
                  ],
                  const SizedBox(height: 8),
                  const _SectionLabel(label: 'Firmware'),
                  _buildFirmwareCard(device),
                  const SizedBox(height: 8),
                  const _SectionLabel(label: 'Connection'),
                  _buildConnectionCard(provider),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 16, 8),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.arrow_back_ios_new_rounded,
                color: Colors.white54, size: 20),
          ),
          const Text(
            'Device',
            style: TextStyle(
              fontSize: 18,
              color: Colors.white,
              fontWeight: FontWeight.w600,
              fontFamily: 'SF Pro Display',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceInfoCard(BtDevice? device) {
    return _Card(
      children: [
        _InfoRow(
          label: 'Name',
          value: device?.name ?? '—',
          copyable: true,
        ),
        _InfoRow(
          label: 'Device ID',
          value: device != null ? _shortId(device.id) : '—',
          copyValue: device?.id,
          copyable: true,
          isLast: true,
        ),
      ],
    );
  }

  Widget _buildHardwareCard(BtDevice? device) {
    return _Card(
      children: [
        _InfoRow(
          label: 'Model',
          value: device?.modelNumber ?? '—',
          copyable: true,
        ),
        _InfoRow(
          label: 'Hardware',
          value: device?.hardwareRevision ?? '—',
          copyable: true,
        ),
        _InfoRow(
          label: 'Manufacturer',
          value: device?.manufacturerName ?? '—',
          isLast: true,
        ),
      ],
    );
  }

  Widget _buildControlsCard() {
    return _Card(
      children: [
        if (_hasDimming)
          _SliderRow(
            label: 'LED Brightness',
            value: _dimLoaded ? _dimRatio : null,
            min: 0,
            max: 100,
            divisions: 100,
            displayValue: '${_dimRatio.round()}%',
            isLast: !_hasMicGain,
            onChanged: (v) {
              setState(() => _dimRatio = v);
              _dimDebounce?.cancel();
              _dimDebounce = Timer(
                const Duration(milliseconds: 300),
                () => _setDimRatio(v),
              );
            },
            onChangeEnd: (v) {
              _dimDebounce?.cancel();
              _setDimRatio(v);
            },
          ),
        if (_hasMicGain)
          _SliderRow(
            label: 'Mic Gain',
            value: _micLoaded ? _micGain : null,
            min: 0,
            max: 8,
            divisions: 8,
            displayValue: _micGainLabel(_micGain.round()),
            isLast: true,
            onChanged: (v) {
              setState(() => _micGain = v);
              _micDebounce?.cancel();
              _micDebounce = Timer(
                const Duration(milliseconds: 300),
                () => _setMicGain(v),
              );
            },
            onChangeEnd: (v) {
              _micDebounce?.cancel();
              _setMicGain(v);
            },
          ),
      ],
    );
  }

  Widget _buildFirmwareCard(BtDevice? device) {
    return _Card(
      children: [
        _ActionRow(
          label: 'Current version',
          value: device?.firmwareRevision ?? '—',
          isLast: false,
        ),
        _ActionRow(
          label: 'Check for updates',
          value: 'GitHub →',
          isLast: true,
          onTap: () => launchUrl(
            Uri.parse(kFirmwareReleasesUrl),
            mode: LaunchMode.externalApplication,
          ),
        ),
      ],
    );
  }

  Widget _buildConnectionCard(RecLoProvider provider) {
    return _Card(
      children: [
        _ActionRow(
          label: 'Disconnect',
          value: '',
          isLast: true,
          isDestructive: true,
          onTap: () {
            provider.disconnect();
            Navigator.of(context).pop();
          },
        ),
      ],
    );
  }

  String _shortId(String id) {
    if (id.length > 10) return '${id.substring(0, 4)}···${id.substring(id.length - 4)}';
    return id;
  }

  String _micGainLabel(int level) {
    const labels = ['Mute', '-20dB', '-10dB', '+0dB', '+6dB', '+10dB', '+20dB', '+30dB', '+40dB'];
    return level >= 0 && level < labels.length ? labels[level] : '';
  }
}

// ─── Shared Card Widgets ──────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  final List<Widget> children;
  const _Card({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF111111),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(children: children),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final String? copyValue;
  final bool copyable;
  final bool isLast;

  const _InfoRow({
    required this.label,
    required this.value,
    this.copyValue,
    this.copyable = false,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    Widget row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 14,
              color: Colors.white54,
              fontFamily: 'SF Pro Display',
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: const TextStyle(
              fontSize: 14,
              color: Colors.white,
              fontFamily: 'SF Pro Display',
              fontWeight: FontWeight.w500,
            ),
          ),
          if (copyable) ...[
            const SizedBox(width: 8),
            const Icon(Icons.copy_rounded, size: 14, color: Colors.white24),
          ],
        ],
      ),
    );

    if (copyable) {
      row = GestureDetector(
        onTap: () {
          Clipboard.setData(ClipboardData(text: copyValue ?? value));
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('$label copied'),
              backgroundColor: const Color(0xFF1A1A1A),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 1),
            ),
          );
        },
        child: row,
      );
    }

    return Column(
      children: [
        row,
        if (!isLast) const Divider(height: 1, color: Colors.white10),
      ],
    );
  }
}

class _ActionRow extends StatelessWidget {
  final String label;
  final String value;
  final bool isLast;
  final bool isDestructive;
  final VoidCallback? onTap;

  const _ActionRow({
    required this.label,
    required this.value,
    required this.isLast,
    this.isDestructive = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        GestureDetector(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    color: isDestructive ? Colors.redAccent : Colors.white,
                    fontFamily: 'SF Pro Display',
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const Spacer(),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Colors.white38,
                    fontFamily: 'SF Pro Display',
                  ),
                ),
                if (onTap != null && !isDestructive) ...[
                  const SizedBox(width: 4),
                  const Icon(Icons.chevron_right_rounded,
                      color: Colors.white24, size: 18),
                ],
              ],
            ),
          ),
        ),
        if (!isLast) const Divider(height: 1, color: Colors.white10),
      ],
    );
  }
}

class _SliderRow extends StatelessWidget {
  final String label;
  final double? value;
  final double min;
  final double max;
  final int divisions;
  final String displayValue;
  final bool isLast;
  final void Function(double) onChanged;
  final void Function(double) onChangeEnd;

  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.displayValue,
    required this.isLast,
    required this.onChanged,
    required this.onChangeEnd,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
          child: Row(
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 14,
                  color: Colors.white,
                  fontFamily: 'SF Pro Display',
                  fontWeight: FontWeight.w500,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  displayValue,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.white,
                    fontFamily: 'SF Pro Display',
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        value == null
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: SizedBox(
                  height: 2,
                  child: LinearProgressIndicator(
                    backgroundColor: Colors.white10,
                    color: Colors.white24,
                  ),
                ),
              )
            : SliderTheme(
                data: SliderThemeData(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                  activeTrackColor: Colors.white,
                  inactiveTrackColor: Colors.white12,
                  thumbColor: Colors.white,
                  overlayColor: Colors.white10,
                ),
                child: Slider(
                  value: value!.clamp(min, max),
                  min: min,
                  max: max,
                  divisions: divisions,
                  onChanged: (v) {
                    HapticFeedback.selectionClick();
                    onChanged(v);
                  },
                  onChangeEnd: onChangeEnd,
                ),
              ),
        if (!isLast) const Divider(height: 1, color: Colors.white10),
        const SizedBox(height: 4),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel({required this.label, super.key});

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
