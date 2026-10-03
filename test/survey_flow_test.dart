import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:rssi_mapping/floor_map.dart';
import 'package:rssi_mapping/models.dart';
import 'package:rssi_mapping/survey_controller.dart';
import 'package:rssi_mapping/survey_screen.dart';

import 'survey_test.dart' show FakeScanner;

class MemoryExporter extends FilePickerPlatform {
  Uint8List? bytes;
  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    this.bytes = bytes;
    return Uri.file('export.json');
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'phone: place each beacon, mark receiver, log only assigned RSSI, export, and adjust settings',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final oldExporter = FilePickerPlatform.instance;
      final exporter = MemoryExporter();
      FilePickerPlatform.instance = exporter;
      addTearDown(() => FilePickerPlatform.instance = oldExporter);
      final scanner = FakeScanner();
      final controller = SurveyController(scanner: scanner);
      try {
        await controller.load();
        await controller.bindDevice(0, 'a');
        await controller.bindDevice(1, 'b');
        controller.setSource(SampleSource.live);
        await controller.toggleScan();
        await tester.pumpWidget(
          MaterialApp(home: SurveyScreen(controller: controller)),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Place beacon'));
        await tester.pump();
        await tester.ensureVisible(find.byType(FloorMap));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(FloorMap));
        await tester.pumpAndSettle();
        expect(controller.beacons[0].position, isNotNull);
        expect(controller.position, isNull);
        await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'B2'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ChoiceChip, 'B2'));
        await tester.pump();
        await tester.tap(find.text('Place beacon'));
        await tester.pump();
        await tester.ensureVisible(find.byType(FloorMap));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(FloorMap));
        await tester.pumpAndSettle();
        expect(controller.beacons[1].position, isNotNull);
        await tester.tap(find.byType(FloorMap));
        await tester.pump();
        expect(controller.position, isNotNull);

        await tester.ensureVisible(find.text('Logs'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Logs'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Start logging'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Start logging'));
        await tester.pumpAndSettle();
        scanner.emit('a', -79);
        scanner.emit('b', -84);
        scanner.emit('other', -40);
        await tester.pump();
        expect(find.text('2 packets saved'), findsOneWidget);
        await tester.tap(find.text('Stop logging'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Export logs (JSON)'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Export logs (JSON)'));
        await tester.pumpAndSettle();
        final exported =
            jsonDecode(utf8.decode(exporter.bytes!)) as Map<String, dynamic>;
        expect(exported['rawLog'], hasLength(2));
        expect((exported['rawLog'] as List).first['beaconX'], isNotNull);
        expect(exported['applicationId'], 'com.iwayplus.rssi_mapping');

        await tester.ensureVisible(find.text('Display'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Display'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Adjust RSSI range'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).first, '-85');
        await tester.enterText(find.byType(TextField).last, '-90');
        await tester.tap(find.text('Apply'));
        await tester.pump();
        expect(
          find.textContaining('strong must be at least 5 dB'),
          findsOneWidget,
        );
        await tester.enterText(find.byType(TextField).last, '-65');
        await tester.tap(find.text('Apply'));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 350));
        expect(controller.strongThreshold, -65);
        expect(controller.weakThreshold, -85);

        await tester.ensureVisible(find.text('Survey'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Survey'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byType(DropdownButton<int>));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(DropdownButton<int>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('30 seconds').last);
        await tester.pumpAndSettle();
        expect(controller.captureSeconds, 30);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      } finally {
        controller.dispose();
      }
    },
  );
}
