import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as ble;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reclo/services/devices/models.dart';

class DeviceScanScreen extends StatefulWidget {
  final void Function(ble.BluetoothDevice device) onDeviceSelected;

  const DeviceScanScreen({super.key, required this.onDeviceSelected});

  @override
  State<DeviceScanScreen> createState() => _DeviceScanScreenState();
}

class _DeviceScanScreenState extends State<DeviceScanScreen> {
  static const String _lastDeviceKey = 'last_connected_device_id';

  final Map<String, ble.ScanResult> _discovered = {};
  String? _lastDeviceId;
  String? _connectingId;
  bool _isScanning = false;
  StreamSubscription? _scanSub;

  @override
  void initState() {
    super.initState();
    _loadLastDevice();
    _startScan();
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    ble.FlutterBluePlus.stopScan();
    super.dispose();
  }

  Future<void> _loadLastDevice() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() => _lastDeviceId = prefs.getString(_lastDeviceKey));
    }
  }

  Future<void> _saveLastDevice(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastDeviceKey, id);
  }

  Future<void> _startScan() async {
    if (_isScanning) return;

    // Check BLE is on
    final adapterState = await ble.FlutterBluePlus.adapterState.first;
    if (adapterState != ble.BluetoothAdapterState.on) {
      _showBluetoothDialog();
      return;
    }

    setState(() {
      _isScanning = true;
      _discovered.clear();
    });

    await _scanSub?.cancel();

    await ble.FlutterBluePlus.startScan(
      withServices: [ble.Guid(omiServiceUuid)],
      timeout: const Duration(seconds: 15),
    );

    _scanSub = ble.FlutterBluePlus.scanResults.listen((results) {
      if (!mounted) return;
      setState(() {
        for (final r in results) {
          _discovered[r.device.remoteId.str] = r;
        }
      });
    });

    ble.FlutterBluePlus.isScanning.listen((scanning) {
      if (mounted && !scanning) {
        setState(() => _isScanning = false);
      }
    });
  }

  Future<void> _connectTo(ble.BluetoothDevice device) async {
    if (_connectingId != null) return;
    HapticFeedback.mediumImpact();

    setState(() => _connectingId = device.remoteId.str);

    await _saveLastDevice(device.remoteId.str);
    widget.onDeviceSelected(device);
  }

  void _showBluetoothDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Bluetooth Required',
          style: TextStyle(color: Colors.white, fontFamily: 'SF Pro Display'),
        ),
        content: const Text(
          'Please enable Bluetooth to scan for your RecLo device.',
          style: TextStyle(color: Colors.white54, fontFamily: 'SF Pro Display'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK',
                style: TextStyle(color: Colors.white70, fontFamily: 'SF Pro Display')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final devices = _discovered.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi)); // Sort by signal strength

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: devices.isEmpty
                  ? _buildEmptyState()
                  : _buildDeviceList(devices),
            ),
            _buildRescanButton(),
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
          const Expanded(
            child: Text(
              'Connect Device',
              style: TextStyle(
                fontSize: 18,
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontFamily: 'SF Pro Display',
              ),
            ),
          ),
          if (_isScanning)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white38,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.bluetooth_searching_rounded,
              size: 48, color: Colors.white12),
          const SizedBox(height: 16),
          Text(
            _isScanning ? 'Searching for devices...' : 'No devices found',
            style: const TextStyle(
              fontSize: 16,
              color: Colors.white38,
              fontFamily: 'SF Pro Display',
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Make sure your RecLo is charged and nearby',
            style: TextStyle(
              fontSize: 13,
              color: Colors.white24,
              fontFamily: 'SF Pro Display',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceList(List<ble.ScanResult> devices) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      children: [
        // Last connected device at top if found
        if (_lastDeviceId != null) ...[
          const _SectionLabel(label: 'Last Connected'),
          ...devices
              .where((d) => d.device.remoteId.str == _lastDeviceId)
              .map((d) => _DeviceCard(
                    result: d,
                    isConnecting: _connectingId == d.device.remoteId.str,
                    isLastConnected: true,
                    onTap: () => _connectTo(d.device),
                  )),
          if (devices.any((d) => d.device.remoteId.str != _lastDeviceId)) ...[
            const SizedBox(height: 8),
            const _SectionLabel(label: 'Other Devices'),
          ],
        ] else
          const _SectionLabel(label: 'Nearby Devices'),
        ...devices
            .where((d) =>
                _lastDeviceId == null ||
                d.device.remoteId.str != _lastDeviceId)
            .map((d) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _DeviceCard(
                    result: d,
                    isConnecting: _connectingId == d.device.remoteId.str,
                    isLastConnected: false,
                    onTap: () => _connectTo(d.device),
                  ),
                )),
      ],
    );
  }

  Widget _buildRescanButton() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Colors.white10)),
      ),
      child: GestureDetector(
        onTap: _isScanning ? null : _startScan,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: _isScanning ? Colors.white12 : const Color(0xFF1A1A1A),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white10),
          ),
          child: Center(
            child: Text(
              _isScanning ? 'Scanning...' : 'Scan Again',
              style: TextStyle(
                fontSize: 15,
                color: _isScanning ? Colors.white24 : Colors.white70,
                fontWeight: FontWeight.w500,
                fontFamily: 'SF Pro Display',
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Device Card ──────────────────────────────────────────────────────────────

class _DeviceCard extends StatelessWidget {
  final ble.ScanResult result;
  final bool isConnecting;
  final bool isLastConnected;
  final VoidCallback onTap;

  const _DeviceCard({
    required this.result,
    required this.isConnecting,
    required this.isLastConnected,
    required this.onTap,
  });

  String get _name {
    final n = result.device.platformName;
    return n.isNotEmpty ? n : 'RecLo Device';
  }

  String get _shortId {
    final id = result.device.remoteId.str;
    if (id.length > 8) return '${id.substring(0, 4)}···${id.substring(id.length - 4)}';
    return id;
  }

  int get _signalBars {
    final rssi = result.rssi;
    if (rssi >= -60) return 4;
    if (rssi >= -70) return 3;
    if (rssi >= -80) return 2;
    return 1;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: isConnecting ? null : onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF111111),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isLastConnected ? Colors.white24 : Colors.white10,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.headset_rounded,
                color: Colors.white54,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _name,
                    style: const TextStyle(
                      fontSize: 15,
                      color: Colors.white,
                      fontWeight: FontWeight.w500,
                      fontFamily: 'SF Pro Display',
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _shortId,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.white38,
                      fontFamily: 'SF Pro Display',
                    ),
                  ),
                ],
              ),
            ),
            if (isConnecting)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white54,
                ),
              )
            else ...[
              _SignalBars(bars: _signalBars),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right_rounded,
                  color: Colors.white24, size: 20),
            ],
          ],
        ),
      ),
    );
  }
}

// ─── Signal Bars ──────────────────────────────────────────────────────────────

class _SignalBars extends StatelessWidget {
  final int bars;
  const _SignalBars({required this.bars});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: List.generate(4, (i) {
        final active = i < bars;
        return Container(
          width: 4,
          height: 6.0 + (i * 3),
          margin: const EdgeInsets.only(left: 2),
          decoration: BoxDecoration(
            color: active ? Colors.white54 : Colors.white12,
            borderRadius: BorderRadius.circular(1),
          ),
        );
      }),
    );
  }
}

// ─── Section Label ────────────────────────────────────────────────────────────

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
