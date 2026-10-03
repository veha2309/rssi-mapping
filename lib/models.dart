import 'dart:math' as math;

import 'package:flutter/material.dart';

enum SampleSource { manual, live, demo }

class Beacon {
  Beacon({
    required this.serial,
    required this.labelId,
    this.deviceId,
    this.position,
    this.placementId = 'initial',
  });
  final String serial;
  final String labelId;
  String? deviceId;
  Offset? position;
  String placementId;

  /// A saved full ID is authoritative. Printed suffixes/names are only
  /// discovery hints until the user confirms the physical beacon.
  bool matchesDiscovery(String advertisedId, String advertisedName) {
    if (deviceId != null) return sameDeviceId(deviceId!, advertisedId);
    final address = normalizedBluetoothId(advertisedId);
    final suffix = labelId.toUpperCase().replaceAll(RegExp('[:-]'), '');
    if (RegExp(r'^[0-9A-F]{12}$').hasMatch(address) &&
        address.endsWith(suffix)) {
      return true;
    }
    return RegExp(
      '(^|[^A-Z0-9])${RegExp.escape(serial)}'
      r'([^A-Z0-9]|$)',
      caseSensitive: false,
    ).hasMatch(advertisedName);
  }

  Map<String, dynamic> toJson() => {
    'serial': serial,
    'labelId': labelId,
    'deviceId': deviceId,
    'x': position?.dx,
    'y': position?.dy,
    'placementId': placementId,
  };
}

String normalizedBluetoothId(String value) {
  final upper = value.trim().toUpperCase();
  final compact = upper.replaceAll(RegExp('[:-]'), '');
  return RegExp(r'^[0-9A-F]{12}$').hasMatch(compact) ? compact : upper;
}

bool sameDeviceId(String left, String right) =>
    normalizedBluetoothId(left) == normalizedBluetoothId(right);

List<Beacon> testBeacons() => [
  Beacon(serial: 'IW26060986', labelId: '00:4B:4F'),
  Beacon(serial: 'IW25030299', labelId: '00:01:A2'),
];

class SurveySample {
  const SurveySample({
    required this.id,
    required this.position,
    required this.beaconSerial,
    required this.rssi,
    required this.source,
    required this.timestamp,
    this.readingCount = 1,
    this.deviceId,
    this.rejectedCount = 0,
    this.spreadDb,
    this.captureId,
    this.beaconPosition,
    this.placementId = 'initial',
  });
  final String id;
  final Offset position;
  final String beaconSerial;
  final double rssi;
  final SampleSource source;
  final DateTime timestamp;
  final int readingCount;
  final String? deviceId;
  final int rejectedCount;
  final double? spreadDb;
  final String? captureId;
  final Offset? beaconPosition;
  final String placementId;
  bool get unstable => spreadDb != null && spreadDb! > 12;

  Map<String, dynamic> toJson() => {
    'id': id,
    'x': position.dx,
    'y': position.dy,
    'beaconSerial': beaconSerial,
    'rssi': rssi,
    'source': source.name,
    'timestamp': timestamp.toUtc().toIso8601String(),
    'readingCount': readingCount,
    'deviceId': deviceId,
    'rejectedCount': rejectedCount,
    'spreadDb': spreadDb,
    'captureId': captureId,
    'beaconX': beaconPosition?.dx,
    'beaconY': beaconPosition?.dy,
    'placementId': placementId,
    'relativeToBeacon': relativeToBeacon(position, beaconPosition),
  };

