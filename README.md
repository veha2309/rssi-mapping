# iWAY+ RSSI Mapping

A Flutter app for measuring each test beacon's signal strength across a venue and displaying it as a heatmap over a floor-plan image. Mark each beacon's fixed reference location and the phone's actual position yourself. Android application ID: `com.iwayplus.rssi_mapping`.

This application ID differs from the earlier `com.vedant.rssi_mapping` build. Android treats it as a separate app: export any readings from that installation before switching. Local data is not automatically transferred between package IDs.

## Run

Requires Flutter 3.47 / Dart 3.13 or newer and the Android SDK for phone builds.

```powershell
flutter pub get
flutter devices
flutter run -d <android-device-id>
```

For manual RSSI testing and a simulated preview in a browser:

```powershell
flutter run -d chrome
```

Build the Android debug APK:

```powershell
flutter build apk --debug
```

Output: `build/app/outputs/flutter-apk/app-debug.apk`. This is a development build, not a signed store release.

## Survey your venue

1. The supplied office plan loads by default. Use the map's three-dot menu to import another PNG, JPEG, or WebP image (up to 10 MB / 25 million pixels).
2. Choose **Live BLE**, then **Discover & assign** on an Android phone. Enable Bluetooth and Location and grant Nearby devices and precise-location permissions.
3. **Only my beacons** is selected by default: discovery accepts addresses ending in `00:4B:4F` / `00:01:A2`, or names containing the corresponding printed serial. Identify and confirm the physical beacons, preferably by powering one at a time, then assign each full device ID to its label. Once assigned, that beacon is matched exclusively by its saved full ID. If the printed IDs do not match the broadcasts, use **Show all devices** once to identify and assign them; closing discovery automatically returns to the restricted filter.
4. Select **B1**, choose **Place beacon**, and tap its physical location on the plan. Repeat for **B2**. The diamonds mark transmitter references; the target marks the receiver. Moving an already placed beacon starts a new map for that placement, retaining earlier measurements in the export.
5. Choose **Mark my position**, then tap your actual position. Pinch to zoom for precise marking; all markers stay aligned with the image.
6. Tap **Capture RSSI · 15 sec** and stay still. Each assigned beacon must have a reference marker. The app collects fresh advertisements, filters isolated spikes within that beacon's capture, and saves the median of at least **10 retained readings**. **Survey → Reading time** offers 10, 15, 20, and 30 seconds. Low-count or interrupted captures are skipped but still logged. Wide variation (retained P90–P10 above 12 dB) is flagged for a repeat.
7. Move, mark your position, and repeat throughout the venue. Select B1/B2 to view each map. Keep beacon placements and phone orientation consistent while surveying; include near, far, door, and weak areas. Repeat a few points to measure stability.

The **Survey**, **Logs**, and **Display** tabs keep setup, recording/export, and map settings together.

Only the two assigned test devices contribute to measurements. Unrelated advertisements are ignored before storage and per-advertisement UI updates in the default filtered mode. **Show all devices** temporarily lists other BLE devices to help identify the hardware; their RSSI is never recorded into the survey. Filtering occurs in the app; the phone's Bluetooth radio still scans nearby advertisements. No GATT connection or pairing is needed to receive advertisements.

| Physical label | Printed short ID |
| --- | --- |
| IW26060986 | 00:4B:4F |
| IW25030299 | 00:01:A2 |

The photos do not identify the complete Bluetooth address or advertising protocol. Printed suffix/name matches are discovery candidates, not proof of identity; they never automatically assign a device. Raw manufacturer data and advertised service UUIDs appear in discovery for troubleshooting. If an assigned address changes, use **Show all devices** to reassign it.

## Debug without beacons

Choose **Manual RSSI**, tap a position, then enter a reading for one or both beacons. RSSI input accepts whole numbers from -127 to -1 dBm. Leave a beacon blank when it was not measured. Repeat at several points to build a map.

**Demo** displays clearly labeled simulated readings. Demo, manual, and live maps remain separate; simulated data is never saved or exported as real survey measurements.

## Heatmap behavior

- **-90 dBm and weaker = blue / lowest strength, at 8% opacity by default.**
- **-70 dBm and stronger = bright red / highest strength, at full opacity by default.**
- This **-90 to -70 dBm** range is a provisional display calibration based on the screenshot's five saved values (-84 to -74 dBm), leaving margin on either side. Those point medians cannot establish perfect thresholds or identify individual packet spikes. **Display → Adjust RSSI range** changes both endpoints, with at least a 5 dB gap. Both beacons share the range so their maps are comparable.
- Opacity increases linearly with RSSI between the configured thresholds. The **Maximum opacity** slider scales the whole overlay while preserving relative opacity; its default is 100%.
- Values between those thresholds pass through cyan, green, and yellow. Original RSSI values remain intact in storage and export, including readings outside the color scale.
- Every beacon has its own map based on receiver measurements at marked positions. The colors show that beacon's received signal strength at locations within the venue, not the beacon's physical location or transmit power.
- Measurement coordinates are also recorded relative to that beacon's reference: `dx` and `dy` are fractions of image width and height. The marker alone never creates an assumed red hotspot or a distance-based synthetic RSSI value. New measurements record the exact reference and placement ID. Old measurements without a logged reference remain identifiable in export; the first reference marker does not retroactively invent their missing coordinates.
- The app estimates signal between nearby samples using inverse-distance weighting with a bounded influence radius. Repeated measurements at exactly the same position are averaged for display.
- Distance calculations respect the floor image's aspect ratio. Coordinates are fractions of the image width and height, with the origin at the top-left; they are not meters.
- Unmeasured space outside the interpolation radius stays transparent. The radius slider is a percentage of the longest image edge. Interpolated areas are estimates, not additional measurements.
- Walls and furniture are visible in the supplied image but are not automatically interpreted as radio obstacles. Actual readings capture their effects at sampled locations; interpolation can cross walls between samples.

