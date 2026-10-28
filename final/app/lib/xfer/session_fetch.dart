/// Post-session bulk download over the sleeve's SoftAP.
///
/// A Dart port of `../python/rehab_fetch.py`, and it keeps that script's two
/// non-obvious behaviours, both of which matter more on a phone than on a
/// laptop:
///
/// - **Resume by Range.** The EMG stream alone is about 4.5 MB. A phone that
///   locks, backgrounds the app or briefly drops the AP should not start over,
///   so every `.bin` endpoint honours `Range` and so does this. A stream
///   already at its expected size is skipped entirely, which makes re-running
///   after a partial failure nearly free.
/// - **A longer local file means a different session.** Appending would splice
///   two recordings together, so the partial file is deleted and the download
///   restarts. Likewise if the server ignores the `Range` header and answers
///   200 instead of 206, the body is the whole file and the only safe reading
///   is to rewrite from zero.
///
/// ## What this cannot do
///
/// It cannot join the Wi-Fi network for you. Android 10+ and iOS both refuse
/// to let an app silently switch networks, and the APIs that come close
/// (`WifiNetworkSuggestion`, `NEHotspotConfiguration`) need entitlements and
/// platform channels that are not worth it before a December demo. So this
/// shows the credentials, waits, and starts as soon as the sleeve becomes
/// reachable.
///
/// Joining the sleeve's AP costs the phone its internet: the SoftAP has no
/// route anywhere. That is expected, and it is why the clinician bridge runs
/// during the set rather than after it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../ble/rehab_device.dart';
import '../protocol/xfer.dart';

enum FetchStage {
  idle(''),
  requesting('Asking the sleeve to start'),
  waitingForAp('Waiting for the sleeve’s Wi-Fi'),
  waitingForJoin('Join the sleeve’s Wi-Fi to continue'),
  manifest('Reading the session manifest'),
  downloading('Downloading'),
  finishing('Confirming and shutting the radio down'),
  done('Done'),
  failed('Failed');

  const FetchStage(this.label);
  final String label;
}

/// The five streams the device serves, as `rehab_fetch.py` names them.
const List<String> kStreams = ['emg', 'imu', 'features', 'events', 'reps'];

/// Large enough that per-read overhead vanishes against a megabyte, small
/// enough that progress moves visibly.
const int kChunkBytes = 64 * 1024;

class SessionFetcher extends ChangeNotifier {
  SessionFetcher(this.device);

  final RehabDevice device;

  FetchStage stage = FetchStage.idle;
  String? message;
  String? savedTo;

  int bytesDone = 0;
  int bytesTotal = 0;

  /// Bytes from streams already finished. Progress during a stream is this
  /// plus what that stream has written, so the bar never jumps backwards
  /// between streams.
  int _base = 0;

  bool get busy =>
      stage != FetchStage.idle &&
      stage != FetchStage.done &&
      stage != FetchStage.failed;

