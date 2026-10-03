import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rssi_mapping/floor_map.dart';

void main() {
  testWidgets('position coordinates follow image geometry after zooming', (
    tester,
  ) async {
    final transform = TransformationController();
    Offset? position;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              height: 500,
              child: FloorMap(
                bytes: null,
                aspectRatio: .6,
                samples: const [],
                position: null,
                onPosition: (value) => position = value,
                opacity: .5,
                radius: .2,
                showSamples: true,
                showHeatmap: true,
                transformationController: transform,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final viewer = find.byType(InteractiveViewer);
    final origin = tester.getTopLeft(viewer);
    await tester.tapAt(origin + const Offset(75, 125));
    await tester.pump();
    expect(position!.dx, closeTo(.25, .001));
    expect(position!.dy, closeTo(.25, .001));
    transform.value = Matrix4.diagonal3Values(2, 2, 1);
    await tester.pump();
    await tester.tapAt(origin + const Offset(150, 250));
    await tester.pump();
    expect(position!.dx, closeTo(.25, .001));
    expect(position!.dy, closeTo(.25, .001));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    transform.dispose();
  });
}
