import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as ble;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reclo/backend/schema/bt_device/bt_device.dart';
import 'package:reclo/pages/settings_screen.dart';
import 'package:reclo/services/audio_chunk_manager.dart';
import 'package:reclo/services/devices/device_connection.dart';
import 'package:reclo/services/devices/models.dart';
import 'package:reclo/services/devices/omi_connection.dart';

enum RecLoConnectionState {
  disconnected,
  connecting,
  connected,
}

class RecLoProvider extends ChangeNotifier {
  static const String _lastDeviceKey = 'last_connected_device_id';

  // ─── State ─────────────────────────────────────────────────────────────────

  RecLoConnectionState _connectionState = RecLoConnectionState.disconnected;
  bool _isScanning = false;
  BtDevice? _connectedDevice;
  int _batteryLevel = -1;
  String? _lastDeviceId;

  final List<Conversation> _conversations = [];
  final List<AudioChunk> _pendingChunks = [];

  double _silenceThresholdDb = RecLoSettings.defaultDbThreshold;
  double _silenceGapMinutes = RecLoSettings.defaultSilenceGapMinutes;

  late AudioChunkManager _chunkManager;

  StreamSubscription? _audioSubscription;
  StreamSubscription? _batterySubscription;
  StreamSubscription? _scanSubscription;
  Timer? _watchdogTimer;
  OmiDeviceConnection? _deviceConnection;

  // ─── Getters ───────────────────────────────────────────────────────────────

  RecLoConnectionState get connectionState => _connectionState;
  bool get isConnected => _connectionState == RecLoConnectionState.connected;
  bool get isConnecting => _connectionState == RecLoConnectionState.connecting;
  bool get isScanning => _isScanning;
  BtDevice? get connectedDevice => _connectedDevice;
  String? get connectedDeviceName => _connectedDevice?.name;
  int get batteryLevel => _batteryLevel;
  List<Conversation> get conversations => List.unmodifiable(_conversations);
  List<AudioChunk> get pendingChunks => List.unmodifiable(_pendingChunks);
  double get silenceThresholdDb => _silenceThresholdDb;
  double get silenceGapMinutes => _silenceGapMinutes;
  bool get isRecording => isConnected && _pendingChunks.isNotEmpty;
  String? get lastDeviceId => _lastDeviceId;

  /// Exposed for DeviceSettingsScreen to call device-specific methods
  OmiDeviceConnection? get deviceConnection => _deviceConnection;

  // ─── Init ──────────────────────────────────────────────────────────────────

  Future<void> init() async {
    _silenceThresholdDb = await RecLoSettings.getDbThreshold();
    _silenceGapMinutes = await RecLoSettings.getSilenceGapMinutes();

    final prefs = await SharedPreferences.getInstance();
    _lastDeviceId = prefs.getString(_lastDeviceKey);

    _initChunkManager();
    _startWatchdog();
    notifyListeners();
  }

  void _initChunkManager() {
    _chunkManager = AudioChunkManager(
      silenceThresholdDb: _silenceThresholdDb,
      conversationGapThreshold: Duration(
        seconds: (_silenceGapMinutes * 60).round(),
      ),
      onChunkCompleted: (chunk) {
        _pendingChunks.add(chunk);
        notifyListeners();
      },
      onConversationDetected: (conversation) {
        _conversations.add(conversation);
        _pendingChunks.removeWhere((c) => conversation.chunks.contains(c));
        notifyListeners();
      },
    );
  }

  // ─── BLE Scanning ──────────────────────────────────────────────────────────

  Future<void> startScan() async {
    if (_isScanning) return;

    _isScanning = true;
    notifyListeners();

    await _scanSubscription?.cancel();

    try {
      await ble.FlutterBluePlus.startScan(
        withServices: [ble.Guid(omiServiceUuid)],
        timeout: const Duration(seconds: 15),
      );

      _scanSubscription = ble.FlutterBluePlus.isScanning.listen((scanning) {
        _isScanning = scanning;
        notifyListeners();
      });
    } catch (e) {
      debugPrint('RecLoProvider: Start scan failed: $e');
      _isScanning = false;
      notifyListeners();
    }
  }

  void stopScan() {
    ble.FlutterBluePlus.stopScan();
    _isScanning = false;
    notifyListeners();
  }

  // ─── BLE Connection ────────────────────────────────────────────────────────

