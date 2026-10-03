import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ble_scanner.dart';
import 'models.dart';

class SurveyController extends ChangeNotifier {
  SurveyController({Scanner? scanner})
    : scanner = scanner ?? AndroidBleScanner() {
    _readings = this.scanner.readings.listen(
      _onReading,
      onError: (Object error) {
        scanning = false;
        _stopLogging('scan_error');
        this.scanner.stop();
        message = 'Scan stopped: $error';
        notifyListeners();
      },
    );
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (scanning || capturing) notifyListeners();
      if (_logDirty && _clock.tick % 5 == 0) save();
    });
  }
  static const storageKey = 'signal_atlas_survey_v1';
  final Scanner scanner;
  final beacons = testBeacons();
  final samples = <SurveySample>[];
  final _demoSamples = demoSamples();
  final devices = <String, BeaconReading>{};
  final _captureReadings = <String, List<RssiLogEntry>>{};
  final rawLog = <RssiLogEntry>[];
  final captureLog = <Map<String, dynamic>>[];
  final logSessions = <Map<String, dynamic>>[];
  static const logLimit = 20000;
  static const minimumReadings = 10;
  bool logging = false, _logDirty = false, _captureLogFull = false;
  String? _sessionId, _captureId;
  DateTime? _loggingStarted, captureEnds;
  int captureSeconds = 15;
  double weakThreshold = minHeatRssi, strongThreshold = maxHeatRssi;
  late final StreamSubscription<BeaconReading> _readings;
  late final Timer _clock;
  Future<void> _writes = Future.value();
  bool loaded = false, scanning = false, starting = false, capturing = false;
  bool showSamples = true, showHeatmap = true;
  bool showAllDevices = false;
  String? message;
  SampleSource source = SampleSource.manual;
  int selectedBeacon = 0;
  Offset? position;
  double opacity = 1;
  double radius = .20;
  Uint8List? floorBytes;
  String floorName = 'Office · supplied plan';
  double aspectRatio = 967 / 1600;
  DateTime? captureStarted;
  bool _disposed = false;
  int get captureRemaining => captureEnds == null
      ? 0
      : (captureEnds!.difference(DateTime.now()).inMilliseconds / 1000)
            .ceil()
            .clamp(0, 30);
  int captureReadingCount(Beacon beacon) =>
      _captureReadings[normalizedBluetoothId(beacon.deviceId ?? '')]?.length ??
      0;

  List<SurveySample> get visibleSamples =>
      (source == SampleSource.demo ? _demoSamples : samples)
          .where(
            (s) =>
                s.source == source &&
                s.beaconSerial == beacons[selectedBeacon].serial &&
                (source == SampleSource.demo ||
                    s.placementId == beacons[selectedBeacon].placementId),
          )
          .toList();
  bool matchesTestBeacon(BeaconReading reading) => beacons.any(
    (beacon) => beacon.matchesDiscovery(reading.deviceId, reading.name),
  );

  List<BeaconReading> get discoveryDevices =>
      devices.values
          .where((reading) => showAllDevices || matchesTestBeacon(reading))
          .toList()
        ..sort((a, b) => b.rssi.compareTo(a.rssi));

  BeaconReading? readingFor(Beacon beacon) =>
      devices[beacon.deviceId == null
          ? null
          : normalizedBluetoothId(beacon.deviceId!)];

  void setShowAllDevices(bool value) {
    showAllDevices = value;
    if (!value) {
      devices.removeWhere((_, reading) => !matchesTestBeacon(reading));
    }
    notifyListeners();
  }

  bool isFresh(BeaconReading? reading) =>
      scanning &&
      reading != null &&
      DateTime.now().difference(reading.seenAt) < const Duration(seconds: 5);
  int get pointCount => visibleSamples
      .map(
        (s) =>
            '${s.position.dx.toStringAsFixed(4)},${s.position.dy.toStringAsFixed(4)}',
      )
      .toSet()
      .length;

  Future<void> load() async {
    if (loaded) return;
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(storageKey);
      if (raw != null) {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        final restored = (json['samples'] as List)
            .map((s) => SurveySample.fromJson(s as Map<String, dynamic>))
            .toList();
        final ratio = (json['aspectRatio'] as num).toDouble();
        if (!ratio.isFinite || ratio <= 0) {
          throw const FormatException('Invalid floor dimensions');
        }
        final bytes = json['floorBase64'] == null
            ? null
            : base64Decode(json['floorBase64'] as String);
        for (var i = 0; i < beacons.length; i++) {
          final saved = (json['beacons'] as List)[i];
          beacons[i].deviceId = saved['deviceId'] as String?;
          beacons[i].position = saved['x'] == null
              ? null
              : Offset(
                  (saved['x'] as num).toDouble(),
                  (saved['y'] as num).toDouble(),
                );
          beacons[i].placementId = saved['placementId'] as String? ?? 'initial';
        }
        samples.addAll(restored);
        aspectRatio = ratio;
        floorBytes = bytes;
        floorName = json['floorName'] as String;
        final settings = json['settings'] as Map<String, dynamic>?;
        final seconds = settings?['captureSeconds'] as int? ?? 15;
        if ([10, 15, 20, 30].contains(seconds)) captureSeconds = seconds;
        final weak =
            (settings?['weakThreshold'] as num?)?.toDouble() ?? minHeatRssi;
        final strong =
            (settings?['strongThreshold'] as num?)?.toDouble() ?? maxHeatRssi;
        if (_validThresholds(weak, strong)) {
          weakThreshold = weak;
          strongThreshold = strong;
        }
        rawLog.addAll(
          ((json['rawLog'] as List?) ?? []).map(
            (v) => RssiLogEntry.fromJson(v as Map<String, dynamic>),
          ),
        );
        captureLog.addAll(
          ((json['captureLog'] as List?) ?? []).cast<Map<String, dynamic>>(),
        );
        for (final capture in captureLog.where(
          (c) => c['status'] == 'collecting',
        )) {
          final packets = rawLog
              .where(
                (p) =>
                    p.captureId == capture['id'] &&
                    p.beaconSerial == capture['beaconSerial'],
              )
              .toList();
          capture['status'] = 'interrupted_app_restart';
          capture['rawCount'] = packets.length;
          capture['endedAt'] =
              packets.lastOrNull?.timestamp.toUtc().toIso8601String() ??
              capture['startedAt'];
          for (final packet in packets) {
            packet.usedInSample = false;
          }
        }
        logSessions.addAll(
          ((json['logSessions'] as List?) ?? []).cast<Map<String, dynamic>>(),
        );
        // Logging never resumes without the user's action after an app restart.
        for (final session in logSessions.where((s) => s['endedAt'] == null)) {
          session['endedAt'] =
              rawLog
                  .where((p) => p.sessionId == session['id'])
                  .lastOrNull
                  ?.timestamp
                  .toUtc()
                  .toIso8601String() ??
              session['startedAt'];
          session['stopReason'] = 'app_restarted';
        }
      }
    } catch (error) {
      message =
          'Saved survey could not be loaded. Export your current survey before clearing app data. $error';
    }
    if (_disposed) return;
    loaded = true;
    notifyListeners();
  }

  Map<String, dynamic> exportData() => {
    'schemaVersion': 2,
    'applicationId': 'com.iwayplus.rssi_mapping',
    'logSemantics': 'Raw packets from assigned beacons only. Null outlier/usedInSample means unassessed. usedInSample describes the capture result; undo/clear may subsequently remove that point. relativeToBeacon dx/dy are fractions of image width/height, not meters. Older data may have no beacon position.',
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    'settings': {
      'captureSeconds': captureSeconds,
      'minimumAcceptedReadings': minimumReadings,
      'weakThreshold': weakThreshold,
      'strongThreshold': strongThreshold,
      'filter': 'per capture and beacon: abs(rssi - median) > max(6, 3.5 * MAD / 0.6745)',
      'unstableSpreadDb': 12,
    },
    'floorName': floorName,
    'aspectRatio': aspectRatio,
    'coordinateSystem':
        'normalized image coordinates; origin top-left; x/y in [0,1]',
    'floorBase64': floorBytes == null ? null : base64Encode(floorBytes!),
    'bundledFloorAsset': floorBytes == null ? 'assets/floor_plan.png' : null,
    'beacons': beacons.map((b) => b.toJson()).toList(),
    'samples': samples.map((s) => s.toJson()).toList(),
    'rawLog': rawLog.map((p) => p.toJson()).toList(),
    'captureLog': captureLog,
    'logSessions': logSessions,
  };

  Future<void> save() {
    _logDirty = false;
    final payload = jsonEncode(exportData());
    _writes = _writes.then((_) async {
      try {
        final preferences = await SharedPreferences.getInstance();
        if (!await preferences.setString(storageKey, payload)) {
          throw StateError('Storage write failed');
        }
      } catch (error) {
        if (!_disposed) {
          message = 'Could not save survey. Export a backup: $error';
          notifyListeners();
        }
      }
    });
    return _writes;
  }

  void _onReading(BeaconReading reading) {
    if (_disposed || !scanning) return;
    // Ignore unrelated advertisements before storage or per-packet UI updates.
    if (!showAllDevices && !matchesTestBeacon(reading)) return;
    final id = normalizedBluetoothId(reading.deviceId);
    devices[id] = reading;
    final now = DateTime.now();
    final fresh =
        !reading.seenAt.isAfter(now) &&
        now.difference(reading.seenAt) < const Duration(seconds: 5);
    final inCapture =
        capturing &&
        captureStarted != null &&
        !reading.seenAt.isBefore(captureStarted!) &&
        reading.seenAt.isBefore(captureEnds!) &&
        _captureReadings.containsKey(id);
    final inLogging =
        logging &&
        _loggingStarted != null &&
        !reading.seenAt.isBefore(_loggingStarted!);
    if (fresh &&
        (inCapture || inLogging) &&
        reading.rssi >= -127 &&
        reading.rssi < 0) {
      final beacon = beacons
          .where((b) => b.deviceId != null && sameDeviceId(b.deviceId!, id))
          .firstOrNull;
      if (beacon != null) {
        if (rawLog.length >= logLimit) {
          _captureLogFull = capturing;
          _stopLogging('log_full');
          message =
              'Raw log is full ($logLimit packets). Export it, then clear the raw log to continue.';
        } else {
          final packet = RssiLogEntry(
            timestamp: reading.seenAt,
            beaconSerial: beacon.serial,
            deviceId: reading.deviceId,
            rssi: reading.rssi,
            position: position,
            captureId: inCapture ? _captureId : null,
            sessionId: inLogging ? _sessionId : null,
            beaconPosition: beacon.position,
            placementId: beacon.placementId,
          );
          rawLog.add(packet);
          if (inCapture) _captureReadings[id]!.add(packet);
          _logDirty = true;
        }
      }
    }
    notifyListeners();
  }

  Future<void> toggleScan() async {
    if (capturing || starting) return;
    if (scanning) {
      scanning = false;
      _stopLogging('scan_stopped');
      await scanner.stop();
      notifyListeners();
      return;
    }
    starting = true;
    message = null;
    notifyListeners();
    try {
      devices.clear();
      await scanner.start();
      if (_disposed) {
        await scanner.stop();
        return;
      }
      scanning = true;
    } catch (error) {
      message = '$error';
    }
    starting = false;
    if (!_disposed) notifyListeners();
  }

  Future<void> suspendScan() async {
    scanning = false;
    _stopLogging('app_backgrounded');
    await scanner.stop();
    if (!_disposed) notifyListeners();
  }

  void setSource(SampleSource value) {
    if (capturing) return;
    source = value;
    if (value != SampleSource.live && scanning) suspendScan();
    notifyListeners();
  }

  void selectPosition(Offset value) {
    if (capturing) return;
    position = Offset(value.dx.clamp(0, 1), value.dy.clamp(0, 1));
    notifyListeners();
  }

  void selectBeacon(int value) {
    if (!capturing) {
      selectedBeacon = value;
      notifyListeners();
    }
  }

  void updateView({double? alpha, double? reach, bool? points, bool? heat}) {
    opacity = alpha ?? opacity;
    radius = reach ?? radius;
    showSamples = points ?? showSamples;
    showHeatmap = heat ?? showHeatmap;
    notifyListeners();
  }

  static bool _validThresholds(double weak, double strong) =>
      weak.isFinite &&
      strong.isFinite &&
      weak >= -127 &&
      strong <= -1 &&
      strong - weak >= 5;

  Future<void> setThresholds(double weak, double strong) async {
    if (!_validThresholds(weak, strong)) {
      throw ArgumentError(
        'Use -127 to -1 dBm, with strong at least 5 dB above weak.',
      );
    }
    weakThreshold = weak;
    strongThreshold = strong;
    notifyListeners();
    await save();
  }

  Future<void> setCaptureSeconds(int value) async {
    if (capturing || ![10, 15, 20, 30].contains(value)) return;
    captureSeconds = value;
    notifyListeners();
    await save();
  }

  Future<String> toggleLogging() async {
    if (logging) {
      _stopLogging('user_stopped');
      notifyListeners();
      await save();
      return 'Logging stopped. Export logs to share the raw readings.';
    }
    if (!scanning ||
        source != SampleSource.live ||
        !beacons.any((b) => b.deviceId != null)) {
      return 'Start Live BLE scanning and assign your beacons first.';
    }
    if (rawLog.length >= logLimit) {
      return 'Export and clear the full raw log first.';
    }
    _loggingStarted = DateTime.now();
    _sessionId = 'log-${_loggingStarted!.microsecondsSinceEpoch}';
    logSessions.add({
      'id': _sessionId,
      'startedAt': _loggingStarted!.toUtc().toIso8601String(),
      'endedAt': null,
      'stopReason': null,
    });
    logging = true;
    notifyListeners();
    await save();
    return 'Logging assigned beacons. Mark your position before recording stationary readings.';
  }

  void _stopLogging(String reason) {
    if (!logging) return;
    final session = logSessions.lastWhere((s) => s['id'] == _sessionId);
    session['endedAt'] = DateTime.now().toUtc().toIso8601String();
    session['stopReason'] = reason;
    logging = false;
    _sessionId = null;
    _loggingStarted = null;
    save();
  }

  Future<void> clearRawLog() async {
    if (capturing || logging) return;
    rawLog.clear();
    captureLog.clear();
    logSessions.clear();
    notifyListeners();
    await save();
  }

  Future<void> bindDevice(int index, String id) async {
    if (capturing || logging) return;
    if (beacons.asMap().entries.any(
      (entry) =>
          entry.key != index &&
          entry.value.deviceId != null &&
          sameDeviceId(entry.value.deviceId!, id),
    )) {
      throw StateError(
        'This device is already assigned to the other test beacon.',
      );
    }
    beacons[index].deviceId = id;
    if (!showAllDevices) {
      devices.removeWhere((_, reading) => !matchesTestBeacon(reading));
    }
    notifyListeners();
    await save();
  }

  Future<void> setBeaconPosition(int index, Offset value) async {
    if (capturing || logging) return;
    final beacon = beacons[index];
    final fixed = Offset(value.dx.clamp(0, 1), value.dy.clamp(0, 1));
    if (beacon.position == fixed) return;
    if (beacon.position != null) {
      // Moving a transmitter starts a new map; old measurements remain exported.
      beacon.placementId = 'placement-${DateTime.now().microsecondsSinceEpoch}';
    }
    beacon.position = fixed;
    notifyListeners();
    await save();
  }

  Future<void> addManual(Map<int, int> readings) async {
    if (position == null || source != SampleSource.manual || capturing) return;
    if (readings.isEmpty || readings.values.any((v) => v < -127 || v >= 0)) {
      throw ArgumentError('Enter an RSSI between -127 and -1 dBm.');
    }
    final now = DateTime.now();
    for (final entry in readings.entries) {
      samples.add(
        SurveySample(
          id: '${now.microsecondsSinceEpoch}-${entry.key}',
          position: position!,
          beaconSerial: beacons[entry.key].serial,
          rssi: entry.value.toDouble(),
          source: SampleSource.manual,
          timestamp: now,
          beaconPosition: beacons[entry.key].position,
          placementId: beacons[entry.key].placementId,
        ),
      );
    }
    notifyListeners();
    await save();
  }

  Future<String> capture({Duration? duration}) async {
    if (position == null ||
        !scanning ||
        source != SampleSource.live ||
        capturing) {
      return 'Mark your position and start a live scan first.';
    }
    final targets = beacons.where((b) => b.deviceId != null).toList();
    if (targets.isEmpty) {
      return 'Assign a scanned device to a test beacon first.';
    }
    if (targets.any((b) => b.position == null)) {
      return 'Place each assigned beacon on the floor plan before capturing.';
    }
    if (rawLog.length >= logLimit) {
      return 'Export and clear the full raw log first.';
    }
    final window = duration ?? Duration(seconds: captureSeconds);
    final fixedPosition = position!;
    capturing = true;
    captureStarted = DateTime.now();
    captureEnds = captureStarted!.add(window);
    _captureId = 'capture-${captureStarted!.microsecondsSinceEpoch}';
    _captureLogFull = false;
    _captureReadings.clear();
    for (final beacon in targets) {
      _captureReadings[normalizedBluetoothId(beacon.deviceId!)] = [];
      captureLog.add({
        'id': _captureId,
        'beaconSerial': beacon.serial,
        'deviceId': beacon.deviceId,
        'beaconX': beacon.position!.dx,
        'beaconY': beacon.position!.dy,
        'placementId': beacon.placementId,
        'x': fixedPosition.dx,
        'y': fixedPosition.dy,
        'startedAt': captureStarted!.toUtc().toIso8601String(),
        'requestedDurationMs': window.inMilliseconds,
        'status': 'collecting',
      });
    }
    save();
    notifyListeners();
    await Future<void>.delayed(window);
    if (_disposed) return 'Capture cancelled.';
    final now = DateTime.now();
    var count = 0;
    final missing = <String>[];
    final unstable = <String>[];
    var rejected = 0;
    for (final beacon in targets) {
      final readings =
          _captureReadings[normalizedBluetoothId(beacon.deviceId!)]!;
      final filtered = FilteredReadings(readings.map((p) => p.rssi).toList());
      final status = !scanning
          ? 'interrupted'
          : _captureLogFull
          ? 'log_full'
          : filtered.accepted.length < minimumReadings
          ? 'insufficient_readings'
          : 'saved';
      for (var i = 0; i < readings.length; i++) {
        readings[i].outlier = filtered.outliers[i];
        readings[i].usedInSample = status == 'saved' && !filtered.outliers[i];
      }
      captureLog
          .lastWhere(
            (c) => c['id'] == _captureId && c['beaconSerial'] == beacon.serial,
          )
          .addAll({
            'id': _captureId,
            'beaconSerial': beacon.serial,
            'deviceId': beacon.deviceId,
            'beaconX': beacon.position?.dx,
            'beaconY': beacon.position?.dy,
            'placementId': beacon.placementId,
            'x': fixedPosition.dx,
            'y': fixedPosition.dy,
            'startedAt': captureStarted!.toUtc().toIso8601String(),
            'endedAt': now.toUtc().toIso8601String(),
            'requestedDurationMs': window.inMilliseconds,
            'rawCount': readings.length,
            'acceptedCount': filtered.accepted.length,
            'rejectedCount': filtered.rejectedCount,
            'medianRssi': filtered.value,
            'madDb': filtered.mad,
            'cutoffDb': filtered.cutoffDb,
            'spreadDb': filtered.spreadDb,
            'unstable': filtered.spreadDb != null && filtered.spreadDb! > 12,
            'status': status,
          });
      rejected += filtered.rejectedCount;
      if (status != 'saved') {
        missing.add(beacon.labelId);
        continue;
      }
      samples.add(
        SurveySample(
          id: '${now.microsecondsSinceEpoch}-${beacon.serial}',
          position: fixedPosition,
          beaconSerial: beacon.serial,
          rssi: filtered.value!,
          source: SampleSource.live,
          timestamp: now,
          readingCount: filtered.accepted.length,
          rejectedCount: filtered.rejectedCount,
          spreadDb: filtered.spreadDb,
          captureId: _captureId,
          beaconPosition: beacon.position,
          placementId: beacon.placementId,
          deviceId: beacon.deviceId,
        ),
      );
      count++;
      if (filtered.spreadDb! > 12) unstable.add(beacon.labelId);
    }
    capturing = false;
    captureStarted = null;
    captureEnds = null;
    _captureId = null;
    _captureReadings.clear();
    notifyListeners();
    await save();
    return '$count beacon sample${count == 1 ? '' : 's'} saved. $rejected spikes excluded; raw values kept.'
        '${missing.isEmpty ? '' : ' Skipped ${missing.join(', ')}: scan interrupted, log full, or fewer than $minimumReadings retained readings. Try 30 seconds.'}'
        '${unstable.isEmpty ? '' : ' Wide variation: ${unstable.join(', ')}. Stay still and repeat.'}';
  }

  Future<void> undo() async {
    if (capturing || source == SampleSource.demo) return;
    final subset = samples.where((s) => s.source == source).toList();
    if (subset.isEmpty) return;
    final time = subset.last.timestamp;
    samples.removeWhere((s) => s.source == source && s.timestamp == time);
    notifyListeners();
    await save();
  }

  Future<void> clear() async {
    if (capturing || source == SampleSource.demo) return;
    samples.removeWhere((s) => s.source == source);
    notifyListeners();
    await save();
  }

  Future<void> replaceFloor(Uint8List? bytes, String name, double ratio) async {
    if (capturing || logging) return;
    floorBytes = bytes;
    floorName = name;
    aspectRatio = ratio;
    samples.clear();
    rawLog.clear();
    captureLog.clear();
    logSessions.clear();
    for (final beacon in beacons) {
      beacon.position = null;
      beacon.placementId = 'initial';
    }
    position = null;
    if (source == SampleSource.demo) source = SampleSource.manual;
    notifyListeners();
    await save();
  }

  @override
  void dispose() {
    _stopLogging('screen_closed');
    if (_logDirty) save();
    _disposed = true;
    _clock.cancel();
    _readings.cancel();
    scanner.dispose();
    super.dispose();
  }
}
