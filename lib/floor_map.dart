import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'package:flutter/material.dart';

import 'models.dart';

class FloorMap extends StatelessWidget {
  const FloorMap({
    super.key,
    required this.bytes,
    required this.aspectRatio,
    required this.samples,
    required this.position,
    required this.onPosition,
    required this.opacity,
    required this.radius,
    required this.showSamples,
    required this.showHeatmap,
    required this.transformationController,
    this.weakThreshold = minHeatRssi,
    this.strongThreshold = maxHeatRssi,
    this.beaconPositions = const [],
    this.selectedBeacon = 0,
  });
  final Uint8List? bytes;
  final double aspectRatio;
  final List<SurveySample> samples;
  final Offset? position;
  final ValueChanged<Offset> onPosition;
  final double opacity, radius;
  final double weakThreshold, strongThreshold;
  final List<Offset?> beaconPositions;
  final int selectedBeacon;
  final bool showSamples, showHeatmap;
  final TransformationController transformationController;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = math.min(
        constraints.maxWidth,
        constraints.maxHeight * aspectRatio,
      );
      final height = width / aspectRatio;
      return Center(
        child: SizedBox(
          width: width,
          height: height,
          child: InteractiveViewer(
            transformationController: transformationController,
            minScale: 1,
            maxScale: 5,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (event) => onPosition(
                Offset(
                  event.localPosition.dx / width,
                  event.localPosition.dy / height,
                ),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  bytes == null
                      ? Image.asset(
                          'assets/floor_plan.png',
                          fit: BoxFit.fill,
                          semanticLabel: 'Office floor plan',
                        )
                      : Image.memory(
                          bytes!,
                          fit: BoxFit.fill,
                          semanticLabel: 'Imported floor plan',
                        ),
                  if (showHeatmap)
                    RepaintBoundary(
                      child: CustomPaint(
                        painter: HeatmapPainter(
                          samples: samples,
                          aspectRatio: aspectRatio,
                          opacity: opacity,
                          radius: radius,
                          weakThreshold: weakThreshold,
                          strongThreshold: strongThreshold,
                          reference: beaconPositions.length > selectedBeacon
                              ? beaconPositions[selectedBeacon]
                              : null,
                        ),
                      ),
                    ),
                  CustomPaint(
                    painter: PointsPainter(
                      samples: showSamples ? samples : [],
                      position: position,
                      weakThreshold: weakThreshold,
                      strongThreshold: strongThreshold,
                      beaconPositions: beaconPositions,
                      selectedBeacon: selectedBeacon,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class HeatmapPainter extends CustomPainter {
  HeatmapPainter({
    required this.samples,
    required this.aspectRatio,
    required this.opacity,
    required this.radius,
    this.weakThreshold = minHeatRssi,
    this.strongThreshold = maxHeatRssi,
    this.reference,
  });
  final List<SurveySample> samples;
  final double aspectRatio, opacity, radius;
  final double weakThreshold, strongThreshold;
  final Offset? reference;
  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty || opacity == 0) return;
    final columns = aspectRatio < 1 ? 55 : 90;
    final rows = (columns / aspectRatio).round().clamp(1, 160);
    final cellWidth = size.width / columns;
    final cellHeight = size.height / rows;
    final paint = Paint()..isAntiAlias = false;
    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < columns; x++) {
        final value = interpolateRssi(
          Offset((x + .5) / columns, (y + .5) / rows),
          samples,
          aspectRatio: aspectRatio,
          radius: radius,
          reference: reference ?? Offset.zero,
        );
        if (value == null) continue;
        paint.color = rssiOverlayColor(
          value,
          maxOpacity: opacity,
          weak: weakThreshold,
          strong: strongThreshold,
        );
        canvas.drawRect(
          Rect.fromLTWH(x * cellWidth, y * cellHeight, cellWidth, cellHeight),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant HeatmapPainter old) =>
      !listEquals(old.samples, samples) ||
      old.opacity != opacity ||
      old.radius != radius ||
      old.weakThreshold != weakThreshold ||
      old.strongThreshold != strongThreshold ||
      old.reference != reference ||
      old.aspectRatio != aspectRatio;
}

class PointsPainter extends CustomPainter {
  PointsPainter({
    required this.samples,
    required this.position,
    this.weakThreshold = minHeatRssi,
    this.strongThreshold = maxHeatRssi,
    this.beaconPositions = const [],
    this.selectedBeacon = 0,
  });
  final List<SurveySample> samples;
  final Offset? position;
  final double weakThreshold, strongThreshold;
  final List<Offset?> beaconPositions;
  final int selectedBeacon;
  @override
  void paint(Canvas canvas, Size size) {
    for (final sample in samples) {
      final point = Offset(
        sample.position.dx * size.width,
        sample.position.dy * size.height,
      );
      canvas.drawCircle(point, 5.5, Paint()..color = Colors.white);
      canvas.drawCircle(
        point,
        3.5,
        Paint()
          ..color = rssiColor(
            sample.rssi,
            weak: weakThreshold,
            strong: strongThreshold,
          ),
      );
      canvas.drawCircle(
        point,
        5.5,
        Paint()
          ..color = Colors.black.withValues(alpha: .18)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
    if (position != null) {
      final point = Offset(
        position!.dx * size.width,
        position!.dy * size.height,
      );
      canvas.drawCircle(
        point,
        14,
        Paint()..color = const Color(0xFF19785F).withValues(alpha: .2),
      );
      canvas.drawCircle(point, 8, Paint()..color = Colors.white);
      canvas.drawCircle(point, 5.5, Paint()..color = const Color(0xFF19785F));
      final line = Paint()
        ..color = const Color(0xFF19785F)
        ..strokeWidth = 1.5;
      canvas.drawLine(
        point - const Offset(20, 0),
        point - const Offset(11, 0),
        line,
      );
      canvas.drawLine(
        point + const Offset(11, 0),
        point + const Offset(20, 0),
        line,
      );
      canvas.drawLine(
        point - const Offset(0, 20),
        point - const Offset(0, 11),
        line,
      );
      canvas.drawLine(
        point + const Offset(0, 11),
        point + const Offset(0, 20),
        line,
      );
    }
    for (var i = 0; i < beaconPositions.length; i++) {
      final anchor = beaconPositions[i];
      if (anchor == null) continue;
      final point = Offset(anchor.dx * size.width, anchor.dy * size.height);
      final color = i == 0 ? const Color(0xFF19785F) : const Color(0xFF6554A4);
      canvas.drawCircle(
        point,
        i == selectedBeacon ? 16 : 12,
        Paint()..color = color.withValues(alpha: .18),
      );
      final diamond = Path()
        ..moveTo(point.dx, point.dy - 8)
        ..lineTo(point.dx + 8, point.dy)
        ..lineTo(point.dx, point.dy + 8)
        ..lineTo(point.dx - 8, point.dy)
        ..close();
      canvas.drawPath(diamond, Paint()..color = color);
      canvas.drawPath(
        diamond,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      final label = TextPainter(
        text: TextSpan(
          text: 'B${i + 1}',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.w800,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final left = (point.dx - label.width / 2 - 6)
          .clamp(0.0, math.max(0.0, size.width - label.width - 12))
          .toDouble();
      final top = (point.dy - 30)
          .clamp(0.0, math.max(0.0, size.height - 20))
          .toDouble();
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left, top, label.width + 12, 18),
          const Radius.circular(5),
        ),
        Paint()..color = color,
      );
      label.paint(canvas, Offset(left + 6, top + 2));
    }
  }

  @override
  bool shouldRepaint(covariant PointsPainter old) =>
      !listEquals(old.samples, samples) ||
      old.position != position ||
      !listEquals(old.beaconPositions, beaconPositions) ||
      old.selectedBeacon != selectedBeacon ||
      old.weakThreshold != weakThreshold ||
      old.strongThreshold != strongThreshold;
}
