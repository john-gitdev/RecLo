import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class RecLoSettings {
  static const String _keyDbThreshold = 'silence_db_threshold';
  static const String _keySilenceGapMinutes = 'silence_gap_minutes';

  static const double defaultDbThreshold = -40.0;
  static const double defaultSilenceGapMinutes = 2.0;

  static Future<double> getDbThreshold() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_keyDbThreshold) ?? defaultDbThreshold;
  }

  static Future<double> getSilenceGapMinutes() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_keySilenceGapMinutes) ?? defaultSilenceGapMinutes;
  }

  static Future<void> setDbThreshold(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyDbThreshold, value);
  }

  static Future<void> setSilenceGapMinutes(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keySilenceGapMinutes, value);
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  double _dbThreshold = RecLoSettings.defaultDbThreshold;
  double _silenceGapMinutes = RecLoSettings.defaultSilenceGapMinutes;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await RecLoSettings.getDbThreshold();
    final gap = await RecLoSettings.getSilenceGapMinutes();
    if (mounted) {
      setState(() {
        _dbThreshold = db;
        _silenceGapMinutes = gap;
        _loading = false;
      });
    }
  }

  Future<void> _saveDb(double value) async {
    setState(() => _dbThreshold = value);
    await RecLoSettings.setDbThreshold(value);
  }

  Future<void> _saveGap(double value) async {
    setState(() => _silenceGapMinutes = value);
    await RecLoSettings.setSilenceGapMinutes(value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(context),
            if (_loading)
              const Expanded(
                child: Center(
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white24,
                  ),
                ),
              )
            else
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    const SizedBox(height: 8),
                    _SectionLabel(label: 'Silence Detection'),
                    _DbThresholdCard(
                      value: _dbThreshold,
                      onChanged: _saveDb,
                    ),
                    const SizedBox(height: 8),
                    _SilenceGapCard(
                      value: _silenceGapMinutes,
                      onChanged: _saveGap,
                    ),
                    const SizedBox(height: 24),
                    _SectionLabel(label: 'About'),
                    _AboutCard(),
                  ],
                ),
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
          const Text(
            'Settings',
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
}

// ─── dB Threshold Card ────────────────────────────────────────────────────────

class _DbThresholdCard extends StatelessWidget {
  final double value;
  final void Function(double) onChanged;

  const _DbThresholdCard({required this.value, required this.onChanged});

  String get _label => '${value.round()} dB';

  String get _description {
    if (value >= -20) return 'Very sensitive — picks up whispers';
    if (value >= -35) return 'Sensitive — good for quiet rooms';
    if (value >= -45) return 'Balanced — recommended default';
    if (value >= -55) return 'Less sensitive — filters background noise';
    return 'Least sensitive — only loud speech';
  }

  @override
  Widget build(BuildContext context) {
    return _SettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Silence threshold',
                      style: TextStyle(
                        fontSize: 15,
                        color: Colors.white,
                        fontWeight: FontWeight.w500,
                        fontFamily: 'SF Pro Display',
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Audio below this level is considered silence',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white38,
                        fontFamily: 'SF Pro Display',
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _label,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'SF Pro Display',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SliderTheme(
            data: SliderThemeData(
              trackHeight: 3,
              thumbShape:
                  const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape:
                  const RoundSliderOverlayShape(overlayRadius: 16),
              activeTrackColor: Colors.white,
              inactiveTrackColor: Colors.white12,
              thumbColor: Colors.white,
              overlayColor: Colors.white10,
            ),
            child: Slider(
              value: value,
              min: -60,
              max: -10,
              divisions: 50,
              onChanged: (v) {
                HapticFeedback.selectionClick();
                onChanged(v);
              },
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '-60 dB',
                style: TextStyle(
                    fontSize: 11,
                    color: Colors.white24,
                    fontFamily: 'SF Pro Display'),
              ),
              Text(
                _description,
                style: const TextStyle(
                    fontSize: 11,
                    color: Colors.white38,
                    fontFamily: 'SF Pro Display'),
              ),
              const Text(
                '-10 dB',
                style: TextStyle(
                    fontSize: 11,
                    color: Colors.white24,
                    fontFamily: 'SF Pro Display'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Silence Gap Card ─────────────────────────────────────────────────────────

class _SilenceGapCard extends StatelessWidget {
  final double value;
  final void Function(double) onChanged;

  const _SilenceGapCard({required this.value, required this.onChanged});

  String get _label {
    if (value < 1) return '${(value * 60).round()}s';
    if (value == value.roundToDouble()) return '${value.round()}m';
    final minutes = value.floor();
    final seconds = ((value - minutes) * 60).round();
    return '${minutes}m ${seconds}s';
  }

  String get _description {
    if (value <= 0.5) return 'Short pauses split conversations';
    if (value <= 1.5) return 'Good for fast-paced conversations';
    if (value <= 3) return 'Recommended — natural conversation gaps';
    if (value <= 5) return 'Lenient — merges across longer pauses';
    return 'Very lenient — most of the day in one entry';
  }

  @override
  Widget build(BuildContext context) {
    return _SettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Conversation gap',
                      style: TextStyle(
                        fontSize: 15,
                        color: Colors.white,
                        fontWeight: FontWeight.w500,
                        fontFamily: 'SF Pro Display',
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Silence longer than this splits conversations',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white38,
                        fontFamily: 'SF Pro Display',
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _label,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'SF Pro Display',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SliderTheme(
            data: SliderThemeData(
              trackHeight: 3,
              thumbShape:
                  const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape:
                  const RoundSliderOverlayShape(overlayRadius: 16),
              activeTrackColor: Colors.white,
              inactiveTrackColor: Colors.white12,
              thumbColor: Colors.white,
              overlayColor: Colors.white10,
            ),
            child: Slider(
              value: value,
              min: 0.5,
              max: 10,
              divisions: 19,
              onChanged: (v) {
                HapticFeedback.selectionClick();
                onChanged(v);
              },
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '30s',
                style: TextStyle(
                    fontSize: 11,
                    color: Colors.white24,
                    fontFamily: 'SF Pro Display'),
              ),
              Text(
                _description,
                style: const TextStyle(
                    fontSize: 11,
                    color: Colors.white38,
                    fontFamily: 'SF Pro Display'),
              ),
              const Text(
                '10m',
                style: TextStyle(
                    fontSize: 11,
                    color: Colors.white24,
                    fontFamily: 'SF Pro Display'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── About Card ───────────────────────────────────────────────────────────────

class _AboutCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return _SettingsCard(
      child: Column(
        children: [
          _AboutRow(label: 'App', value: 'RecLo'),
          _Divider(),
          _AboutRow(label: 'Version', value: '1.0.0'),
          _Divider(),
          _AboutRow(label: 'Based on', value: 'Omi (Apache 2.0)'),
        ],
      ),
    );
  }
}

class _AboutRow extends StatelessWidget {
  final String label;
  final String value;

  const _AboutRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 14,
              color: Colors.white54,
              fontFamily: 'SF Pro Display',
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              fontSize: 14,
              color: Colors.white,
              fontFamily: 'SF Pro Display',
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const Divider(color: Colors.white10, height: 1);
  }
}

// ─── Shared Widgets ───────────────────────────────────────────────────────────

class _SettingsCard extends StatelessWidget {
  final Widget child;
  const _SettingsCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF111111),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white10),
      ),
      child: child,
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
