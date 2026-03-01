import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as ble;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reclo/backend/schema/bt_device/bt_device.dart';
import 'package:reclo/pages/settings_screen.dart';
import 'package:reclo/services/audio_chunk_manager.dart';
import 'package:reclo/services/chunk_upload_service.dart';
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
  UploadProgress? _uploadProgress;

  double _silenceThresholdDb = RecLoSettings.defaultDbThreshold;
  double _silenceGapMinutes = RecLoSettings.defaultSilenceGapMinutes;

  ChunkUploadService? _uploadService;
  StreamSubscription<UploadProgress>? _uploadProgressSubscription;
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
  UploadProgress? get uploadProgress => _uploadProgress;
  double get silenceThresholdDb => _silenceThresholdDb;
  double get silenceGapMinutes => _silenceGapMinutes;
  bool get isUploading =>
      _uploadProgress != null && !(_uploadProgress?.isComplete ?? true);
  String? get lastDeviceId => _lastDeviceId;

  /// Exposed for DeviceSettingsScreen to call device-specific methods
  OmiDeviceConnection? get deviceConnection => _deviceConnection;

  // ─── Init ──────────────────────────────────────────────────────────────────

  Future<void> init() async {
    _silenceThresholdDb = await RecLoSettings.getDbThreshold();
    _silenceGapMinutes = await RecLoSettings.getSilenceGapMinutes();

    final prefs = await SharedPreferences.getInstance();
    _lastDeviceId = prefs.getString(_lastDeviceKey);

    _startWatchdog();
    notifyListeners();
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
              : 'RecLo Device',
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

      // Device info was already fetched inside connect() via BtDevice.getDeviceInfo().
      // Use _deviceConnection!.device which has the correct values (with fallbacks).
      final d = _deviceConnection!.device;
      _connectedDevice = BtDevice(
        id: device.remoteId.str,
        name: device.platformName.isNotEmpty
            ? device.platformName
            : 'RecLo Device',
        type: DeviceType.omi,
        rssi: 0,
        firmwareRevision: d.firmwareRevision,
        hardwareRevision: d.hardwareRevision,
        modelNumber: d.modelNumber,
        manufacturerName: d.manufacturerName,
      );

      // Remember this device for watchdog reconnect
      _lastDeviceId = device.remoteId.str;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastDeviceKey, _lastDeviceId!);

      // Request high connection priority for faster upload
      try {
        await device.requestConnectionPriority(
            connectionPriorityRequest: ble.ConnectionPriority.high);
      } catch (e) {
        debugPrint('RecLoProvider: Priority request failed: $e');
      }

      await _startBatteryMonitor();

      // Mark connected before attempting upload — the device is connected
      // regardless of whether the RecLo transfer service is present.
      _setConnectionState(RecLoConnectionState.connected);

      try {
        await _startChunkUpload(transport);
      } catch (e) {
        debugPrint('RecLoProvider: Chunk upload start failed: $e');
      }

      return true;
    } catch (e) {
      debugPrint('RecLoProvider: Connection failed: $e');
      _deviceConnection = null;
      _connectedDevice = null;
      _setConnectionState(RecLoConnectionState.disconnected);
      return false;
    }
  }

  /// Start the batch chunk upload from the device.
  Future<void> _startChunkUpload(DeviceTransport transport) async {
    await _uploadProgressSubscription?.cancel();
    await _uploadService?.dispose();

    _uploadService = ChunkUploadService(
      transport: transport,
      silenceThresholdDb: _silenceThresholdDb,
      conversationGapThreshold: Duration(
        seconds: (_silenceGapMinutes * 60).round(),
      ),
      onConversationReady: (conversation) {
        _conversations.add(conversation);
        notifyListeners();
      },
    );

    _uploadProgressSubscription = _uploadService!.progress.listen((progress) {
      _uploadProgress = progress;
      notifyListeners();
    });

    await _uploadService!.start();
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
    _uploadProgressSubscription?.cancel();
    _uploadProgressSubscription = null;
    _uploadService?.stop();
    _uploadService = null;
    _uploadProgress = null;
    _batterySubscription?.cancel();
    _connectedDevice = null;
    _batteryLevel = -1;
    _setConnectionState(RecLoConnectionState.disconnected);
  }

  // ─── Watchdog ──────────────────────────────────────────────────────────────

  void _startWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (_connectionState != RecLoConnectionState.disconnected) return;
      if (_lastDeviceId == null) return;

      debugPrint('RecLoProvider: Watchdog — trying to reconnect to $_lastDeviceId');

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

  Future<void> updateSilenceThreshold(double db) async {
    _silenceThresholdDb = db;
    _uploadService?.silenceThresholdDb = db;
    await RecLoSettings.setDbThreshold(db);
    notifyListeners();
  }

  Future<void> updateSilenceGap(double minutes) async {
    _silenceGapMinutes = minutes;
    _uploadService?.conversationGapThreshold =
        Duration(seconds: (minutes * 60).round());
    await RecLoSettings.setSilenceGapMinutes(minutes);
    notifyListeners();
  }

  Future<void> disconnect() async {
    _watchdogTimer?.cancel();
    await _deviceConnection?.disconnect();
    _onDeviceDisconnected();
    _lastDeviceId = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastDeviceKey);
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
    _uploadProgressSubscription?.cancel();
    _batterySubscription?.cancel();
    _uploadService?.dispose();
    super.dispose();
  }
}
