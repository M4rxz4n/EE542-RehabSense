/// Runtime permissions for a BLE scan.
///
/// Worth its own file because the failure mode is invisible: without these,
/// `startScan` succeeds, reports no error, and returns an empty list forever.
/// Nothing in the logs says why.
///
/// Android splits at API 31 (Android 12):
///
/// - **API 31+** — `BLUETOOTH_SCAN` and `BLUETOOTH_CONNECT`, both runtime.
///   With `neverForLocation` in the manifest, no location permission is
///   needed, which is the right answer here: the sleeve is on the patient's
///   arm, not somewhere that needs locating.
/// - **API 30 and below** — `BLUETOOTH` and `BLUETOOTH_ADMIN` are install-time,
///   but a scan still demands `ACCESS_FINE_LOCATION` at runtime.
///
/// iOS asks once, on the first BLE call, using the `Info.plist` strings. There
/// is nothing to request here — but the app is terminated outright if those
/// strings are missing, so see `platform/ios-Info.plist.patch.md`.
library;

import 'dart:io' show Platform;

import 'package:permission_handler/permission_handler.dart';

enum BleReadiness {
  ready,
  bluetoothOff,
  permissionDenied,

  /// Denied with "don't ask again". Only Settings can undo it, so the UI must
  /// offer that rather than asking again and appearing to do nothing.
  permissionPermanentlyDenied,
  unsupported,
}

class BlePermissions {
  /// Request whatever this platform and OS version needs.
  ///
  /// Returns what to tell the user, not a bare bool, because the three
  /// failures need three different pieces of advice.
  static Future<BleReadiness> ensure() async {
    if (!Platform.isAndroid && !Platform.isIOS) return BleReadiness.unsupported;

    // iOS prompts itself on first use, driven by Info.plist.
    if (Platform.isIOS) return BleReadiness.ready;

    // permission_handler maps these to the right manifest entries per API
    // level, so asking for all three is correct on every Android version:
    // the ones that do not apply resolve as granted.
    final results = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    final scan = results[Permission.bluetoothScan];
    final connect = results[Permission.bluetoothConnect];
    final location = results[Permission.locationWhenInUse];

    // On API 31+ location is irrelevant thanks to neverForLocation, so a
    // denial there must not block the scan. Below 31 the scan permission
    // resolves as granted and location is what matters. Checking "scan and
    // connect, or location" covers both without version sniffing.
    final modernOk = (scan?.isGranted ?? false) && (connect?.isGranted ?? false);
    final legacyOk = location?.isGranted ?? false;
    if (modernOk || legacyOk) return BleReadiness.ready;

    final permanently = [scan, connect, location]
        .any((s) => s?.isPermanentlyDenied ?? false);
    return permanently
        ? BleReadiness.permissionPermanentlyDenied
        : BleReadiness.permissionDenied;
  }

  static Future<bool> openSettings() => openAppSettings();

  static String advice(BleReadiness r) => switch (r) {
        BleReadiness.ready => '',
        BleReadiness.bluetoothOff =>
          'Turn Bluetooth on, then try connecting again.',
        BleReadiness.permissionDenied =>
          'RehabSense needs Bluetooth permission to find your sleeve.',
        BleReadiness.permissionPermanentlyDenied =>
          'Bluetooth permission was turned off for RehabSense. Open Settings '
              'to allow it.',
        BleReadiness.unsupported =>
          'This platform has no Bluetooth LE support.',
      };
}