  factory SurveySample.fromJson(Map<String, dynamic> json) {
    final x = (json['x'] as num).toDouble();
    final y = (json['y'] as num).toDouble();
    final rssi = (json['rssi'] as num).toDouble();
    if (!x.isFinite ||
        !y.isFinite ||
        x < 0 ||
        x > 1 ||
        y < 0 ||
        y > 1 ||
        !rssi.isFinite ||
        rssi < -127 ||
        rssi >= 0) {
      throw const FormatException('Invalid survey sample');
    }
    return SurveySample(
      id: json['id'] as String,
      position: Offset(x, y),
      beaconSerial: json['beaconSerial'] as String,
      rssi: rssi,
      source: SampleSource.values.byName(json['source'] as String),
      timestamp: DateTime.parse(json['timestamp'] as String),
      readingCount: json['readingCount'] as int,
      deviceId: json['deviceId'] as String?,
      rejectedCount: json['rejectedCount'] as int? ?? 0,
      spreadDb: (json['spreadDb'] as num?)?.toDouble(),
      captureId: json['captureId'] as String?,
      beaconPosition: json['beaconX'] == null
          ? null
          : Offset(
              (json['beaconX'] as num).toDouble(),
              (json['beaconY'] as num).toDouble(),
            ),
      placementId: json['placementId'] as String? ?? 'initial',
    );
  }
}

double median(List<int> values) {
  if (values.isEmpty) throw ArgumentError('No readings');
  final sorted = [...values]..sort();
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid].toDouble()
      : (sorted[mid - 1] + sorted[mid]) / 2;
}

/// Raw packets stay in the log even when excluded from a point's estimate.
class RssiLogEntry {
  RssiLogEntry({
    required this.timestamp,
    required this.beaconSerial,
    required this.deviceId,
    required this.rssi,
    this.position,
    this.captureId,
    this.outlier,
    this.usedInSample,
    this.sessionId,
    this.beaconPosition,
    this.placementId = 'initial',
  });
  final DateTime timestamp;
  final String beaconSerial, deviceId;
  final int rssi;
  final Offset? position;
  final String? captureId;
  final String? sessionId;
  final Offset? beaconPosition;
  final String placementId;
  bool? outlier, usedInSample;
  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toUtc().toIso8601String(),
    'beaconSerial': beaconSerial,
    'deviceId': deviceId,
    'rssi': rssi,
    'x': position?.dx,
    'y': position?.dy,
    'captureId': captureId,
    'outlier': outlier,
    'usedInSample': usedInSample,
    'sessionId': sessionId,
    'beaconX': beaconPosition?.dx,
    'beaconY': beaconPosition?.dy,
    'placementId': placementId,
    'relativeToBeacon': relativeToBeacon(position, beaconPosition),
  };
  factory RssiLogEntry.fromJson(Map<String, dynamic> json) => RssiLogEntry(
    timestamp: DateTime.parse(json['timestamp'] as String),
    beaconSerial: json['beaconSerial'] as String,
    deviceId: json['deviceId'] as String,
    rssi: json['rssi'] as int,
    position: json['x'] == null
        ? null
        : Offset((json['x'] as num).toDouble(), (json['y'] as num).toDouble()),
    captureId: json['captureId'] as String?,
    outlier: json['outlier'] as bool?,
    usedInSample: json['usedInSample'] as bool?,
    sessionId: json['sessionId'] as String?,
    beaconPosition: json['beaconX'] == null
        ? null
        : Offset(
            (json['beaconX'] as num).toDouble(),
            (json['beaconY'] as num).toDouble(),
          ),
    placementId: json['placementId'] as String? ?? 'initial',
  );
}

Map<String, double>? relativeToBeacon(Offset? receiver, Offset? beacon) =>
    receiver == null || beacon == null
    ? null
    : {'dx': receiver.dx - beacon.dx, 'dy': receiver.dy - beacon.dy};

double percentile(List<double> values, double fraction) {
  if (values.isEmpty) throw ArgumentError('No values');
  final sorted = [...values]..sort();
  final index = (sorted.length - 1) * fraction.clamp(0.0, 1.0);
  final lower = index.floor();
  return sorted[lower] +
      (sorted[index.ceil()] - sorted[lower]) * (index - lower);
}

