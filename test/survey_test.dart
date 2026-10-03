import 'dart:async';
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:rssi_mapping/ble_scanner.dart';
import 'package:rssi_mapping/models.dart';
import 'package:rssi_mapping/survey_controller.dart';

class FakeScanner implements Scanner {
  final stream = StreamController<BeaconReading>.broadcast(sync: true);
  @override
  bool get supported => true;
  @override
  Stream<BeaconReading> get readings => stream.stream;
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async => stream.close();
  void emit(String id, int rssi, {DateTime? seenAt}) => stream.add(
    BeaconReading(
      deviceId: id,
      name: 'test',
      rssi: rssi,
      seenAt: seenAt ?? DateTime.now(),
      manufacturerHex: '',
      services: '',
    ),
  );
}

SurveySample sample(Offset point, double value) => SurveySample(
  id: '$point',
  position: point,
  beaconSerial: 'IW26060986',
  rssi: value,
  source: SampleSource.manual,
  timestamp: DateTime.utc(2026, 10, 3),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('heat scale clamps at -90 blue and -70 strongest', () {
    expect(rssiColor(-90), heatColors.first);
    expect(rssiColor(-100), heatColors.first);
    expect(rssiColor(-60), heatColors.last);
    expect(rssiColor(-20), heatColors.last);
    expect(rssiColor(-80), heatColors[2]);
    expect(rssiColor(-60), const Color(0xFFFF0000));
  });
  test('weak signals are faint and strongest signals are fully red', () {
    expect(rssiOverlayColor(-90).a, closeTo(.08, .001));
    expect(rssiOverlayColor(-110).a, closeTo(.08, .001));
    expect(rssiOverlayColor(-80).a, closeTo(.54, .001));
    expect(rssiOverlayColor(-60), const Color(0xFFFF0000));
    expect(rssiOverlayColor(-40), const Color(0xFFFF0000));
    final levels = [
      -90.0,
      -85.0,
      -80.0,
      -75.0,
      -70.0,
    ].map((rssi) => rssiOverlayColor(rssi).a).toList();
    for (var i = 1; i < levels.length; i++) {
      expect(levels[i], greaterThan(levels[i - 1]));
    }
  });
  test('maximum-opacity control preserves relative strength opacity', () {
    expect(rssiOverlayColor(-90, maxOpacity: .5).a, closeTo(.04, .001));
    expect(rssiOverlayColor(-60, maxOpacity: .5).a, closeTo(.5, .001));
    expect(rssiOverlayColor(-60, maxOpacity: 2).a, 1);
    expect(rssiOverlayColor(-60, maxOpacity: -1).a, 0);
  });
  test('interpolation preserves measurements, averages duplicates, and leaves gaps empty', () {
    final data = [
      sample(const Offset(.5, .5), -50),
      sample(const Offset(.5, .5), -70),
    ];
    expect(interpolateRssi(const Offset(.5, .5), data, aspectRatio: .6), -60);
    expect(
      interpolateRssi(const Offset(.99, .99), data, aspectRatio: .6),
      isNull,
    );
    final balanced = [
      sample(const Offset(.4, .5), -40),
      sample(const Offset(.6, .5), -80),
    ];
    expect(
      interpolateRssi(const Offset(.5, .5), balanced, aspectRatio: .6),
      closeTo(-60, .0001),
    );
  });
  test('distance respects rectangular floor plans', () {
    final data = [sample(const Offset(.5, .5), -60)];
    expect(
      interpolateRssi(const Offset(.8, .5), data, aspectRatio: .5, radius: .2),
      closeTo(-60, .0001),
    );
    expect(
      interpolateRssi(const Offset(.5, .8), data, aspectRatio: .5, radius: .2),
      isNull,
    );
  });
  test('manual samples remain separated by beacon and data source; demo is never persisted', () async {
    final controller = SurveyController(scanner: FakeScanner());
    await controller.load();
    controller.selectPosition(const Offset(.25, .75));
    await controller.addManual({0: -54, 1: -72});
    expect(controller.visibleSamples.single.rssi, -54);
    controller.selectBeacon(1);
    expect(controller.visibleSamples.single.rssi, -72);
    controller.setSource(SampleSource.live);
    expect(controller.visibleSamples, isEmpty);
    controller.setSource(SampleSource.demo);
    expect(controller.visibleSamples, hasLength(9));
    expect((controller.exportData()['samples'] as List), hasLength(2));
    controller.setSource(SampleSource.manual);
    await controller.undo();
    expect(controller.samples, isEmpty);
    controller.dispose();
  });
  test(
    'survey restores normalized coordinates and exact device bindings',
    () async {
      final original = SurveyController(scanner: FakeScanner());
      await original.load();
      await original.bindDevice(0, 'AA:BB:CC:00:4B:4F');
      original.selectPosition(const Offset(.123, .876));
      await original.addManual({0: -67});
      original.dispose();
      final restored = SurveyController(scanner: FakeScanner());
      await restored.load();
      expect(restored.samples.single.position, const Offset(.123, .876));
      expect(restored.samples.single.source, SampleSource.manual);
      expect(restored.beacons[0].deviceId, 'AA:BB:CC:00:4B:4F');
      restored.dispose();
    },
  );
  test('one physical device cannot be assigned to both test beacons', () async {
    final controller = SurveyController(scanner: FakeScanner());
    await controller.load();
    await controller.bindDevice(0, 'test-id');
    await expectLater(controller.bindDevice(1, 'test-id'), throwsStateError);
    controller.dispose();
  });
  test('live capture ignores old and unrelated readings, locks position, uses median', () async {
    final scanner = FakeScanner();
    final controller = SurveyController(scanner: scanner);
    await controller.load();
    controller.setSource(SampleSource.live);
    await controller.bindDevice(0, 'a');
    await controller.bindDevice(1, 'b');
    await controller.setBeaconPosition(0, const Offset(.1, .2));
    await controller.setBeaconPosition(1, const Offset(.8, .9));
    controller.selectPosition(const Offset(.3, .4));
    await controller.toggleScan();
    scanner.emit('a', -20);
    final capture = controller.capture(
      duration: const Duration(milliseconds: 30),
    );
    controller.selectPosition(const Offset(.8, .9));
    expect(controller.position, const Offset(.3, .4));
    scanner.emit(
      'a',
      -100,
      seenAt: DateTime.now().subtract(const Duration(seconds: 10)),
    );
    for (final value in [
      -62,
      -61,
      -61,
      -60,
      -60,
      -60,
      -60,
      -59,
      -59,
      -58,
      -100,
      -20,
    ]) {
      scanner.emit('a', value);
    }
    scanner.emit('unrelated', -30);
    scanner.emit('b', -55); // Too few advertisements to save.
    final result = await capture;
    expect(result, contains('1 beacon sample saved'));
    expect(controller.samples.single.rssi, -60);
    expect(controller.samples.single.readingCount, 10);
    expect(controller.samples.single.rejectedCount, 2);
    expect(controller.rawLog, hasLength(13));
    expect(controller.rawLog.where((p) => p.outlier == true), hasLength(2));
    expect(controller.samples.single.deviceId, 'a');
    expect(controller.samples.single.position, const Offset(.3, .4));
    controller.dispose();
  });
  test('a stopped scan cannot produce a completed live sample', () async {
    final scanner = FakeScanner();
    final controller = SurveyController(scanner: scanner);
    await controller.load();
    controller.setSource(SampleSource.live);
    await controller.bindDevice(0, 'a');
    controller.selectPosition(const Offset(.5, .5));
    await controller.setBeaconPosition(0, const Offset(.1, .2));
    await controller.toggleScan();
    final capture = controller.capture(
      duration: const Duration(milliseconds: 30),
    );
    for (var i = 0; i < 10; i++) {
      scanner.emit('a', -60);
    }
    await controller.suspendScan();
    await capture;
    expect(controller.samples, isEmpty);
    controller.dispose();
  });
  test('replacing floor clears coordinates and measurements tied to previous floor', () async {
    final controller = SurveyController(scanner: FakeScanner());
    await controller.load();
    controller.selectPosition(const Offset(.5, .5));
    await controller.addManual({0: -60});
    await controller.replaceFloor(null, 'new plan', 1.5);
    expect(controller.samples, isEmpty);
    expect(controller.position, isNull);
    expect(controller.aspectRatio, 1.5);
    controller.dispose();
  });
}
