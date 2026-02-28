import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';

import 'package:reclo/services/devices/device_connection.dart';
import 'package:reclo/services/devices/models.dart';

class OmiDeviceConnection extends DeviceConnection {
  static const String settingsServiceUuid = '19b10010-e8f2-537e-4f6c-d104768a1214';
  static const String settingsDimRatioCharacteristicUuid = '19b10011-e8f2-537e-4f6c-d104768a1214';
  static const String settingsMicGainCharacteristicUuid = '19b10012-e8f2-537e-4f6c-d104768a1214';

  OmiDeviceConnection(super.device, super.transport);

  String get deviceId => device.id;

  Future<Map<String, dynamic>> getDeviceInfo() async {
    final Map<String, dynamic> info = {};
    try {
      final model = await transport.readCharacteristic(deviceInformationServiceUuid, modelNumberCharacteristicUuid);
      if (model.isNotEmpty) info['modelNumber'] = String.fromCharCodes(model);

      final firmware = await transport.readCharacteristic(deviceInformationServiceUuid, firmwareRevisionCharacteristicUuid);
      if (firmware.isNotEmpty) info['firmwareRevision'] = String.fromCharCodes(firmware);

      final hardware = await transport.readCharacteristic(deviceInformationServiceUuid, hardwareRevisionCharacteristicUuid);
      if (hardware.isNotEmpty) info['hardwareRevision'] = String.fromCharCodes(hardware);

      final manufacturer = await transport.readCharacteristic(deviceInformationServiceUuid, manufacturerNameCharacteristicUuid);
      if (manufacturer.isNotEmpty) info['manufacturerName'] = String.fromCharCodes(manufacturer);

      final serial = await transport.readCharacteristic(deviceInformationServiceUuid, serialNumberCharacteristicUuid);
      if (serial.isNotEmpty) info['serialNumber'] = String.fromCharCodes(serial);
    } catch (e) {
      debugPrint('OmiDeviceConnection: Error getting device info: $e');
    }
    return info;
  }

  @override
  Future<void> connect({Function(String deviceId, DeviceConnectionState state)? onConnectionStateChanged}) async {
    await super.connect(onConnectionStateChanged: onConnectionStateChanged);
    await performSyncTime();
  }

  Future<bool> performSyncTime() async {
    try {
      final epochSeconds = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      final byteData = ByteData(4)..setUint32(0, epochSeconds, Endian.little);

      await transport.writeCharacteristic(
        timeSyncServiceUuid,
        timeSyncWriteCharacteristicUuid,
        byteData.buffer.asUint8List(),
      );
      debugPrint('OmiDeviceConnection: Time synced to device: $epochSeconds');
      return true;
    } catch (e) {
      debugPrint('OmiDeviceConnection: Error syncing time: $e');
      return false;
    }
  }

  @override
  Future<int> performRetrieveBatteryLevel() async {
    try {
      final data = await transport.readCharacteristic(batteryServiceUuid, batteryLevelCharacteristicUuid);
      if (data.isNotEmpty) return data[0];
      return -1;
    } catch (e) {
      debugPrint('OmiDeviceConnection: Error reading battery level: $e');
      return -1;
    }
  }

  @override
  Future<StreamSubscription<List<int>>?> performGetBleBatteryLevelListener({
    void Function(int)? onBatteryLevelChange,
  }) async {
    try {
      final stream = transport.getCharacteristicStream(batteryServiceUuid, batteryLevelCharacteristicUuid);
      return stream.listen((value) {
        if (value.isNotEmpty && onBatteryLevelChange != null) {
          onBatteryLevelChange(value[0]);
        }
      });
    } catch (e) {
      debugPrint('OmiDeviceConnection: Error setting up battery listener: $e');
      return null;
    }
  }

  @override
  Future<int> getFeatures() async {
    int features = 0;
    try {
      final dimData = await transport.readCharacteristic(settingsServiceUuid, settingsDimRatioCharacteristicUuid);
      if (dimData.isNotEmpty) features |= OmiFeatures.ledDimming;
    } catch (_) {}
    try {
      final gainData = await transport.readCharacteristic(settingsServiceUuid, settingsMicGainCharacteristicUuid);
      if (gainData.isNotEmpty) features |= OmiFeatures.micGain;
    } catch (_) {}
    return features;
  }

  @override
  Future<int> getLedDimRatio() async {
    try {
      final data = await transport.readCharacteristic(settingsServiceUuid, settingsDimRatioCharacteristicUuid);
      if (data.isNotEmpty) return data[0];
    } catch (_) {}
    return 50;
  }

  @override
  Future<int> getMicGain() async {
    try {
      final data = await transport.readCharacteristic(settingsServiceUuid, settingsMicGainCharacteristicUuid);
      if (data.isNotEmpty) return data[0];
    } catch (_) {}
    return 50;
  }

  @override
  Future<void> setLedDimRatio(int ratio) async {
    try {
      await transport.writeCharacteristic(
          settingsServiceUuid, settingsDimRatioCharacteristicUuid, [ratio.clamp(0, 100)]);
    } catch (e) {
      debugPrint('OmiDeviceConnection: Error setting LED dim ratio: $e');
    }
  }

  @override
  Future<void> setMicGain(int gain) async {
    try {
      await transport.writeCharacteristic(
          settingsServiceUuid, settingsMicGainCharacteristicUuid, [gain.clamp(0, 100)]);
    } catch (e) {
      debugPrint('OmiDeviceConnection: Error setting mic gain: $e');
    }
  }
}