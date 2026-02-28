import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'package:reclo/backend/schema/bt_device/bt_device.dart';
import 'package:reclo/services/devices/models.dart';
import 'package:reclo/utils/logger.dart';

enum DeviceConnectionState {
  disconnected,
  connected,
}

enum DeviceTransportState {
  disconnected,
  connecting,
  connected,
  disconnecting,
}

abstract class DeviceTransport {
  String get deviceId;
  Future<void> connect();
  Future<void> disconnect();
  Future<bool> isConnected();
  Future<bool> ping();
  Stream<List<int>> getCharacteristicStream(String serviceUuid, String characteristicUuid);
  Future<List<int>> readCharacteristic(String serviceUuid, String characteristicUuid);
  Future<void> writeCharacteristic(String serviceUuid, String characteristicUuid, List<int> data);
  Stream<DeviceTransportState> get connectionStateStream;
  Future<void> dispose();
}

class BleTransport extends DeviceTransport {
  final BluetoothDevice _bleDevice;
  final StreamController<DeviceTransportState> _connectionStateController;
  final Map<String, StreamController<List<int>>> _streamControllers = {};
  final Map<String, StreamSubscription> _characteristicSubscriptions = {};

  List<BluetoothService> _services = [];
  DeviceTransportState _state = DeviceTransportState.disconnected;
  StreamSubscription<BluetoothConnectionState>? _bleConnectionSubscription;

  BleTransport(this._bleDevice) : _connectionStateController = StreamController<DeviceTransportState>.broadcast() {
    _bleConnectionSubscription = _bleDevice.connectionState.listen((state) {
      switch (state) {
        case BluetoothConnectionState.disconnected:
          _updateState(DeviceTransportState.disconnected);
          break;
        case BluetoothConnectionState.connecting:
          _updateState(DeviceTransportState.connecting);
          break;
        case BluetoothConnectionState.connected:
          _updateState(DeviceTransportState.connected);
          break;
        case BluetoothConnectionState.disconnecting:
          _updateState(DeviceTransportState.disconnecting);
          break;
      }
    });
  }

  @override
  String get deviceId => _bleDevice.remoteId.str;

  @override
  Stream<DeviceTransportState> get connectionStateStream => _connectionStateController.stream;

  void _updateState(DeviceTransportState newState) {
    if (_state != newState) {
      _state = newState;
      _connectionStateController.add(_state);
    }
  }

  @override
  Future<void> connect() async {
    if (_state == DeviceTransportState.connected) return;
    _updateState(DeviceTransportState.connecting);
    try {
      await _bleDevice.connect(autoConnect: false, license: License.free);
      await _bleDevice.connectionState.where((val) => val == BluetoothConnectionState.connected).first;
      if (Platform.isAndroid && _bleDevice.mtuNow < 512) {
        await _bleDevice.requestMtu(512);
      }
      _services = await _bleDevice.discoverServices();
      _updateState(DeviceTransportState.connected);
    } catch (e) {
      _updateState(DeviceTransportState.disconnected);
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    if (_state == DeviceTransportState.disconnected) return;
    _updateState(DeviceTransportState.disconnecting);
    try {
      for (final subscription in _characteristicSubscriptions.values) await subscription.cancel();
      _characteristicSubscriptions.clear();
      for (final controller in _streamControllers.values) await controller.close();
      _streamControllers.clear();
      await _bleDevice.disconnect();
      _updateState(DeviceTransportState.disconnected);
    } catch (e) {
      _updateState(DeviceTransportState.disconnected);
      rethrow;
    }
  }

  @override
  Future<bool> isConnected() async => _bleDevice.isConnected;

  @override
  Future<bool> ping() async {
    try {
      await _bleDevice.readRssi(timeout: 10);
      return true;
    } catch (e) {
      return false;
    }
  }

  @override
  Stream<List<int>> getCharacteristicStream(String serviceUuid, String characteristicUuid) {
    final key = '$serviceUuid:$characteristicUuid';
    if (!_streamControllers.containsKey(key)) {
      _streamControllers[key] = StreamController<List<int>>.broadcast();
      _setupCharacteristicListener(serviceUuid, characteristicUuid, key);
    }
    return _streamControllers[key]!.stream;
  }

  Future<void> _setupCharacteristicListener(String serviceUuid, String characteristicUuid, String key) async {
    try {
      final characteristic = await _getCharacteristic(serviceUuid, characteristicUuid);
      if (characteristic == null) return;
      await characteristic.setNotifyValue(true);
      final subscription = characteristic.lastValueStream.listen((value) {
        if (_streamControllers[key] != null && !_streamControllers[key]!.isClosed) {
          _streamControllers[key]!.add(value);
        }
      });
      _characteristicSubscriptions[key] = subscription;
    } catch (e) {
      debugPrint('BleTransport: Error setting up listener: $e');
    }
  }

  @override
  Future<List<int>> readCharacteristic(String serviceUuid, String characteristicUuid) async {
    final characteristic = await _getCharacteristic(serviceUuid, characteristicUuid);
    if (characteristic == null) return [];
    try {
      return await characteristic.read();
    } catch (e) {
      return [];
    }
  }

  @override
  Future<void> writeCharacteristic(String serviceUuid, String characteristicUuid, List<int> data) async {
    final characteristic = await _getCharacteristic(serviceUuid, characteristicUuid);
    if (characteristic == null) throw Exception('Characteristic not found');
    try {
      final needsLongWrite = data.length > (_bleDevice.mtuNow - 3);
      await characteristic.write(data, allowLongWrite: needsLongWrite);
    } catch (e) {
      rethrow;
    }
  }

  Future<BluetoothCharacteristic?> _getCharacteristic(String serviceUuid, String characteristicUuid) async {
    final service = _services.firstWhereOrNull((s) => s.uuid.str128.toLowerCase() == serviceUuid.toLowerCase());
    if (service == null) return null;
    return service.characteristics.firstWhereOrNull((c) => c.uuid.str128.toLowerCase() == characteristicUuid.toLowerCase());
  }

  @override
  Future<void> dispose() async {
    await _bleConnectionSubscription?.cancel();
    for (final subscription in _characteristicSubscriptions.values) await subscription.cancel();
    for (final controller in _streamControllers.values) await controller.close();
    await _connectionStateController.close();
  }
}

class DeviceConnectionException implements Exception {
  final String message;
  DeviceConnectionException(this.message);
  @override
  String toString() => 'DeviceConnectionException: $message';
}

abstract class DeviceConnection {
  BtDevice device;
  DeviceTransport transport;
  DeviceConnectionState _connectionState = DeviceConnectionState.disconnected;
  DeviceConnectionState get connectionState => _connectionState;
  StreamSubscription<DeviceTransportState>? _transportStateSubscription;
  Function(String deviceId, DeviceConnectionState state)? _connectionStateChangedCallback;

