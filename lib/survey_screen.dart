import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'ble_scanner.dart';
import 'floor_map.dart';
import 'main.dart';
import 'models.dart';
import 'survey_controller.dart';

class SurveyScreen extends StatefulWidget {
  const SurveyScreen({super.key, this.controller});
  final SurveyController? controller;
  @override
  State<SurveyScreen> createState() => _SurveyScreenState();
}

class _SurveyScreenState extends State<SurveyScreen>
    with WidgetsBindingObserver {
  late final SurveyController survey;
  final transform = TransformationController();
  final inspectorAnchor = GlobalKey();
  bool exporting = false, importing = false;
  bool placingBeacon = false;
  int inspectorTab = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    survey = widget.controller ?? SurveyController();
    survey.load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) survey.suspendScan();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.controller == null) survey.dispose();
    transform.dispose();
    super.dispose();
  }

  void toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void openLogs() {
    setState(() => inspectorTab = 1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = inspectorAnchor.currentContext;
      if (mounted && target != null) {
        Scrollable.ensureVisible(
          target,
          alignment: 0,
          duration: const Duration(milliseconds: 250),
        );
      }
    });
  }

  Future<void> mapTap(Offset value) async {
    if (!placingBeacon) {
      survey.selectPosition(value);
      return;
    }
    if (survey.capturing || survey.logging) return;
    final index = survey.selectedBeacon;
    final beacon = survey.beacons[index];
    if (beacon.position != null &&
        beacon.position != value &&
        survey.samples.any(
          (s) =>
              s.beaconSerial == beacon.serial &&
              s.placementId == beacon.placementId,
        )) {
      if (!await confirm(
        'Move beacon B${index + 1}?',
        'Moving the beacon starts a fresh heatmap for this placement. Earlier readings and their original reference remain in your export.',
      )) {
        return;
      }
    }
    await survey.setBeaconPosition(index, value);
    if (mounted) {
      setState(() => placingBeacon = false);
      toast(
        'Beacon B${index + 1} reference placed. Now mark your own position.',
      );
    }
  }

  Future<bool> confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> importFloor({bool restore = false}) async {
    importing = true;
    setState(() {});
    try {
      Uint8List? bytes;
      var name = 'Office · supplied plan';
      var ratio = 967 / 1600;
      if (!restore) {
        final file = await FilePicker.pickFile(
          type: FileType.custom,
          allowedExtensions: ['png', 'jpg', 'jpeg', 'webp'],
        );
        if (file == null) return;
        if ((await file.length() ?? 0) > 10 * 1024 * 1024) {
          throw StateError('Choose an image under 10 MB.');
        }
        bytes = await file.readAsBytes();
        if (bytes.length > 10 * 1024 * 1024) {
          throw StateError('Choose an image under 10 MB.');
        }
        final codec = await ui.instantiateImageCodec(bytes);
        try {
          final frame = await codec.getNextFrame();
          ratio = frame.image.width / frame.image.height;
          final pixels = frame.image.width * frame.image.height;
          frame.image.dispose();
          if (pixels > 25000000) {
            throw StateError(
              'Choose a plan with fewer than 25 million pixels.',
            );
          }
        } finally {
          codec.dispose();
        }
        name = file.name;
      }
      if (!mounted) return;
      if (survey.samples.isNotEmpty &&
          !await confirm(
            'Replace this floor plan?',
            'This starts a new survey and removes samples, beacon markers, and raw logs from the current plan. Export your survey first if you need a backup.',
          )) {
        return;
      }
      await survey.replaceFloor(bytes, name, ratio);
      transform.value = Matrix4.identity();
      toast('Floor plan ready. Tap to mark your position.');
    } catch (error) {
      toast('Could not open floor plan: $error');
    } finally {
      if (mounted) setState(() => importing = false);
    }
  }

  Future<void> exportSurvey() async {
    if (survey.capturing) return;
    exporting = true;
    setState(() {});
    try {
      final bytes = Uint8List.fromList(
        utf8.encode(
          const JsonEncoder.withIndent('  ').convert(survey.exportData()),
        ),
      );
      final path = await FilePicker.saveFile(
        mimeType: 'application/json',
        dialogTitle: 'Export survey',
        fileName: 'signal-atlas-${DateTime.now().millisecondsSinceEpoch}.json',
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: bytes,
      );
      if (path != null) {
        toast(
          'Exported survey, raw RSSI packets, filter decisions, and capture diagnostics.',
        );
      }
    } catch (error) {
      toast('Export failed: $error');
    } finally {
      if (mounted) setState(() => exporting = false);
    }
  }

  Future<void> editThresholds() async {
    final weak = TextEditingController(
      text: survey.weakThreshold.toStringAsFixed(0),
    );
    final strong = TextEditingController(
      text: survey.strongThreshold.toStringAsFixed(0),
    );
    var error = '';
    final values = await showDialog<List<double>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Heatmap range'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Starting range: −90 to −70 dBm. Use the same range for both beacons to compare coverage. Raw measurements are never clipped.',
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: weak,
                  keyboardType: const TextInputType.numberWithOptions(
                    signed: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Weak / faint blue (dBm)',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: strong,
                  keyboardType: const TextInputType.numberWithOptions(
                    signed: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Strong / bright red (dBm)',
                  ),
                ),
                if (error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      error,
                      style: const TextStyle(color: Colors.deepOrange),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final w = double.tryParse(weak.text.trim()),
                    s = double.tryParse(strong.text.trim());
                if (w == null ||
                    s == null ||
                    !w.isFinite ||
                    !s.isFinite ||
                    w < -127 ||
                    s > -1 ||
                    s - w < 5) {
                  update(
                    () => error = 'Use −127 to −1 dBm; strong must be at least 5 dB above weak.',
                  );
                  return;
                }
                Navigator.pop(context, [w, s]);
              },
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
    // Wait until the dialog's dismissal animation releases the fields.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    weak.dispose();
    strong.dispose();
    if (values != null && mounted) {
      await survey.setThresholds(values[0], values[1]);
    }
  }

  Future<void> recordManual() async {
    final inputs = [TextEditingController(), TextEditingController()];
    var error = '';
    final values = await showDialog<Map<int, int>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Record RSSI at this point'),
          content: SizedBox(
            width: 340,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Enter one or both readings in dBm. Leave an unmeasured beacon blank.',
                ),
                const SizedBox(height: 20),
                for (var i = 0; i < 2; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: TextField(
                      controller: inputs[i],
                      autofocus: i == 0,
                      keyboardType: const TextInputType.numberWithOptions(
                        signed: true,
                      ),
                      decoration: InputDecoration(
                        labelText: survey.beacons[i].serial,
                        hintText: '-65',
                        suffixText: 'dBm',
                      ),
                    ),
                  ),
                if (error.isNotEmpty)
                  Text(error, style: const TextStyle(color: Colors.red)),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final result = <int, int>{};
                for (var i = 0; i < 2; i++) {
                  final text = inputs[i].text.trim();
                  if (text.isEmpty) continue;
                  final value = int.tryParse(text);
                  if (value == null || value < -127 || value >= 0) {
                    update(() => error = 'Use a whole number from -127 to -1.');
                    return;
                  }
                  result[i] = value;
                }
                if (result.isEmpty) {
                  update(() => error = 'Enter at least one reading.');
                  return;
                }
                Navigator.pop(context, result);
              },
              child: const Text('Save readings'),
            ),
          ],
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    for (final input in inputs) {
      input.dispose();
    }
    if (values != null && mounted) {
      await survey.addManual(values);
      toast('Manual readings saved at your marked position.');
    }
  }

  Future<void> discovery() async {
    survey.setShowAllDevices(false);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .78,
        child: AnimatedBuilder(
          animation: survey,
          builder: (context, _) => Padding(
            padding: const EdgeInsets.fromLTRB(22, 8, 22, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Discover your beacons',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Only your test beacons are shown by default. Confirm each physical label once to save its full device ID.',
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('Only my beacons'),
                      selected: !survey.showAllDevices,
                      onSelected: (_) => survey.setShowAllDevices(false),
                    ),
                    ChoiceChip(
                      label: const Text('Show all devices'),
                      selected: survey.showAllDevices,
                      onSelected: (_) => survey.setShowAllDevices(true),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  survey.showAllDevices
                      ? 'Unfiltered discovery. Only assigned devices can be captured.'
                      : survey.beacons.every((b) => b.deviceId != null)
                      ? 'Filtering by your two saved full device IDs.'
                      : 'Looking for 00:4B:4F / 00:01:A2 address endings or the printed serial names. Confirm matches before assigning.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: survey.starting ? null : survey.toggleScan,
                  icon: Icon(
                    survey.scanning
                        ? Icons.stop_rounded
                        : Icons.bluetooth_searching,
                  ),
                  label: Text(
                    survey.starting
                        ? 'Starting…'
                        : survey.scanning
                        ? 'Stop scan'
                        : 'Start scan',
                  ),
                ),
                if (survey.message != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      survey.message!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                const SizedBox(height: 12),
                Expanded(
                  child: survey.discoveryDevices.isEmpty
                      ? Center(
                          child: Text(
                            !survey.scanning
                                ? 'Start scanning with Bluetooth and Location enabled.'
                                : survey.showAllDevices
                                ? 'No devices yet. Check beacon power and permissions.'
                                : 'No matching test beacons yet.\nIf the printed IDs are not address endings, use Show all devices once to assign them.',
                            textAlign: TextAlign.center,
                          ),
                        )
                      : ListView(
                          children: survey.discoveryDevices
                              .map(deviceTile)
                              .toList(),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    // Do not keep accepting arbitrary devices after the discovery sheet closes.
    if (mounted) survey.setShowAllDevices(false);
  }

  Widget deviceTile(BeaconReading device) {
    final fresh = survey.isFresh(device);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    device.name.isEmpty ? 'Unnamed BLE device' : device.name,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                Text(fresh ? '${device.rssi} dBm' : 'Stale'),
              ],
            ),
            SelectableText(
              device.deviceId,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            if (device.manufacturerHex.isNotEmpty)
              Text(
                'Manufacturer: ${device.manufacturerHex}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (device.services.isNotEmpty)
              Text(
                'Services: ${device.services}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: List.generate(2, (index) {
                final beacon = survey.beacons[index];
                final bound =
                    beacon.deviceId != null &&
                    sameDeviceId(beacon.deviceId!, device.deviceId);
                final assignedElsewhere = survey.beacons.asMap().entries.any(
                  (entry) =>
                      entry.key != index &&
                      entry.value.deviceId != null &&
                      sameDeviceId(entry.value.deviceId!, device.deviceId),
                );
                final candidate =
                    survey.showAllDevices ||
                    beacon.matchesDiscovery(device.deviceId, device.name);
                return OutlinedButton(
                  onPressed: !fresh || bound || assignedElsewhere || !candidate
                      ? null
                      : () async {
                          try {
                            await survey.bindDevice(index, device.deviceId);
                            toast(
                              'Assigned to ${survey.beacons[index].serial}.',
                            );
                          } catch (error) {
                            toast('$error');
                          }
                        },
                  child: Text(
                    '${bound ? 'Assigned' : 'Assign'} ${survey.beacons[index].labelId}',
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: survey,
    builder: (context, _) {
      if (!survey.loaded) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      return LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 1000;
          final padding = wide ? 28.0 : 16.0;
          return Scaffold(
            body: SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(padding, 20, padding, 14),
                    child: header(wide),
                  ),
                  Expanded(
                    child: wide
                        ? Padding(
                            padding: EdgeInsets.fromLTRB(
                              padding,
                              0,
                              padding,
                              24,
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(child: mapCard()),
                                const SizedBox(width: 20),
                                SizedBox(
                                  width: 330,
                                  child: SingleChildScrollView(
                                    child: inspector(),
                                  ),
                                ),
                              ],
                            ),
                          )
                        : SingleChildScrollView(
                            padding: EdgeInsets.symmetric(horizontal: padding),
                            child: Column(
                              children: [
                                SizedBox(height: 730, child: mapCard()),
                                const SizedBox(height: 16),
                                inspector(),
                                const SizedBox(height: 24),
                              ],
                            ),
                          ),
                  ),
                  if (!wide)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                      child: Row(
                        children: [
                          Expanded(child: captureButton()),
                          const SizedBox(width: 8),
                          IconButton.filledTonal(
                            tooltip: 'Open logs & export',
                            onPressed: openLogs,
                            icon: const Icon(Icons.receipt_long_outlined),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      );
    },
  );

  Widget header(bool wide) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: accent,
              borderRadius: BorderRadius.circular(13),
            ),
            child: const Icon(Icons.radar, color: Colors.white),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'iWAY+  /  RSSI MAPPING',
                  style: TextStyle(
                    fontSize: 12,
                    letterSpacing: 2,
                    fontWeight: FontWeight.w800,
                    color: accent,
                  ),
                ),
                Text(
                  'Floor-plan survey',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    color: ink,
                    letterSpacing: -.6,
                  ),
                ),
              ],
            ),
          ),
          if (wide) statusPill(Icons.save_outlined, 'Stored on this device'),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Export survey as JSON',
            onPressed: survey.capturing || exporting ? null : exportSurvey,
            icon: exporting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.file_download_outlined),
          ),
          IconButton(
            tooltip: 'How the survey works',
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('A signal map, one point at a time'),
                content: const Text(
                  '1. Choose Live BLE and discover & assign the two beacons.\n2. Select B1 or B2, choose Place beacon, and tap its physical location. Repeat for the other beacon.\n3. Choose Mark my position and tap where you stand.\n4. Capture while staying still, then move, mark, and repeat.\n5. Open Logs, stop logging, and export JSON to share your measurements.\n\nCaptures last 15 seconds by default (up to 30). Each beacon needs 10 retained readings after median/MAD spike filtering. Every raw reading and filtering decision is logged, including skipped captures. Start logging also records between captures.\n\nEach beacon placement has a separate heatmap based on measured receiver positions. Moving a marked beacon starts a new map. Older measurements may lack a beacon reference. Unmeasured space stays transparent; walls are not modeled.\n\nLive BLE is Android-only. Manual RSSI and Demo work in browsers; demo measurements are never exported.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Got it'),
                  ),
                ],
              ),
            ),
            icon: const Icon(Icons.help_outline),
          ),
        ],
      ),
      const SizedBox(height: 18),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final mode in SampleSource.values)
            ChoiceChip(
              avatar: Icon(
                mode == SampleSource.live
                    ? Icons.bluetooth
                    : mode == SampleSource.manual
                    ? Icons.edit_outlined
                    : Icons.auto_awesome_outlined,
                size: 17,
              ),
              label: Text(
                mode == SampleSource.manual
                    ? 'Manual RSSI'
                    : mode == SampleSource.live
                    ? 'Live BLE'
                    : 'Demo',
              ),
              selected: survey.source == mode,
              showCheckmark: false,
              onSelected: survey.capturing
                  ? null
                  : (_) {
                      setState(() => placingBeacon = false);
                      survey.setSource(mode);
                    },
            ),
          if (survey.source == SampleSource.demo)
            statusPill(Icons.science_outlined, 'Simulated data', amber: true),
          if (survey.source == SampleSource.live)
            statusPill(
              Icons.circle,
              survey.scanning ? 'Scanning' : 'Scan paused',
              amber: !survey.scanning,
            ),
          if (survey.logging)
            statusPill(Icons.fiber_manual_record, 'Recording raw RSSI'),
        ],
      ),
      if (survey.message != null)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Row(
            children: [
              const Icon(
                Icons.info_outline,
                color: Colors.deepOrange,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  survey.message!,
                  style: const TextStyle(
                    color: Colors.deepOrange,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
    ],
  );

  Widget statusPill(IconData icon, String label, {bool amber = false}) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: amber ? const Color(0xFFFFF0D5) : const Color(0xFFE7F0E8),
          borderRadius: BorderRadius.circular(30),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 13,
              color: amber ? const Color(0xFF99641D) : accent,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: amber ? const Color(0xFF99641D) : accent,
              ),
            ),
          ],
        ),
      );

  Widget mapCard() => Card(
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 12, 10),
          child: Row(
            children: [
              const Icon(Icons.layers_outlined, size: 20, color: accent),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      survey.floorName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const Text(
                      'Tap to mark where you are · pinch to zoom',
                      style: TextStyle(fontSize: 11, color: muted),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Reset zoom',
                onPressed: () => transform.value = Matrix4.identity(),
                icon: const Icon(Icons.fit_screen, size: 21),
              ),
              PopupMenuButton<String>(
                tooltip: 'Floor plan options',
                enabled: !survey.capturing && !survey.logging && !importing,
                icon: const Icon(Icons.more_horiz),
                onSelected: (value) => importFloor(restore: value == 'restore'),
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'import',
                    child: Text('Import floor-plan image'),
                  ),
                  const PopupMenuItem(
                    value: 'restore',
                    child: Text('Use supplied office plan'),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (survey.source != SampleSource.demo)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (var i = 0; i < survey.beacons.length; i++)
                      ChoiceChip(
                        label: Text('B${i + 1}'),
                        showCheckmark: false,
                        avatar: Icon(
                          survey.beacons[i].position == null
                              ? Icons.sensors
                              : Icons.location_on_outlined,
                          size: 16,
                        ),
                        selected: survey.selectedBeacon == i,
                        onSelected: survey.capturing
                            ? null
                            : (_) => survey.selectBeacon(i),
                      ),
                    ChoiceChip(
                      label: const Text('Mark my position'),
                      showCheckmark: false,
                      avatar: const Icon(Icons.my_location, size: 16),
                      selected: !placingBeacon,
                      onSelected: survey.capturing
                          ? null
                          : (_) => setState(() => placingBeacon = false),
                    ),
                    ChoiceChip(
                      label: const Text('Place beacon'),
                      showCheckmark: false,
                      avatar: const Icon(
                        Icons.add_location_alt_outlined,
                        size: 16,
                      ),
                      selected: placingBeacon,
                      onSelected: survey.capturing || survey.logging
                          ? null
                          : (_) => setState(() => placingBeacon = true),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  placingBeacon
                      ? 'Tap where beacon B${survey.selectedBeacon + 1} is physically placed.'
                      : 'Diamond = beacon reference  ·  Target = your position',
                  style: TextStyle(
                    fontSize: 11,
                    color: placingBeacon ? accent : muted,
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: const Color(0xFFF2F4EF),
              borderRadius: BorderRadius.circular(12),
            ),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: FloorMap(
                bytes: survey.floorBytes,
                aspectRatio: survey.aspectRatio,
                samples: survey.visibleSamples,
                position: survey.position,
                onPosition: mapTap,
                opacity: survey.opacity,
                radius: survey.radius,
                showSamples: survey.showSamples,
                showHeatmap: survey.showHeatmap,
                transformationController: transform,
                weakThreshold: survey.weakThreshold,
                strongThreshold: survey.strongThreshold,
                beaconPositions: survey.source == SampleSource.demo
                    ? []
                    : survey.beacons.map((b) => b.position).toList(),
                selectedBeacon: survey.selectedBeacon,
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
          child: Column(
            children: [
              Row(
                children: [
                  const Text(
                    'RSSI',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 11),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Container(
                      height: 7,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        gradient: LinearGradient(
                          colors: List.generate(
                            heatColors.length,
                            (index) => rssiOverlayColor(
                              survey.weakThreshold +
                                  (survey.strongThreshold -
                                          survey.weakThreshold) *
                                      index /
                                      (heatColors.length - 1),
                              maxOpacity: survey.opacity,
                              weak: survey.weakThreshold,
                              strong: survey.strongThreshold,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '${survey.visibleSamples.length} samples',
                    style: const TextStyle(fontSize: 11, color: muted),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Wrap(
                spacing: 24,
                runSpacing: 4,
                children: [
                  Text(
                    '≤ −${survey.weakThreshold.abs().toStringAsFixed(0)} dBm · faint',
                    style: const TextStyle(fontSize: 10, color: muted),
                  ),
                  Text(
                    '≥ −${survey.strongThreshold.abs().toStringAsFixed(0)} dBm · strongest',
                    style: const TextStyle(fontSize: 10, color: muted),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                survey.visibleSamples.isEmpty
                    ? 'Your heatmap will appear as you record points.'
                    : 'Nearby estimates only · walls are not modeled',
                style: const TextStyle(fontSize: 11, color: muted),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget inspector() => Column(
    key: inspectorAnchor,
    children: [
      Container(
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          color: const Color(0xFFE7EEEA),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            for (var i = 0; i < 3; i++)
              Expanded(
                child: TextButton(
                  style: TextButton.styleFrom(
                    backgroundColor: inspectorTab == i
                        ? Colors.white
                        : Colors.transparent,
                    foregroundColor: inspectorTab == i ? ink : muted,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: () => setState(() => inspectorTab = i),
                  child: Text(
                    ['Survey', 'Logs', 'Display'][i],
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      if (inspectorTab == 0) ...[
        section('TEST BEACONS', 'Two signals. Separate maps.', [
          for (var i = 0; i < 2; i++) beaconCard(i),
          if (survey.source == SampleSource.live) ...[
            const SizedBox(height: 6),
            OutlinedButton.icon(
              onPressed:
                  !survey.scanner.supported ||
                      survey.capturing ||
                      survey.logging
                  ? null
                  : discovery,
              icon: const Icon(Icons.bluetooth_searching, size: 18),
              label: const Text('Discover & assign'),
            ),
            if (survey.scanning)
              TextButton.icon(
                onPressed: survey.capturing ? null : survey.toggleScan,
                icon: const Icon(Icons.stop_rounded, size: 18),
                label: const Text('Stop scanning'),
              ),
            if (!survey.scanner.supported)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Live BLE needs an Android phone. Use Manual RSSI or Demo on this device.',
                  style: TextStyle(fontSize: 12, color: muted),
                ),
              ),
          ],
        ]),
        const SizedBox(height: 16),
        section('YOUR POSITION', 'Mark. Measure. Move.', [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: surface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(Icons.my_location, size: 24, color: accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        survey.position == null
                            ? 'No position marked'
                            : 'Position marked',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        survey.position == null
                            ? 'Tap your location on the plan'
                            : 'x ${(survey.position!.dx * 100).toStringAsFixed(1)}%  ·  y ${(survey.position!.dy * 100).toStringAsFixed(1)}%',
                        style: const TextStyle(fontSize: 12, color: muted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (survey.source == SampleSource.live) ...[
            Row(
              children: [
                const Expanded(
                  child: Text('Reading time', style: TextStyle(fontSize: 12)),
                ),
                DropdownButton<int>(
                  value: survey.captureSeconds,
                  items: [10, 15, 20, 30]
                      .map(
                        (v) => DropdownMenuItem(
                          value: v,
                          child: Text(
                            '$v seconds',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: survey.capturing
                      ? null
                      : (v) => survey.setCaptureSeconds(v!),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          captureButton(),
          if (survey.capturing) ...[
            const SizedBox(height: 8),
            for (final beacon in survey.beacons.where(
              (b) => b.deviceId != null,
            ))
              Text(
                '${beacon.labelId}: ${survey.captureReadingCount(beacon)} raw readings',
                style: const TextStyle(fontSize: 11, color: muted),
              ),
          ],
          const SizedBox(height: 8),
          Text(
            survey.source == SampleSource.live
                ? 'Stay still. At least 10 readings must remain after spike filtering; use 30 seconds if needed.'
                : survey.source == SampleSource.demo
                ? 'Explore a simulated survey. Switch modes to record.'
                : 'Enter readings from your debug setup at each point.',
            style: const TextStyle(fontSize: 11, color: muted),
          ),
        ]),
        const SizedBox(height: 16),
      ],
      if (inspectorTab == 1 && survey.source != SampleSource.demo) ...[
        rawLogPanel(),
        const SizedBox(height: 16),
      ],
      if (inspectorTab == 2) ...[
        section('MAP LAYERS', 'See the signal, keep the context.', [
          OutlinedButton.icon(
            onPressed: editThresholds,
            icon: const Icon(Icons.tune, size: 18),
            label: const Text('Adjust RSSI range'),
          ),
          const SizedBox(height: 8),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Heatmap', style: TextStyle(fontSize: 13)),
            value: survey.showHeatmap,
            onChanged: (value) => survey.updateView(heat: value),
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Sample points', style: TextStyle(fontSize: 13)),
            value: survey.showSamples,
            onChanged: (value) => survey.updateView(points: value),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Maximum opacity', style: TextStyle(fontSize: 12)),
              Text(
                '${(survey.opacity * 100).round()}%',
                style: const TextStyle(fontSize: 12, color: muted),
              ),
            ],
          ),
          Slider(
            value: survey.opacity,
            min: .1,
            max: 1,
            onChanged: (value) => survey.updateView(alpha: value),
          ),
          const Text(
            'Weak signals are faint. Strong signals are bright red.',
            style: TextStyle(fontSize: 11, color: muted),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              const Text('Interpolation reach', style: TextStyle(fontSize: 12)),
              Text(
                '${(survey.radius * 100).round()}% of plan',
                style: const TextStyle(fontSize: 12, color: muted),
              ),
            ],
          ),
          Slider(
            value: survey.radius,
            min: .05,
            max: .35,
            onChanged: (value) => survey.updateView(reach: value),
          ),
          const Text(
            'Space beyond this distance from a sample stays transparent.',
            style: TextStyle(fontSize: 11, color: muted),
          ),
        ]),
        const SizedBox(height: 16),
      ],
      if (inspectorTab == 1) ...[
        section('SURVEY LOG', '${survey.pointCount} positions for this beacon', [
          if (survey.visibleSamples.isEmpty)
            const Text(
              'No samples yet. Each reading adds a little more of the picture.',
              style: TextStyle(fontSize: 12, color: muted),
            ),
          for (final sample in survey.visibleSamples.reversed.take(5))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: rssiColor(
                        sample.rssi,
                        weak: survey.weakThreshold,
                        strong: survey.strongThreshold,
                      ),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${(sample.position.dx * 100).round()}%, ${(sample.position.dy * 100).round()}%  ·  ${sample.readingCount} reading${sample.readingCount == 1 ? '' : 's'}'
                      '${sample.rejectedCount == 0 ? '' : ' · ${sample.rejectedCount} excluded'}'
                      '${sample.unstable ? ' · repeat: wide variation' : ''}',
                      style: const TextStyle(fontSize: 12, color: muted),
                    ),
                  ),
                  Text(
                    '${sample.rssi.toStringAsFixed(0)} dBm',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          if (survey.source != SampleSource.demo) ...[
            const Divider(),
            Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  onPressed:
                      survey.capturing ||
                          !survey.samples.any((s) => s.source == survey.source)
                      ? null
                      : survey.undo,
                  icon: const Icon(Icons.undo, size: 16),
                  label: const Text('Undo last point'),
                ),
                TextButton(
                  onPressed:
                      survey.capturing ||
                          !survey.samples.any((s) => s.source == survey.source)
                      ? null
                      : () async {
                          if (await confirm(
                            'Clear ${survey.source.name} samples?',
                            'This removes readings for both beacons in the current mode. Other modes stay saved.',
                          )) {
                            await survey.clear();
                          }
                        },
                  child: const Text(
                    'Clear mode',
                    style: TextStyle(color: Colors.deepOrange),
                  ),
                ),
              ],
            ),
          ],
        ]),
      ],
    ],
  );

  Widget rawLogPanel() => section(
    'RAW RSSI LOG',
    '${survey.rawLog.length} packets saved',
    [
      Text(
        survey.logging
            ? 'Logging both assigned beacons…'
            : 'Captures log every raw reading automatically.',
        style: const TextStyle(fontSize: 12, color: muted),
      ),
      const SizedBox(height: 8),
      const Text(
        'Start logging for a longer diagnostic session. Mark your position, stay still, and capture at each point. Stop logging before exporting.',
        style: TextStyle(fontSize: 11, color: muted),
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed:
            survey.capturing ||
                (!survey.logging &&
                    (survey.source != SampleSource.live || !survey.scanning))
            ? null
            : () async => toast(await survey.toggleLogging()),
        icon: Icon(
          survey.logging
              ? Icons.stop_circle_outlined
              : Icons.fiber_manual_record,
          size: 18,
        ),
        label: Text(survey.logging ? 'Stop logging' : 'Start logging'),
      ),
      OutlinedButton.icon(
        onPressed: survey.capturing || exporting ? null : exportSurvey,
        icon: const Icon(Icons.download_outlined, size: 18),
        label: const Text('Export logs (JSON)'),
      ),
      for (final packet
          in survey.rawLog.reversed
              .where(
                (p) =>
                    p.beaconSerial ==
                    survey.beacons[survey.selectedBeacon].serial,
              )
              .take(4))
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            '${packet.timestamp.toLocal().toIso8601String().substring(11, 19)}  ·  ${packet.rssi} dBm  ·  '
            '${packet.outlier == true
                ? 'spike excluded'
                : packet.usedInSample == true
                ? 'used in point'
                : packet.usedInSample == false
                ? 'capture skipped'
                : 'raw / unfiltered'}',
            style: const TextStyle(fontSize: 11, color: muted),
          ),
        ),
      if (survey.rawLog.isNotEmpty || survey.captureLog.isNotEmpty)
        TextButton(
          onPressed: survey.logging || survey.capturing
              ? null
              : () async {
                  if (await confirm(
                    'Clear raw log?',
                    'Export first if you want to share these packets. This clears raw packets and capture diagnostics. Your saved heatmap points remain.',
                  )) {
                    await survey.clearRawLog();
                  }
                },
          child: const Text(
            'Clear raw log',
            style: TextStyle(color: Colors.deepOrange),
          ),
        ),
    ],
  );

  Widget section(String eyebrow, String title, List<Widget> children) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            eyebrow,
            style: const TextStyle(
              fontSize: 10,
              letterSpacing: 1.5,
              fontWeight: FontWeight.w800,
              color: muted,
            ),
          ),
          const SizedBox(height: 5),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 18),
          ...children,
        ],
      ),
    ),
  );

  Widget beaconCard(int index) {
    final beacon = survey.beacons[index];
    final selected = survey.selectedBeacon == index;
    final reading = survey.readingFor(beacon);
    final fresh = survey.isFresh(reading);
    final subset = survey.source == SampleSource.demo
        ? demoSamples()
        : survey.samples;
    final count = subset
        .where(
          (s) =>
              s.source == survey.source &&
              s.beaconSerial == beacon.serial &&
              (survey.source == SampleSource.demo ||
                  s.placementId == beacon.placementId),
        )
        .length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: survey.capturing ? null : () => survey.selectBeacon(index),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: selected ? const Color(0xFFEEF6EF) : Colors.white,
            border: Border.all(
              color: selected ? accent : const Color(0xFFE1E7DF),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: selected ? accent : surface,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(
                  Icons.sensors,
                  size: 20,
                  color: selected ? Colors.white : muted,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      beacon.serial,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      '${beacon.labelId}  ·  $count samples',
                      style: const TextStyle(fontSize: 10, color: muted),
                    ),
                    if (survey.source != SampleSource.demo)
                      Text(
                        beacon.position == null
                            ? 'Reference not placed'
                            : 'Reference: ${(beacon.position!.dx * 100).round()}%, ${(beacon.position!.dy * 100).round()}%',
                        style: TextStyle(
                          fontSize: 10,
                          color: beacon.position == null ? muted : accent,
                        ),
                      ),
                    if (survey.source == SampleSource.live)
                      Text(
                        beacon.deviceId ?? 'Device not assigned',
                        style: const TextStyle(fontSize: 10, color: muted),
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              if (survey.source == SampleSource.live)
                Text(
                  fresh ? '${reading!.rssi}' : '—',
                  style: TextStyle(
                    fontSize: 18,
                    color: fresh ? accent : muted,
                    fontWeight: FontWeight.w700,
                  ),
                )
              else
                Icon(
                  selected ? Icons.check_circle : Icons.circle_outlined,
                  size: 18,
                  color: selected ? accent : muted,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget captureButton() => SizedBox(
    width: double.infinity,
    child: FilledButton.icon(
      onPressed:
          survey.position == null ||
              placingBeacon ||
              survey.capturing ||
              survey.source == SampleSource.demo ||
              (survey.source == SampleSource.live && !survey.scanning)
          ? null
          : () async {
              if (survey.source == SampleSource.manual) {
                await recordManual();
              } else {
                toast(await survey.capture());
              }
            },
      icon: survey.capturing
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.add_location_alt_outlined, size: 19),
      label: Text(
        survey.capturing
            ? 'Collecting · ${survey.captureRemaining}s left'
            : placingBeacon
            ? 'Place beacon on the plan'
            : survey.source == SampleSource.live
            ? 'Capture RSSI · ${survey.captureSeconds} sec'
            : 'Record RSSI here',
      ),
    ),
  );
}