## Storage and export

The current floor image, exact device assignments, and recorded samples are saved locally with `shared_preferences`. No backend or upload is configured. A storage failure is shown on screen; use export if local storage is full. Large custom images can exceed browser storage quotas even when accepted by the picker.

Every live capture automatically saves its raw packets, including readings excluded from the median and packets from captures with insufficient readings. For longer diagnostics, open **Logs → Start logging** while scanning. This records only the exact devices assigned to the two beacons, even in unfiltered discovery. Mark your position as you move; the coordinate is your annotation, not an automatically tracked position. Packets between captures are unfiltered and do not create heatmap points. Manual entries are exported under `samples`; demo data is never exported.

To share data for calibration:

1. Place both beacon references, then start **Live BLE** scanning.
2. Open **Logs → Start logging**. Mark and capture at several spread-out positions, staying still during captures. Use 30 seconds if there are fewer than 10 retained readings.
3. Open **Logs → Stop logging → Export logs (JSON)**. Save the file on your phone and attach it for analysis. The header download icon exports the same complete data.

Schema 2 JSON contains `samples`, `rawLog`, `captureLog`, `logSessions`, floor metadata, beacon placements, full IDs, and settings. Packet records contain UTC timestamp, receiver coordinates, beacon reference, placement ID, optional capture/session ID, raw RSSI, `outlier`, and `usedInSample`. Null flags mean the packet was not assessed in a capture. `usedInSample` describes the capture result; later undo/clear can remove that point. Capture diagnostics include duration, raw/retained/rejected counts, MAD, cutoff, median, P90–P10 spread, and completion/skip status. Failed and interrupted captures are retained for troubleshooting. The bundled office image is referenced by asset path. JSON import is not implemented.

Filtering uses `abs(RSSI − median) > max(6 dB, 3.5 × MAD / 0.6745)`, independently for each beacon at each stationary capture. The modified z-score criterion follows [NIST's outlier discussion](https://www.itl.nist.gov/div898/handbook/eda/section3/eda35h.htm). The 6 dB floor, 10-reading minimum, 15-second default, and 12 dB spread warning are initial engineering settings to refine using your logs. No values are discarded across different floor positions, and color thresholds never clip recorded RSSI. A -84 dBm point can be a legitimate weak location.

Logs are checkpointed locally every five seconds and saved when a capture completes or logging stops. Force-closing can lose packets since the latest checkpoint; unfinished captures are marked interrupted after restart. Logging stops on backgrounding and does not restart automatically. The log holds up to 20,000 packets; reaching the limit stops raw logging visibly and prevents partial captures from becoming survey points. Export, then clear the raw log to continue. Clearing the raw log preserves heatmap points and beacon markers.

Undo removes the last recording batch in the current mode for both beacons. Clear removes the current mode's samples after confirmation. Replacing the floor plan starts a new survey and clears points, raw logs, and beacon markers after confirmation. Export first to retain a previous floor. Only one current floor survey is stored.

## Platform scope

Live BLE scanning is implemented for Android. Web supports manual measurement, demo, image import, and export. Scanning pauses when the app enters the background; reopen discovery and start scanning again to resume. iOS and background scanning are not implemented in this version.

Android configuration intentionally removes `neverForLocation` from the merged BLE scan permission: Android can filter beacon advertisements when that flag is set. See [Android's Bluetooth permission documentation](https://developer.android.com/develop/connectivity/bluetooth/bt-permissions) and [the BLE plugin documentation](https://pub.dev/packages/flutter_reactive_ble).

## Validation

```powershell
flutter analyze
flutter test
flutter build apk --debug
flutter build web
```

Tests cover configurable color thresholds, strength-dependent opacity, interpolation and aspect ratio, discovery filtering, device isolation, spike filtering including zero MAD, retained-reading counts, raw log export/persistence/limits, interruption/restart, reference positions and placement isolation, floor replacement, zoomed coordinates, and phone/desktop screens.

Real radio performance and these specific iWAY advertisements still require testing on an Android phone beside the beacons.

## Source layout

- `lib/ble_scanner.dart`: Android scanning and permissions; injectable scanner interface for tests.
- `lib/models.dart`: beacon definitions, measurements, statistics, and heatmap interpolation.
- `lib/survey_controller.dart`: capture, local persistence, device assignments, and survey state.
- `lib/floor_map.dart`: zoomable floor image, heatmap, and position markers.
- `lib/survey_screen.dart`: survey UI, manual entry, BLE discovery, floor import, and JSON export.
- `assets/floor_plan.png`: the supplied office floor plan.
