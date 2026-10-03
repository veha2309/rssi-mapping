import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:rssi_mapping/models.dart';
import 'package:rssi_mapping/survey_controller.dart';

import 'survey_test.dart' show FakeScanner;

Future<SurveyController> ready(FakeScanner scanner) async {
  final controller = SurveyController(scanner: scanner);
  await controller.load();
  await controller.bindDevice(0, 'a');
  await controller.bindDevice(1, 'b');
  await controller.setBeaconPosition(0, const Offset(.1, .2));
  await controller.setBeaconPosition(1, const Offset(.8, .9));
  controller.setSource(SampleSource.live);
  controller.selectPosition(const Offset(.25, .75));
  await controller.toggleScan();
  return controller;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('filter rejects isolated spikes, handles zero MAD, and keeps real variation', () {
    final readings = FilteredReadings([
      -80,
      -80,
      -80,
      -80,
      -80,
      -80,
      -80,
      -80,
      -80,
      -80,
      -79,
      -85,
      -40,
      -110,
    ]);
    expect(readings.mad, 0);
    expect(readings.cutoffDb, 6);
    expect(readings.rejectedCount, 2);
    expect(readings.accepted, contains(-85));
    expect(readings.value, -80);
    final varied = FilteredReadings([
      -85,
      -83,
      -81,
      -79,
      -77,
      -75,
      -73,
      -71,
      -69,
      -67,
    ]);
    expect(varied.rejectedCount, 0);
    expect(varied.spreadDb, greaterThan(12));
    expect(FilteredReadings([]).value, isNull);
  });

  test('logging isolates assigned devices even in unfiltered discovery and persists/export raw packets', () async {
    final scanner = FakeScanner();
    final controller = await ready(scanner);
    controller.setShowAllDevices(true);
    await controller.toggleLogging();
    scanner.emit('other', -40);
    scanner.emit('a', -75);
    scanner.emit('b', -84);
    scanner.emit('a', 0);
    scanner.emit(
      'a',
      -100,
      seenAt: DateTime.now().subtract(const Duration(seconds: 10)),
    );
    controller.selectPosition(const Offset(.5, .5));
    scanner.emit('a', -79);
    await controller.toggleLogging();
    scanner.emit('b', -72);
    expect(controller.rawLog, hasLength(3));
    expect(controller.samples, isEmpty);
    expect(controller.rawLog.first.position, const Offset(.25, .75));
    expect(controller.rawLog.first.beaconPosition, const Offset(.1, .2));
    expect(
      (controller.rawLog.first.toJson()['relativeToBeacon'] as Map)['dx'],
      closeTo(.15, .001),
    );
    expect(controller.rawLog.last.position, const Offset(.5, .5));
    expect(
      controller.rawLog.every(
        (p) => p.outlier == null && p.usedInSample == null,
      ),
      isTrue,
    );
    final exported = controller.exportData();
    expect(exported['schemaVersion'], 2);
    expect(exported['rawLog'], hasLength(3));
    expect(
      (exported['logSessions'] as List).single['stopReason'],
      'user_stopped',
    );
    expect((exported['rawLog'] as List).first['timestamp'], endsWith('Z'));
    controller.dispose();
    final restored = SurveyController(scanner: FakeScanner());
    await restored.load();
    expect(restored.rawLog, hasLength(3));
    expect(restored.logging, isFalse);
    expect(restored.rawLog.first.sessionId, isNotNull);
    restored.dispose();
  });

  test('capture logs failures, both beacons, timestamps and per-beacon decisions without double logging', () async {
    final scanner = FakeScanner();
    final controller = await ready(scanner);
    await controller.toggleLogging();
    final capture = controller.capture(
      duration: const Duration(milliseconds: 80),
    );
    for (var i = 0; i < 10; i++) {
      scanner.emit('a', -84);
    }
    scanner.emit('a', -40);
    for (var i = 0; i < 9; i++) {
      scanner.emit('b', -74);
    }
    await capture;
    await controller.toggleLogging();
    expect(
      controller.samples.single.rssi,
      -84,
    ); // Weak points are genuine measurements.
    expect(controller.samples.single.readingCount, 10);
    expect(controller.samples.single.rejectedCount, 1);
    expect(controller.rawLog, hasLength(20));
    expect(
      controller.rawLog.every(
        (p) => p.captureId != null && p.sessionId != null,
      ),
      isTrue,
    );
    expect(
      controller.rawLog.where((p) => p.usedInSample == true),
      hasLength(10),
    );
    expect(controller.captureLog.map((s) => s['status']), [
      'saved',
      'insufficient_readings',
    ]);
    expect(controller.captureLog.first['cutoffDb'], 6);
    expect(controller.captureLog.first['requestedDurationMs'], 80);
    await controller.save();
    controller.dispose();
    final restored = SurveyController(scanner: FakeScanner());
    await restored.load();
    expect(restored.samples.single.captureId, restored.rawLog.first.captureId);
    expect(restored.rawLog.last.usedInSample, isFalse);
    expect(restored.captureLog, hasLength(2));
    await restored.clearRawLog();
    expect(restored.rawLog, isEmpty);
    expect(restored.samples, hasLength(1));
    restored.dispose();
  });

  test(
    'scan suspension closes logging and interrupted captures cannot be used',
    () async {
      final scanner = FakeScanner();
      final controller = await ready(scanner);
      await controller.toggleLogging();
      final capture = controller.capture(
        duration: const Duration(milliseconds: 80),
      );
      for (var i = 0; i < 10; i++) {
        scanner.emit('a', -75);
      }
      await controller.suspendScan();
      scanner.emit('a', -60);
      await capture;
      expect(controller.logging, isFalse);
      expect(controller.rawLog, hasLength(10));
      expect(controller.samples, isEmpty);
      expect(controller.captureLog.first['status'], 'interrupted');
      expect(controller.rawLog.every((p) => p.usedInSample == false), isTrue);
      controller.dispose();
    },
  );

  test(
    'range and capture time persist; existing schema 1 samples remain readable',
    () async {
      final controller = SurveyController(scanner: FakeScanner());
      await controller.load();
      expect(controller.captureSeconds, 15);
      await controller.setCaptureSeconds(30);
      await controller.setThresholds(-85, -65);
      expect(
        rssiOverlayColor(-85, weak: -85, strong: -65).a,
        closeTo(.08, .001),
      );
      expect(
        rssiOverlayColor(-65, weak: -85, strong: -65),
        const Color(0xFFFF0000),
      );
      await expectLater(
        controller.setThresholds(-70, -80),
        throwsArgumentError,
      );
      await expectLater(
        controller.setThresholds(double.nan, -60),
        throwsArgumentError,
      );
      controller.selectPosition(const Offset(.3, .3));
      await controller.addManual({0: -80});
      final old = controller.samples.single.toJson()
        ..remove('rejectedCount')
        ..remove('spreadDb')
        ..remove('captureId');
      expect(SurveySample.fromJson(old).readingCount, 1);
      expect(SurveySample.fromJson(old).rejectedCount, 0);
      controller.dispose();
      final restored = SurveyController(scanner: FakeScanner());
      await restored.load();
      expect(restored.captureSeconds, 30);
      expect(restored.weakThreshold, -85);
      expect(restored.strongThreshold, -65);
      restored.dispose();
    },
  );

  test(
    'full log stops recording visibly and never silently discards old packets',
    () async {
      final scanner = FakeScanner();
      final controller = await ready(scanner);
      await controller.toggleLogging();
      final existing = RssiLogEntry(
        timestamp: DateTime.now(),
        beaconSerial: controller.beacons[0].serial,
        deviceId: 'a',
        rssi: -80,
      );
      controller.rawLog.addAll(
        List.filled(SurveyController.logLimit - 1, existing),
      );
      scanner.emit('b', -75);
      scanner.emit('b', -74);
      expect(controller.rawLog, hasLength(SurveyController.logLimit));
      expect(controller.rawLog.last.rssi, -75);
      expect(controller.logging, isFalse);
      expect(controller.message, contains('full'));
      expect(await controller.capture(), contains('full'));
      await controller.clearRawLog();
      expect(controller.rawLog, isEmpty);
      controller.dispose();
    },
  );
}
