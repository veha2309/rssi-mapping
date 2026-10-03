import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:rssi_mapping/ble_scanner.dart';
import 'package:rssi_mapping/models.dart';
import 'package:rssi_mapping/survey_controller.dart';
import 'package:rssi_mapping/survey_screen.dart';

class FilterTestScanner implements Scanner {
  final events = StreamController<BeaconReading>.broadcast(sync: true);
  @override
  bool get supported => true;
  @override
  Stream<BeaconReading> get readings => events.stream;
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async => events.close();
  void emit(String id, {String name = ''}) => events.add(
    BeaconReading(
      deviceId: id,
      name: name,
      rssi: -60,
      seenAt: DateTime.now(),
      manufacturerHex: '',
      services: '',
    ),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'unassigned beacon matches only valid MAC suffixes or full serial tokens',
    () {
      final beacon = testBeacons().first;
      expect(beacon.matchesDiscovery('11:22:33:00:4b:4f', ''), isTrue);
      expect(beacon.matchesDiscovery('11-22-33-00-4B-4F', ''), isTrue);
      expect(beacon.matchesDiscovery('11:22:33:00:01:A2', 'iWAY'), isFalse);
      expect(beacon.matchesDiscovery('unknown', 'iWAY IW26060986'), isTrue);
      expect(beacon.matchesDiscovery('unknown', 'IW260609860'), isFalse);
      expect(
        beacon.matchesDiscovery('00000000-0000-0000-0000-112233004b4f', ''),
        isFalse,
      );
    },
  );
  test('full binding overrides suffix and advertised name candidates', () {
    final beacon = testBeacons().first..deviceId = '11:22:33:00:4B:4F';
    expect(beacon.matchesDiscovery('11-22-33-00-4b-4f', ''), isTrue);
    expect(beacon.matchesDiscovery('AA:BB:CC:00:4B:4F', 'IW26060986'), isFalse);
  });
  test(
    'default scan drops unrelated packets without notifying the UI',
    () async {
      final scanner = FilterTestScanner();
      final controller = SurveyController(scanner: scanner);
      await controller.load();
      await controller.toggleScan();
      var changes = 0;
      controller.addListener(() => changes++);
      for (var i = 0; i < 100; i++) {
        scanner.emit('unrelated-$i');
      }
      expect(controller.devices, isEmpty);
      expect(changes, 0);
      scanner.emit('11:22:33:00:4B:4F');
      scanner.emit('11:22:33:00:01:A2');
      expect(controller.discoveryDevices, hasLength(2));
      expect(changes, 2);
      controller.dispose();
    },
  );
  test('show all allows assignment with arbitrary IDs, then only bound IDs survive', () async {
    final scanner = FilterTestScanner();
    final controller = SurveyController(scanner: scanner);
    await controller.load();
    await controller.toggleScan();
    controller.setShowAllDevices(true);
    scanner.emit('first-custom-id');
    scanner.emit('second-custom-id');
    scanner.emit('unrelated');
    expect(controller.discoveryDevices, hasLength(3));
    await controller.bindDevice(0, 'first-custom-id');
    await controller.bindDevice(1, 'second-custom-id');
    controller.setShowAllDevices(false);
    expect(controller.devices, hasLength(2));
    scanner.emit('11:22:33:00:4B:4F', name: 'IW26060986');
    scanner.emit('unrelated');
    expect(controller.discoveryDevices, hasLength(2));
    controller.dispose();
    final restored = SurveyController(scanner: FilterTestScanner());
    await restored.load();
    expect(restored.showAllDevices, isFalse);
    expect(restored.beacons.first.deviceId, 'first-custom-id');
    restored.dispose();
  });
  test(
    'MAC formatting cannot bypass duplicate assignment prevention',
    () async {
      final controller = SurveyController(scanner: FilterTestScanner());
      await controller.load();
      await controller.bindDevice(0, '11:22:33:00:4B:4F');
      await expectLater(
        controller.bindDevice(1, '11-22-33-00-4b-4f'),
        throwsStateError,
      );
      controller.dispose();
    },
  );
  testWidgets(
    'discovery defaults to restricted mode and resets show all on closing',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final scanner = FilterTestScanner();
      final controller = SurveyController(scanner: scanner);
      controller.setSource(SampleSource.live);
      await tester.pumpWidget(
        MaterialApp(home: SurveyScreen(controller: controller)),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Discover & assign'));
      await tester.tap(find.text('Discover & assign'));
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(ChoiceChip, 'Only my beacons'),
        findsOneWidget,
      );
      expect(controller.showAllDevices, isFalse);
      await tester.tap(find.text('Start scan'));
      await tester.pumpAndSettle();
      scanner.emit('11:22:33:00:4B:4F');
      scanner.emit('noise-device');
      await tester.pump();
      expect(find.text('11:22:33:00:4B:4F'), findsOneWidget);
      expect(find.text('noise-device'), findsNothing);
      await tester.tap(find.text('Show all devices'));
      await tester.pump();
      scanner.emit('noise-device');
      await tester.pump();
      expect(find.text('noise-device'), findsOneWidget);
      Navigator.of(tester.element(find.text('Discover your beacons'))).pop();
      await tester.pumpAndSettle();
      expect(controller.showAllDevices, isFalse);
      expect(controller.devices.containsKey('NOISE-DEVICE'), isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
}
