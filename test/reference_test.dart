import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:rssi_mapping/models.dart';
import 'package:rssi_mapping/survey_controller.dart';

import 'survey_test.dart' show FakeScanner;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('beacon placement anchors export and moving a beacon isolates its new map', () async {
    final controller = SurveyController(scanner: FakeScanner());
    await controller.load();
    await controller.setBeaconPosition(0, const Offset(.2, .3));
    await controller.setBeaconPosition(1, const Offset(.8, .7));
    controller.selectPosition(const Offset(.4, .6));
    await controller.addManual({0: -80, 1: -70});
    final measured = controller.samples.first;
    expect(measured.beaconPosition, const Offset(.2, .3));
    expect(
      (measured.toJson()['relativeToBeacon'] as Map)['dx'],
      closeTo(.2, .001),
    );
    expect(
      (measured.toJson()['relativeToBeacon'] as Map)['dy'],
      closeTo(.3, .001),
    );
    final oldPlacement = controller.beacons[0].placementId;
    await controller.setBeaconPosition(0, const Offset(.3, .4));
    expect(controller.beacons[0].placementId, isNot(oldPlacement));
    expect(controller.visibleSamples, isEmpty);
    expect(controller.samples, hasLength(2)); // Export keeps the old reference.
    controller.selectBeacon(1);
    expect(controller.visibleSamples.single.rssi, -70);
    controller.selectBeacon(0);
    await controller.addManual({0: -75});
    expect(controller.visibleSamples.single.rssi, -75);
    await controller
        .load(); // Loading an injected controller twice cannot duplicate data.
    expect(controller.samples, hasLength(3));
    controller.dispose();
    final restored = SurveyController(scanner: FakeScanner());
    await restored.load();
    expect(restored.beacons[0].position, const Offset(.3, .4));
    expect(restored.visibleSamples.single.rssi, -75);
    expect(restored.samples.first.beaconPosition, const Offset(.2, .3));
    await restored.clearRawLog();
    expect(restored.beacons[0].position, const Offset(.3, .4));
    await restored.replaceFloor(null, 'new floor', 1);
    expect(restored.beacons.every((b) => b.position == null), isTrue);
    restored.dispose();
  });

  test('a reference preserves measured RSSI and does not invent signal around the beacon', () {
    final data = [
      SurveySample(
        id: 'p',
        position: const Offset(.6, .6),
        beaconSerial: 'IW26060986',
        rssi: -84,
        source: SampleSource.manual,
        timestamp: DateTime.now(),
        beaconPosition: const Offset(.1, .1),
      ),
    ];
    expect(
      interpolateRssi(
        const Offset(.6, .6),
        data,
        aspectRatio: .6,
        reference: const Offset(.1, .1),
      ),
      -84,
    );
    expect(
      interpolateRssi(
        const Offset(.1, .1),
        data,
        aspectRatio: .6,
        reference: const Offset(.1, .1),
      ),
      isNull,
    );
    final point = const Offset(.61, .62);
    expect(
      interpolateRssi(
        point,
        data,
        aspectRatio: .6,
        reference: const Offset(.1, .1),
      ),
      closeTo(interpolateRssi(point, data, aspectRatio: .6)!, .001),
    );
  });

  test(
    'capture requires a beacon reference and locks reference during capture',
    () async {
      final scanner = FakeScanner();
      final controller = SurveyController(scanner: scanner);
      await controller.load();
      await controller.bindDevice(0, 'a');
      controller.setSource(SampleSource.live);
      controller.selectPosition(const Offset(.5, .5));
      await controller.toggleScan();
      expect(
        await controller.capture(),
        contains('Place each assigned beacon'),
      );
      await controller.setBeaconPosition(0, const Offset(.2, .2));
      final capture = controller.capture(
        duration: const Duration(milliseconds: 80),
      );
      await controller.setBeaconPosition(0, const Offset(.8, .8));
      for (var i = 0; i < 10; i++) {
        scanner.emit('a', -80);
      }
      await capture;
      expect(controller.samples.single.beaconPosition, const Offset(.2, .2));
      expect(
        controller.rawLog.every(
          (p) => p.beaconPosition == const Offset(.2, .2),
        ),
        isTrue,
      );
      controller.dispose();
    },
  );

  test('an unfinished capture after restart keeps raw data and is marked interrupted', () async {
    final scanner = FakeScanner();
    final controller = SurveyController(scanner: scanner);
    await controller.load();
    await controller.bindDevice(0, 'a');
    await controller.setBeaconPosition(0, const Offset(.2, .2));
    controller.setSource(SampleSource.live);
    controller.selectPosition(const Offset(.5, .5));
    await controller.toggleScan();
    final capture = controller.capture(
      duration: const Duration(milliseconds: 80),
    );
    scanner.emit('a', -80);
    await controller.save();
    controller.dispose();
    await capture;
    final restored = SurveyController(scanner: FakeScanner());
    await restored.load();
    expect(restored.rawLog.single.rssi, -80);
    expect(restored.rawLog.single.usedInSample, isFalse);
    expect(restored.captureLog.single['status'], 'interrupted_app_restart');
    expect(restored.samples, isEmpty);
    restored.dispose();
  });
}