  DeviceConnection(this.device, this.transport) {
    _transportStateSubscription = transport.connectionStateStream.listen((transportState) {
      final deviceState = transportState == DeviceTransportState.connected ? DeviceConnectionState.connected : DeviceConnectionState.disconnected;
      if (_connectionState != deviceState) {
        _connectionState = deviceState;
        _connectionStateChangedCallback?.call(device.id, _connectionState);
      }
    });
  }

  Future<void> connect({Function(String deviceId, DeviceConnectionState state)? onConnectionStateChanged}) async {
    if (_connectionState == DeviceConnectionState.connected) throw DeviceConnectionException("Already connected");
    _connectionStateChangedCallback = onConnectionStateChanged;
    try {
      await transport.connect();
      device = await device.getDeviceInfo(this);
    } catch (e) {
      throw DeviceConnectionException("Connection failed: $e");
    }
  }

  Future<void> disconnect() async {
    _connectionState = DeviceConnectionState.disconnected;
    _connectionStateChangedCallback?.call(device.id, _connectionState);
    _connectionStateChangedCallback = null;
    await transport.disconnect();
    await _transportStateSubscription?.cancel();
    _transportStateSubscription = null;
  }

  Future<bool> isConnected() async => await transport.isConnected();
  Future<int> retrieveBatteryLevel() async => await performRetrieveBatteryLevel();
  Future<int> performRetrieveBatteryLevel();
  Future<StreamSubscription<List<int>>?> getBleBatteryLevelListener({void Function(int)? onBatteryLevelChange}) async => await performGetBleBatteryLevelListener(onBatteryLevelChange: onBatteryLevelChange);
  Future<StreamSubscription<List<int>>?> performGetBleBatteryLevelListener({void Function(int)? onBatteryLevelChange});
  Future<StreamSubscription?> getBleAudioBytesListener({required void Function(List<int>) onAudioBytesReceived}) async => await performGetBleAudioBytesListener(onAudioBytesReceived: onAudioBytesReceived);
  Future<StreamSubscription?> performGetBleAudioBytesListener({required void Function(List<int>) onAudioBytesReceived});
  Future<BleAudioCodec> getAudioCodec() async => await performGetAudioCodec();
  Future<BleAudioCodec> performGetAudioCodec();

  Future<void> performSetAudioCodec(int codecId) async {}
  Future<void> setAudioCodec(int codecId) async {
    if (await isConnected()) await performSetAudioCodec(codecId);
  }

  Future<int> getFeatures() async => 3;
  Future<int> getLedDimRatio() async => 50;
  Future<int> getMicGain() async => 50;
  Future<void> setLedDimRatio(int r) async {}
  Future<void> setMicGain(int g) async {}
}