  /// Called by DeviceScanScreen when user picks a device
  Future<bool> connectToDevice(ble.BluetoothDevice device) async {
    if (_connectionState == RecLoConnectionState.connecting) return false;

    _setConnectionState(RecLoConnectionState.connecting);

    try {
      final transport = BleTransport(device);
      _deviceConnection = OmiDeviceConnection(
        BtDevice(
          id: device.remoteId.str,
          name: device.platformName.isNotEmpty
              ? device.platformName
              : 'Omi Device',
          type: DeviceType.omi,
          rssi: 0,
        ),
        transport,
      );

      await _deviceConnection!.connect(
        onConnectionStateChanged: (deviceId, state) {
          if (state == DeviceConnectionState.disconnected) {
            _onDeviceDisconnected();
          }
        },
      );

      // Fetch full device info (firmware, hardware, etc.)
      final info = await _deviceConnection!.getDeviceInfo();
      _connectedDevice = BtDevice(
        id: device.remoteId.str,
        name: device.platformName.isNotEmpty
            ? device.platformName
            : 'Omi Device',
        type: DeviceType.omi,
        rssi: 0,
        firmwareRevision: info['firmwareRevision'],
        hardwareRevision: info['hardwareRevision'],
        modelNumber: info['modelNumber'],
        manufacturerName: info['manufacturerName'],
      );

      // Remember this device for watchdog reconnect
      _lastDeviceId = device.remoteId.str;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastDeviceKey, _lastDeviceId!);

      await _startAudioStream();
      await _startBatteryMonitor();

      // Request High Priority for Uncompressed Audio
      try {
        await device.requestConnectionPriority(connectionPriorityRequest: ble.ConnectionPriority.high);
      } catch (e) {
        debugPrint('RecLoProvider: Priority request failed: $e');
      }

      _setConnectionState(RecLoConnectionState.connected);
      return true;
    } catch (e) {
      debugPrint('RecLoProvider: Connection failed: $e');
      _deviceConnection = null;
      _connectedDevice = null;
      _setConnectionState(RecLoConnectionState.disconnected);
      return false;
    }
  }

  Future<void> _startAudioStream() async {
    if (_deviceConnection == null) return;

    final codec = await _deviceConnection!.getAudioCodec();
    debugPrint('RecLoProvider: Active codec is $codec');

    await _chunkManager.start(codec);
    _audioSubscription = (await _deviceConnection!.getBleAudioBytesListener(
      onAudioBytesReceived: (bytes) => _chunkManager.addAudioBytes(bytes),
    )) as StreamSubscription?;
  }

  Future<void> _startBatteryMonitor() async {
    if (_deviceConnection == null) return;
    _batteryLevel = await _deviceConnection!.retrieveBatteryLevel();
    notifyListeners();
    _batterySubscription =
        (await _deviceConnection!.getBleBatteryLevelListener(
      onBatteryLevelChange: (level) {
        _batteryLevel = level;
        notifyListeners();
      },
    )) as StreamSubscription?;
  }

  void _onDeviceDisconnected() {
    debugPrint('RecLoProvider: Device disconnected');
    _chunkManager.stop();
    _audioSubscription?.cancel();
    _batterySubscription?.cancel();
    _connectedDevice = null;
    _batteryLevel = -1;
    _setConnectionState(RecLoConnectionState.disconnected);
  }

  // ─── Watchdog ──────────────────────────────────────────────────────────────

  /// Watchdog tries to reconnect to the last known device every 30s
  void _startWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (_connectionState != RecLoConnectionState.disconnected) return;
      if (_lastDeviceId == null) return;

      debugPrint('RecLoProvider: Watchdog — trying to reconnect to $_lastDeviceId');

      // Try to find and reconnect to the last device
      try {
        await ble.FlutterBluePlus.startScan(
          withServices: [ble.Guid(omiServiceUuid)],
          timeout: const Duration(seconds: 8),
        );

        final sub = ble.FlutterBluePlus.scanResults.listen((results) {
          for (final r in results) {
            if (r.device.remoteId.str == _lastDeviceId) {
              ble.FlutterBluePlus.stopScan();
              connectToDevice(r.device);
              break;
            }
          }
        });

        await Future.delayed(const Duration(seconds: 8));
        await sub.cancel();
        ble.FlutterBluePlus.stopScan();
      } catch (e) {
        debugPrint('RecLoProvider: Watchdog scan failed: $e');
      }
    });
  }

  // ─── User Actions ──────────────────────────────────────────────────────────

  void finalizeNow() => _chunkManager.finalizeNow();

  Future<void> updateSilenceThreshold(double db) async {
    _silenceThresholdDb = db;
    _chunkManager.silenceThresholdDb = db;
    await RecLoSettings.setDbThreshold(db);
    notifyListeners();
  }

  Future<void> updateSilenceGap(double minutes) async {
    _silenceGapMinutes = minutes;
    _chunkManager.conversationGapThreshold =
        Duration(seconds: (minutes * 60).round());
    await RecLoSettings.setSilenceGapMinutes(minutes);
    notifyListeners();
  }

  Future<void> disconnect() async {
    _watchdogTimer?.cancel(); // Stop watchdog so it doesn't auto-reconnect
    await _deviceConnection?.disconnect();
    _onDeviceDisconnected();
    // Clear last device so watchdog doesn't try to reconnect
    _lastDeviceId = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastDeviceKey);
    // Restart watchdog (will do nothing without lastDeviceId)
    _startWatchdog();
  }

  // ─── Private ───────────────────────────────────────────────────────────────

  void _setConnectionState(RecLoConnectionState state) {
    _connectionState = state;
    notifyListeners();
  }

  @override
  void dispose() {
    _watchdogTimer?.cancel();
    _audioSubscription?.cancel();
    _batterySubscription?.cancel();
    _chunkManager.dispose();
    super.dispose();
  }
}