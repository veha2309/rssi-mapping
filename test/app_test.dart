import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:rssi_mapping/main.dart';
import 'package:rssi_mapping/floor_map.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('phone: mark position, validate RSSI, save, and switch beacon', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const SignalAtlasApp());
    await tester.pumpAndSettle();
    expect(find.text('Floor-plan survey'), findsOneWidget);
    await tester.tap(find.byType(FloorMap));
    await tester.pump();
    await tester.tap(find.text('Record RSSI here').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '5');
    await tester.tap(find.text('Save readings'));
    await tester.pump();
    expect(find.text('Use a whole number from -127 to -1.'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '-90');
    await tester.enterText(find.byType(TextField).last, '-45');
    await tester.tap(find.text('Save readings'));
    await tester.pumpAndSettle();
    expect(find.text('1 samples'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
  testWidgets(
    'desktop: demo creates heatmap; live mode reports Android requirement',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const SignalAtlasApp());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Demo'));
      await tester.pumpAndSettle();
      expect(find.text('Simulated data'), findsOneWidget);
      expect(find.text('9 samples'), findsOneWidget);
      expect(find.text('≤ −90 dBm · faint'), findsOneWidget);
      expect(find.text('≥ −70 dBm · strongest'), findsOneWidget);
      await tester.tap(find.text('Live BLE'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Live BLE needs an Android phone'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
