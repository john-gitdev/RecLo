import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';

import 'package:reclo/backend/schema/bt_device/bt_device.dart';
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
  Future<StreamSubscription?> performGetBleAudioBytesListener({
    required void Function(List<int>) onAudioBytesReceived,
  }) async {
    try {
      final stream = transport.getCharacteristicStream(omiServiceUuid, audioDataStreamCharacteristicUuid);
      debugPrint('Subscribed to audioBytes stream from Omi Device');
      return stream.listen((value) {
        if (value.isNotEmpty) onAudioBytesReceived(value);
      });
    } catch (e) {
      debugPrint('OmiDeviceConnection: Error setting up audio listener: $e');
      return null;
    }
  }

  @override
  Future<BleAudioCodec> performGetAudioCodec() async {
    try {
      final codecValue = await transport.readCharacteristic(omiServiceUuid, audioCodecCharacteristicUuid);
      var codecId = 1;
      if (codecValue.isNotEmpty) {
        codecId = codecValue[0];
      }

      switch (codecId) {
        case 1:
          return BleAudioCodec.pcm8;
        case 20:
          return BleAudioCodec.opus;
        case 21:
          return BleAudioCodec.opusFS320;
        default:
          debugPrint('OmiDeviceConnection: Unknown codec id: $codecId');
          return BleAudioCodec.pcm8;
      }
    } catch (e) {
      debugPrint('OmiDeviceConnection: Error reading audio codec: $e');
      return BleAudioCodec.pcm8;
    }
  }

  @override
  Future<void> performSetAudioCodec(int codecId) async {
    try {
      await transport.writeCharacteristic(omiServiceUuid, audioCodecCharacteristicUuid, [codecId]);
      debugPrint('OmiDeviceConnection: Audio codec set to $codecId');
    } catch (e) {
      debugPrint('OmiDeviceConnection: Error setting audio codec: $e');
    }
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