  double? get fraction =>
      bytesTotal > 0 ? (bytesDone / bytesTotal).clamp(0.0, 1.0) : null;

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 6);

  void _set(FetchStage s, [String? msg]) {
    stage = s;
    message = msg;
    notifyListeners();
  }

  /// The whole sequence: ask over BLE, wait for the AP, download, confirm.
  Future<bool> run() async {
    bytesDone = 0;
    bytesTotal = 0;
    savedTo = null;

    _set(FetchStage.requesting);
    if (!await device.startTransfer()) {
      _set(FetchStage.failed, 'Could not send the request over BLE.');
      return false;
    }

    final info = await _awaitReady();
    if (info == null) return false;

    // Reachability is the signal, not a timer: the phone has to be on the
    // sleeve's network, and only the phone can tell us whether it is.
    _set(FetchStage.waitingForJoin,
        'Join "${info.ssid}" with password ${info.password}. '
        'This download starts by itself once connected.');

    if (!await _awaitReachable(info)) {
      _set(FetchStage.failed,
          'Could not reach ${info.baseUrl}. Is the phone joined to '
          '"${info.ssid}"?');
      return false;
    }

    try {
      return await _download(info);
    } catch (e) {
      _set(FetchStage.failed, '$e');
      return false;
    }
  }

  /// Wait for the transfer characteristic to report READY.
  ///
  /// A FAILED state is final and means the device refused — almost always
  /// because a set is still running, or because no session has been sealed.
  /// That is deliberate and not overridable, so there is nothing to retry.
  Future<XferInfo?> _awaitReady({
    Duration timeout = const Duration(seconds: 25),
  }) async {
    _set(FetchStage.waitingForAp);

    final existing = await device.readTransferInfo();
    if (existing != null && existing.ready) return existing;
    if (existing != null && existing.failed) {
      _set(FetchStage.failed,
          'The sleeve refused: either a set is still running, or no session '
          'has been recorded yet.');
      return null;
    }

    try {
      final info = await device.transfer
          .firstWhere((x) => x.ready || x.failed)
          .timeout(timeout);
      if (info.failed) {
        _set(FetchStage.failed,
            'The sleeve refused: either a set is still running, or no '
            'session has been recorded yet.');
        return null;
      }
      return info;
    } on TimeoutException {
      _set(FetchStage.failed,
          'The sleeve did not bring its access point up in time.');
      return null;
    }
  }

  /// Poll the manifest endpoint until the phone can actually reach it.
  Future<bool> _awaitReachable(
    XferInfo info, {
    Duration timeout = const Duration(minutes: 2),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final req = await _http
            .getUrl(Uri.parse('${info.baseUrl}/manifest.json'))
            .timeout(const Duration(seconds: 4));
        final res = await req.close().timeout(const Duration(seconds: 6));
        await res.drain<void>();
        if (res.statusCode == HttpStatus.ok) return true;
      } catch (_) {
        // Not on the network yet. Expected, and the common case for the
        // first several seconds while the user is in Wi-Fi settings.
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    return false;
  }

  Future<bool> _download(XferInfo info) async {
    _set(FetchStage.manifest);

    final manifest = await _getJson('${info.baseUrl}/manifest.json');
    if (manifest == null) {
      _set(FetchStage.failed, 'Could not read the manifest.');
      return false;
    }

    if (manifest['sealed'] != true) {
      _set(FetchStage.failed,
          'The sleeve says this session is not sealed. Stop the set first — '
          'downloading a buffer whose counts are moving produces a file that '
          'is internally inconsistent in ways that are very hard to spot '
          'later.');
      return false;
    }

    final dir = await _sessionDir(manifest);
    savedTo = dir.path;

    await File('${dir.path}/manifest.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(manifest));

    final streams = manifest['streams'];
    if (streams is! Map) {
      _set(FetchStage.failed, 'The manifest has no stream table.');
      return false;
    }

    // Expected sizes up front, so progress is a real fraction rather than a
    // spinner. (count - first) * record_bytes, as rehab_fetch.py computes it.
    final expected = <String, int>{};
    final paths = <String, String>{};
    bytesTotal = 0;
    for (final name in kStreams) {
      final meta = streams[name];
      if (meta is! Map) continue;
      final count = (meta['count'] as num?)?.toInt() ?? 0;
      final first = (meta['first'] as num?)?.toInt() ?? 0;
      final rec = (meta['record_bytes'] as num?)?.toInt() ?? 0;
      final size = (count - first) * rec;
      expected[name] = size < 0 ? 0 : size;
      paths[name] = (meta['path'] as String?) ?? '/$name.bin';
      bytesTotal += expected[name]!;
    }

    if (manifest['gap_occurred'] == true) {
      // Not a download problem, and it must not be mistaken for one: the
      // device is reporting that data was genuinely lost during the session,
      // which no amount of retrying recovers.
      message = 'The sleeve reports a gap in this session — some data was '
          'lost while recording and cannot be recovered.';
    }

    _set(FetchStage.downloading, message);

    bytesDone = 0;
    _base = 0;
    for (final name in kStreams) {
      final path = paths[name];
      if (path == null) continue;
      final dest = File('${dir.path}/${path.split('/').last}');
      final size = await _fetchStream(
        '${info.baseUrl}$path',
        dest,
        expected[name] ?? 0,
      );
      _base += size;
      bytesDone = _base;
      notifyListeners();
    }

    // The calibration record belongs with the session: a score means nothing
    // without the profile it was normalised against. Absent on a device that
    // has never been calibrated, which is not an error here.
    try {
      final n = await _fetchStream(
          '${info.baseUrl}/calib.bin', File('${dir.path}/calib.bin'), 0);
      _base += n;
      bytesDone = _base;
    } catch (_) {
      // Fine. The manifest records whether a profile existed.
    }

    _set(FetchStage.finishing, message);
    await _markComplete(info);
    await device.stopTransfer();

    _set(FetchStage.done,
        'Saved ${(bytesDone / 1048576).toStringAsFixed(2)} MB. '
        '${message ?? ''}'.trim());
    return true;
  }

  /// One stream, resuming if the file is already partly written.
  ///
  /// Returns the file's final size on disk.
  Future<int> _fetchStream(String url, File dest, int expectBytes) async {
    var have = (await dest.exists()) ? await dest.length() : 0;

    // Already complete. Re-running after a partial failure costs nothing for
    // the streams that did land.
    if (expectBytes > 0 && have == expectBytes) return have;

    // Longer than expected means this is a leftover from a DIFFERENT session.
    // Appending would splice two recordings together.
    if (expectBytes > 0 && have > expectBytes) {
      await dest.delete();
      have = 0;
    }

    final req = await _http.getUrl(Uri.parse(url));
    if (have > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
    final res = await req.close();

    if (res.statusCode == 409) {
      await res.drain<void>();
      throw Exception('The sleeve reports the session is still running — '
          'stop the set before downloading.');
    }
    if (res.statusCode != HttpStatus.ok &&
        res.statusCode != HttpStatus.partialContent) {
      await res.drain<void>();
      throw Exception('$url returned ${res.statusCode}');
    }

    // The server ignored the Range header, so the body is the whole file.
    // Rewriting from zero is the only safe reading of that.
    var mode = FileMode.write;
    if (have > 0) {
      if (res.statusCode == HttpStatus.partialContent) {
        mode = FileMode.append;
      } else {
        have = 0;
      }
    }

    final sink = dest.openWrite(mode: mode);
    var written = have;
    try {
      await for (final chunk in res) {
        sink.add(chunk);
        written += chunk.length;
        bytesDone = _base + written;
        // Throttled: a notify per 64 kB chunk would rebuild the progress bar
        // dozens of times a second for no visible benefit.
        if (written % (kChunkBytes * 4) < chunk.length) notifyListeners();
      }
    } finally {
      await sink.flush();
      await sink.close();
    }

    return written;
  }

  Future<Map<String, dynamic>?> _getJson(String url) async {
    try {
      final req = await _http.getUrl(Uri.parse(url));
      final res = await req.close();
      if (res.statusCode != HttpStatus.ok) {
        await res.drain<void>();
        return null;
      }
      final body = await res.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// Tell the device we have everything, so it drops the AP.
  ///
  /// Best effort: the session stays in PSRAM until the next START either way,
  /// so a failure here costs an idle timeout, not the data.
  Future<void> _markComplete(XferInfo info) async {
    try {
      final req = await _http.postUrl(Uri.parse('${info.baseUrl}/complete'));
      req.contentLength = 0;
      final res = await req.close();
      await res.drain<void>();
    } catch (_) {
      // Ignored, deliberately.
    }
  }

  Future<Directory> _sessionDir(Map<String, dynamic> manifest) async {
    final base = await getApplicationDocumentsDirectory();

    // Name it from the device's own start timestamp when that is a plausible
    // wall-clock value — it only is if the host sent SET_TIME, since the
    // device has no clock of its own. Otherwise fall back to now.
    final startUs = (manifest['start_us'] as num?)?.toDouble() ?? 0;
    final when = startUs > 1e15
        ? DateTime.fromMicrosecondsSinceEpoch(startUs.toInt())
        : DateTime.now();

    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${when.year}${two(when.month)}${two(when.day)}'
        '-${two(when.hour)}${two(when.minute)}${two(when.second)}';

    final dir = Directory('${base.path}/sessions/session-$stamp');
    await dir.create(recursive: true);
    return dir;
  }

  @override
  void dispose() {
    _http.close(force: true);
    super.dispose();
  }
}