class FilteredReadings {
  FilteredReadings(List<int> readings) {
    if (readings.isEmpty) return;
    final center = median(readings);
    mad = percentile(readings.map((v) => (v - center).abs()).toList(), .5);
    // Modified z-score > 3.5; a 6 dB floor handles zero MAD and quantization.
    cutoffDb = math.max(6, 3.5 * mad! / .6745);
    for (final value in readings) {
      final excluded = (value - center).abs() > cutoffDb!;
      outliers.add(excluded);
      if (!excluded) accepted.add(value);
    }
    if (accepted.isNotEmpty) {
      value = median(accepted);
      final values = accepted.map((v) => v.toDouble()).toList();
      spreadDb = percentile(values, .9) - percentile(values, .1);
    }
  }
  final accepted = <int>[];
  final outliers = <bool>[];
  double? value, mad, cutoffDb, spreadDb;
  int get rejectedCount => outliers.where((v) => v).length;
}

/// Distances are fractions of the longest image edge, respecting aspect ratio.
/// A bounded IDW estimate: unmeasured space outside the radius stays transparent.
double? interpolateRssi(
  Offset point,
  List<SurveySample> samples, {
  required double aspectRatio,
  double radius = .20,
  Offset reference = Offset.zero,
}) {
  var total = 0.0;
  var weights = 0.0;
  final exact = <double>[];
  final sx = aspectRatio > 1 ? 1.0 : aspectRatio;
  final sy = aspectRatio > 1 ? 1 / aspectRatio : 1.0;
  final relativePoint = point - reference;
  for (final sample in samples) {
    final relativeSample = sample.position - reference;
    final dx = (relativePoint.dx - relativeSample.dx) * sx;
    final dy = (relativePoint.dy - relativeSample.dy) * sy;
    final distance = math.sqrt(dx * dx + dy * dy);
    if (distance < .00001) {
      exact.add(sample.rssi);
      continue;
    }
    if (distance >= radius) continue;
    final taper = 1 - distance / radius;
    final weight = taper * taper / (distance * distance);
    total += sample.rssi * weight;
    weights += weight;
  }
  if (exact.isNotEmpty) return exact.reduce((a, b) => a + b) / exact.length;
  return weights == 0 ? null : total / weights;
}

const minHeatRssi = -90.0;
const maxHeatRssi = -70.0;
const minHeatOpacity = .08;
const heatColors = [
  Color(0xFF2563EB),
  Color(0xFF22B8DB),
  Color(0xFF3DC88C),
  Color(0xFFFFCC57),
  Color(0xFFFF0000),
];

double signalStrength(
  double rssi, {
  double weak = minHeatRssi,
  double strong = maxHeatRssi,
}) => ((rssi - weak) / (strong - weak)).clamp(0.0, 1.0);

Color rssiColor(
  double rssi, {
  double weak = minHeatRssi,
  double strong = maxHeatRssi,
}) {
  final scaled = signalStrength(rssi, weak: weak, strong: strong) * 4;
  final index = scaled.floor().clamp(0, 3);
  return Color.lerp(heatColors[index], heatColors[index + 1], scaled - index)!;
}

Color rssiOverlayColor(
  double rssi, {
  double maxOpacity = 1,
  double weak = minHeatRssi,
  double strong = maxHeatRssi,
}) => rssiColor(rssi, weak: weak, strong: strong).withValues(
  alpha:
      (minHeatOpacity +
          (1 - minHeatOpacity) *
              signalStrength(rssi, weak: weak, strong: strong)) *
      maxOpacity.clamp(0.0, 1.0),
);

List<SurveySample> demoSamples() {
  final result = <SurveySample>[];
  const points = [
    Offset(.15, .14),
    Offset(.52, .15),
    Offset(.37, .36),
    Offset(.20, .49),
    Offset(.52, .57),
    Offset(.30, .74),
    Offset(.76, .68),
    Offset(.58, .88),
    Offset(.13, .88),
  ];
  for (var b = 0; b < 2; b++) {
    for (var i = 0; i < points.length; i++) {
      final anchor = b == 0 ? const Offset(.2, .35) : const Offset(.73, .78);
      final distance = (points[i] - anchor).distance;
      result.add(
        SurveySample(
          id: 'demo-$b-$i',
          position: points[i],
          beaconSerial: testBeacons()[b].serial,
          rssi: -43 - distance * 63,
          source: SampleSource.demo,
          timestamp: DateTime.utc(2026),
          readingCount: 8,
        ),
      );
    }
  }
  return result;
}
