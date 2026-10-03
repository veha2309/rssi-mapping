import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';

class BeaconReading {
  BeaconReading({
    required this.deviceId,
    required this.name,
    required this.rssi,
    required this.seenAt,
    required this.manufacturerHex,
    required this.services,
  });
  final String deviceId;
  final String name;
  final int rssi;
  final DateTime seenAt;
  final String manufacturerHex;
  final String services;
}

abstract class Scanner {
  bool get supported;
  Stream<BeaconReading> get readings;
  Future<void> start();
  Future<void> stop();
  Future<void> dispose();
}

class AndroidBleScanner implements Scanner {
  FlutterReactiveBle? _ble;
  StreamSubscription<DiscoveredDevice>? _subscription;
  final _readings = StreamController<BeaconReading>.broadcast();
  @override
  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  @override
  Stream<BeaconReading> get readings => _readings.stream;

  @override
  Future<void> start() async {
    if (!supported) {
      throw StateError(
        'Live scanning requires an Android phone. Use manual mode here.',
      );
    }
    final permissions = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    // Bluetooth permissions are not applicable on older Android versions.
    if (!permissions[Permission.locationWhenInUse]!.isGranted) {
      throw StateError(
        'Allow precise location for beacon discovery in Android settings.',
      );
    }
    _ble ??= FlutterReactiveBle();
    final status = await _ble!.statusStream
        .firstWhere((s) => s != BleStatus.unknown)
        .timeout(const Duration(seconds: 8));
    if (status != BleStatus.ready) {
      throw StateError(
        'Bluetooth is ${status.name}. Enable Bluetooth and Location, and allow Nearby devices.',
      );
    }
    await _subscription?.cancel();
    _subscription = _ble!
        .scanForDevices(withServices: [], scanMode: ScanMode.lowLatency)
        .listen((device) {
          if (device.rssi < -127 || device.rssi >= 0) return;
          _readings.add(
            BeaconReading(
              deviceId: device.id,
              name: device.name,
              rssi: device.rssi,
              seenAt: DateTime.now(),
              manufacturerHex: device.manufacturerData
                  .map((b) => b.toRadixString(16).padLeft(2, '0'))
                  .join(' '),
              services: device.serviceUuids.join(', '),
            ),
          );
        }, onError: (Object error) => _readings.addError(error));
  }

  @override
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _readings.close();
  }
}
