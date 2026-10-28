/// BLE transport for the RehabSense sleeve.
///
/// Owns the link and nothing else: it finds the device, negotiates an MTU big
/// enough for the frames, subscribes, decodes, and exposes streams. It holds
/// no session state and draws nothing — see `session/session_state.dart`.
///
/// Two rules this file exists to enforce:
///
/// 1. **Request the MTU before subscribing.** Android starts every connection
///    at 23 bytes. Frames here run to 180, so notifications arrive truncated
///    and the only symptom is a parse error on perfectly good data. iOS
///    negotiates 185 on its own, which is exactly why the firmware caps
///    frames at 180 rather than the 244 a 247-byte MTU would allow.
///
/// 2. **Do almost nothing in the notification handler.** The PRD's note about
///    the Python client applies here: parse and hand off, never render. A
///    20 Hz stream feeding widget rebuilds directly will stall the link
///    behind the frame buffer.
library;

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../protocol/calib.dart';
import '../protocol/commands.dart';
import '../protocol/config_tlv.dart';
import '../protocol/constants.dart';
import '../protocol/enums.dart';
import '../protocol/frames.dart';
import '../protocol/status.dart';
import '../protocol/xfer.dart';
import 'seq_tracker.dart';

enum LinkState {
  idle('Not connected'),
  scanning('Looking for sleeve'),
  connecting('Connecting'),
  negotiating('Negotiating'),
  subscribing('Subscribing'),
  ready('Connected'),
  reconnecting('Reconnecting'),
  failed('Connection failed');

  const LinkState(this.label);
  final String label;

  bool get isLive => this == ready;
  bool get isBusy =>
      this == scanning ||
      this == connecting ||
      this == negotiating ||
      this == subscribing ||
      this == reconnecting;
}

class RehabDevice {
  RehabDevice();

  BluetoothDevice? _device;
  final Map<String, BluetoothCharacteristic> _chars = {};
  final List<StreamSubscription<dynamic>> _subs = [];
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  // ── Outputs ────────────────────────────────────────────────────────────

  final _link = StreamController<LinkState>.broadcast();
  final _features = StreamController<FeatureFrame>.broadcast();
  final _events = StreamController<EventFrame>.broadcast();
  final _status = StreamController<DeviceStatus>.broadcast();
  final _config = StreamController<RuntimeConfig>.broadcast();
  final _calib = StreamController<CalibRecord>.broadcast();
  final _xfer = StreamController<XferInfo>.broadcast();
  final _emg = StreamController<EmgFrame>.broadcast();
  final _imu = StreamController<ImuFrame>.broadcast();
  final _problems = StreamController<String>.broadcast();

  Stream<LinkState> get linkState => _link.stream;
  Stream<FeatureFrame> get features => _features.stream;
  Stream<EventFrame> get events => _events.stream;
  Stream<DeviceStatus> get status => _status.stream;
  Stream<RuntimeConfig> get config => _config.stream;
  Stream<CalibRecord> get calibration => _calib.stream;
  Stream<XferInfo> get transfer => _xfer.stream;

  /// Full-rate EMG. Only produced while [wantRawSamples] is true, because
  /// decoding 80 samples 25 times a second allocates steadily for data the
  /// live view does not use.
  Stream<EmgFrame> get rawEmg => _emg.stream;
  Stream<ImuFrame> get rawImu => _imu.stream;

  /// Decode failures and link complaints, for a debug panel. Never fatal: a
  /// corrupt frame must not end a session.
  Stream<String> get problems => _problems.stream;

  LinkState _state = LinkState.idle;
  LinkState get state => _state;

  /// Set true only for a debugging session. The sequence tracker works from
  /// frame headers either way, so ACK and backfill stay correct with this
  /// off.
  bool wantRawSamples = false;

  final SeqTracker seq = SeqTracker();
  int _lastAcked = -1;

  /// Demo mode: no radio involved. Commands are handed to [onDemoCommand]
  /// instead of being written to a characteristic, and notifications are
  /// pushed in through [injectNotification].
  ///
  /// Worth noting what this does NOT bypass: the synthetic frames go through
  /// the same decoders, the same sequence tracker and the same session state
  /// as real ones. So the demo exercises the wire format end to end rather
  /// than faking the layer above it.
  bool demoMode = false;
  void Function(Uint8List payload)? onDemoCommand;

  int negotiatedMtu = 0;
  String deviceId = '';
  String deviceName = '';

  final RuntimeConfig _cfg = RuntimeConfig();
  RuntimeConfig get currentConfig => _cfg;

  bool _disposed = false;
  bool _wantConnection = false;

  void _setState(LinkState s) {
    if (_state == s) return;
    _state = s;
    if (!_link.isClosed) _link.add(s);
  }

  void _complain(String message) {
    if (!_problems.isClosed) _problems.add(message);
  }

  // ── Connect ────────────────────────────────────────────────────────────

  /// Scan for the sleeve and bring the link all the way up.
  ///
  /// Permissions must already be granted — see `ble/permissions.dart`. A scan
  /// without them returns an empty list and reports nothing, which is the
  /// single most common way to lose an afternoon to this.
  Future<bool> connect({
    Duration scanTimeout = const Duration(seconds: 12),
  }) async {
    _wantConnection = true;

    if (!await FlutterBluePlus.isSupported) {
      _complain('This device has no Bluetooth LE support.');
      _setState(LinkState.failed);
      return false;
    }

    final found = await _scanForSleeve(scanTimeout);
    if (found == null) {
      _complain('No sleeve found. Is it powered on and out of a session with '
          'another host?');
      _setState(LinkState.failed);
      return false;
    }

    return _bringUp(found);
  }

  Future<BluetoothDevice?> _scanForSleeve(Duration timeout) async {
    _setState(LinkState.scanning);
    final completer = Completer<BluetoothDevice?>();

    await _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        // Match on the service UUID, with the name as a fallback: the
        // firmware advertises both, and a crowded 2.4 GHz room makes name
        // matching alone unreliable.
        final byService =
            r.advertisementData.serviceUuids.contains(Guid(kUuidService));
        final byName = r.device.platformName == kDeviceName;
        if (byService || byName) {
          if (!completer.isCompleted) completer.complete(r.device);
          return;
        }
      }
    }, onError: (Object e) {
      _complain('Scan failed: $e');
      if (!completer.isCompleted) completer.complete(null);
    });

    try {
      await FlutterBluePlus.startScan(
        withServices: [Guid(kUuidService)],
        timeout: timeout,
      );
    } catch (e) {
      // Some Android stacks reject a filtered scan. Fall back to an open one
      // and filter in the callback above.
      _complain('Filtered scan rejected ($e); scanning unfiltered.');
      try {
        await FlutterBluePlus.startScan(timeout: timeout);
      } catch (e2) {
        _complain('Scan could not start: $e2');
        return null;
      }
    }

    final device = await completer.future
        .timeout(timeout + const Duration(seconds: 2), onTimeout: () => null);

    await _scanSub?.cancel();
    _scanSub = null;
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {
      // Already stopped by the timeout.
    }
    return device;
  }

  Future<bool> _bringUp(BluetoothDevice device) async {
    _device = device;
    deviceId = device.remoteId.str;
    deviceName = device.platformName.isEmpty ? kDeviceName : device.platformName;

    _setState(LinkState.connecting);
    try {
      await device.connect(timeout: const Duration(seconds: 20));
    } catch (e) {
      _complain('Connect failed: $e');
      _setState(LinkState.failed);
      return false;
    }

    // Watch for the link dropping. Losing it does not change the device
    // state: acquisition, rep detection, grading and every haptic cue carry
    // on, and only the transmit task idles. So reconnect quietly and backfill
    // rather than telling the patient anything alarming.
    await _connSub?.cancel();
    _connSub = device.connectionState.listen((s) {
      if (s == BluetoothConnectionState.disconnected && _wantConnection) {
        _onDropped();
      }
    });

    _setState(LinkState.negotiating);
    await _negotiateMtu(device);

    _setState(LinkState.subscribing);
    if (!await _discoverAndSubscribe(device)) {
      _setState(LinkState.failed);
      return false;
    }

    await _handshake();
    _setState(LinkState.ready);
    return true;
  }

  Future<void> _negotiateMtu(BluetoothDevice device) async {
    // iOS and macOS negotiate on their own and reject an explicit request;
    // only Android needs asking, and only Android starts at 23. On iOS the
    // value is whatever CoreBluetooth settled on — reported as 0 here,
    // meaning "not ours to ask", not "too small".
    if (!Platform.isAndroid) {
      negotiatedMtu = 0;
      return;
    }
    try {
      negotiatedMtu = await device.requestMtu(kDesiredMtu);
    } catch (e) {
      _complain('MTU request failed: $e');
      negotiatedMtu = 0;
      return;
    }

    if (negotiatedMtu > 0 && negotiatedMtu < kMinUsableMtu) {
      // Not fatal — feature frames are 54 bytes and the live view works — but
      // the raw stream cannot fit and will arrive truncated.
      _complain('MTU is $negotiatedMtu, need $kMinUsableMtu for the raw '
          'stream. Features and events are unaffected; raw frames will be '
          'dropped.');
    }
  }

  Future<bool> _discoverAndSubscribe(BluetoothDevice device) async {
    final List<BluetoothService> services;
    try {
      services = await device.discoverServices();
    } catch (e) {
      _complain('Service discovery failed: $e');
      return false;
    }

    BluetoothService? svc;
    for (final s in services) {
      if (s.uuid == Guid(kUuidService)) {
        svc = s;
        break;
      }
    }

    if (svc == null) {
      _complain('Connected, but this device does not expose the RehabSense '
          'service. Wrong device, or firmware older than the frozen '
          'interface.');
      return false;
    }

    _chars.clear();
    for (final c in svc.characteristics) {
      _chars[c.uuid.str.toLowerCase()] = c;
    }

    // Notify-only characteristics. Each gets its own decoder so one bad frame
    // on the raw stream cannot disturb the feature stream the patient view
    // depends on.
    await _subscribe(kUuidEvents, _onEventsValue);
    await _subscribe(kUuidStatus, _onStatusValue);
    await _subscribe(kUuidConfig, _onConfigValue);
    await _subscribe(kUuidXfer, _onXferValue);
    await _subscribe(kUuidRaw, _onRawValue);
    await _subscribe(kUuidBackfill, _onBackfillValue);
    return true;
  }

  BluetoothCharacteristic? _char(String uuid) => _chars[uuid.toLowerCase()];

  Future<void> _subscribe(String uuid, void Function(Uint8List) handler) async {
    final c = _char(uuid);
    if (c == null) {
      _complain('Characteristic $uuid is missing from the service.');
      return;
    }
    try {
      await c.setNotifyValue(true);
    } catch (e) {
      _complain('Could not subscribe to $uuid: $e');
      return;
    }
    _subs.add(c.onValueReceived.listen(
      (v) {
        // Deliberately lean. Parse, hand to a broadcast stream, return.
        try {
          handler(Uint8List.fromList(v));
        } catch (e) {
          _complain('$e');
        }
      },
      onError: (Object e) => _complain('Notification error on $uuid: $e'),
    ));
  }

  /// Everything the device should be told once the link is up.
  Future<void> _handshake() async {
    // The device records the offset and reports it, but never adjusts its own
    // clock: altering the sampling clock would corrupt the spectral analysis
    // the fatigue estimate depends on.
    await _write(Commands.setTimeNow());

    // Read back what the device actually holds rather than assuming the
    // firmware defaults.
    await _write(Commands.getConfig());
    await readCalibration();
    await readStatus();
  }

  void _onDropped() {
    _setState(LinkState.reconnecting);
    _complain('Link lost. The sleeve keeps counting and cueing; reconnecting.');
    unawaited(_reconnectLoop());
  }

  Future<void> _reconnectLoop() async {
    var delay = const Duration(seconds: 1);
    while (_wantConnection && !_disposed) {
      await Future<void>.delayed(delay);
      if (!_wantConnection || _disposed) return;

      final d = _device;
      if (d == null) return;
      try {
        await d.connect(timeout: const Duration(seconds: 15));
        await _negotiateMtu(d);
        if (await _discoverAndSubscribe(d)) {
          await _handshake();
          _setState(LinkState.ready);
          // Recover whatever the stream missed. The device reports
          // explicitly if any of it was genuinely lost.
          await requestOutstandingBackfill();
          return;
        }
      } catch (_) {
        // Expected while the sleeve is out of range or mid-advertise.
      }
      // Back off to 8 s: a patient may have walked out of range for a minute.
      delay = Duration(
          milliseconds: (delay.inMilliseconds * 2).clamp(1000, 8000));
    }
  }

  // ── Decoders ───────────────────────────────────────────────────────────

  void _onEventsValue(Uint8List v) {
    final f = parseFrame(v);
    switch (f) {
      case FeatureFrame():
        if (!_features.isClosed) _features.add(f);
      case EventFrame():
        if (!_events.isClosed) _events.add(f);
      // The events characteristic should carry only these two, but the raw
      // types are legal frames and dropping them silently would hide a
      // firmware change.
      case EmgFrame():
      case ImuFrame():
        _complain('Raw frame arrived on the events characteristic.');
    }
  }

  void _onStatusValue(Uint8List v) {
    final s = DeviceStatus.parse(v);
    if (!_status.isClosed) _status.add(s);
  }

  void _onConfigValue(Uint8List v) {
    _cfg.applyTlv(parseConfigTlv(v));
    if (!_config.isClosed) _config.add(_cfg);
  }

  void _onXferValue(Uint8List v) {
    final x = XferInfo.parse(v);
    if (!_xfer.isClosed) _xfer.add(x);
  }

  /// The hot path: up to 25 EMG frames and 17 IMU frames a second.
  ///
  /// Reads the header to keep sequence accounting honest, and only decodes
  /// the body when something is actually listening for samples.
  void _onRawValue(Uint8List v) {
    if (v.length < kFrameHeaderBytes) return;
    final h = FrameHeader.parse(ByteData.sublistView(v));

    if (h.type == FrameType.emg) {
      final gap = seq.onEmgBatch(h.seq, h.n);
      if (gap != null) {
        // Ask immediately. Backfill is served below the live stream, so the
        // request costs the session nothing and arrives when there is room.
        unawaited(_write(Commands.requestBackfill(gap.from, gap.to)));
      }
      _maybeAck();
    }

    if (!wantRawSamples) return;
    final f = parseFrame(v);
    switch (f) {
      case EmgFrame():
        if (!_emg.isClosed) _emg.add(f);
      case ImuFrame():
        if (!_imu.isClosed) _imu.add(f);
      default:
        break;
    }
  }

  void _onBackfillValue(Uint8List v) {
    if (v.length < kFrameHeaderBytes) return;
    final h = FrameHeader.parse(ByteData.sublistView(v));
    seq.onBackfillBatch(h.seq, h.n);
    _maybeAck();

    if (!wantRawSamples) return;
    final f = parseFrame(v, isBackfill: true);
    if (f is EmgFrame && !_emg.isClosed) _emg.add(f);
  }

  /// Acknowledging frees device storage below the value sent, so this only
  /// ever sends [SeqTracker.highestContiguous] — never a number past a gap.
  void _maybeAck() {
    if (!seq.shouldAck(_lastAcked)) return;
    _lastAcked = seq.highestContiguous;
    unawaited(_write(Commands.ackSeq(_lastAcked)));
  }

  /// Re-request every gap still outstanding. Worth doing after a reconnect.
  Future<void> requestOutstandingBackfill() async {
    for (final g in seq.gaps) {
      await _write(Commands.requestBackfill(g.from, g.to));
    }
  }

  // ── Commands ───────────────────────────────────────────────────────────

  Future<bool> _write(Uint8List payload) async {
    if (demoMode) {
      onDemoCommand?.call(payload);
      return true;
    }
    final c = _char(kUuidControl);
    if (c == null) {
      _complain('Not connected; command dropped.');
      return false;
    }
    try {
      await c.write(payload, withoutResponse: false);
      return true;
    } catch (e) {
      _complain('Command 0x${payload.first.toRadixString(16)} failed: $e');
      return false;
    }
  }

  Future<bool> startSession([int exerciseId = 0]) =>
      _write(Commands.startSession(exerciseId));

  Future<bool> stopSession() => _write(Commands.stopSession());

  Future<bool> startCalibration(CalibPhase phase) =>
      _write(Commands.calibrate(phase));

  Future<bool> abortCalibration() => _write(Commands.abortCalibration());

  Future<bool> requestRecalibration() => _write(Commands.requestRecalibration());

  Future<bool> testHaptic(HapticPattern p) => _write(Commands.hapticTest(p));

  Future<bool> powerOff() => _write(Commands.powerOff());

  /// Brings up the sleeve's SoftAP. Refused while the device is OPERATIONAL —
  /// stop the session first. That refusal is deliberate and not overridable:
  /// one radio, and the live stream wins.
  Future<bool> startTransfer() => _write(Commands.startTransfer());

  Future<bool> stopTransfer() => _write(Commands.stopTransfer());

  /// Push only the tags that changed, then read back.
  ///
  /// The read-back is not optional. A recognised tag with the wrong length is
  /// rejected by the firmware, and nothing on the wire says so — comparing
  /// what comes back is the only confirmation a change took effect.
  Future<bool> setConfigTags(List<Uint8List> blocks) async {
    if (blocks.isEmpty) return true;
    final ok = await _write(Commands.setConfigTags(blocks));
    if (!ok) return false;
    return _write(Commands.getConfig());
  }

  Future<bool> setRawStream(bool enabled) =>
      setConfigTags([cfgU8(CfgTag.rawStream, enabled ? 1 : 0)]);

  Future<bool> refreshConfig() => _write(Commands.getConfig());

  // ── Reads ──────────────────────────────────────────────────────────────

  Future<DeviceStatus?> readStatus() async {
    final c = _char(kUuidStatus);
    if (c == null) return null;
    try {
      final s = DeviceStatus.parse(Uint8List.fromList(await c.read()));
      if (!_status.isClosed) _status.add(s);
      return s;
    } catch (e) {
      _complain('Status read failed: $e');
      return null;
    }
  }

  Future<CalibRecord?> readCalibration() async {
    final c = _char(kUuidCalib);
    if (c == null) return null;
    try {
      final r = CalibRecord.parse(Uint8List.fromList(await c.read()));
      if (!_calib.isClosed) _calib.add(r);
      return r;
    } catch (e) {
      _complain('Calibration read failed: $e');
      return null;
    }
  }

  Future<XferInfo?> readTransferInfo() async {
    final c = _char(kUuidXfer);
    if (c == null) return null;
    try {
      final x = XferInfo.parse(Uint8List.fromList(await c.read()));
      if (!_xfer.isClosed) _xfer.add(x);
      return x;
    } catch (e) {
      _complain('Transfer info read failed: $e');
      return null;
    }
  }

  /// Write a whole `calib_record_t`. This is the clinician-override path of
  /// PRD §5.3 — how a supplied normalisation value supersedes a measured one
  /// when a true maximum contraction cannot be elicited.
  ///
  /// It goes to the calibration characteristic, never through SET_CONFIG.
  Future<bool> writeCalibration(CalibRecord record) async {
    final c = _char(kUuidCalib);
    if (c == null) return false;
    try {
      await c.write(record.pack(), withoutResponse: false);
      await readCalibration();
      return true;
    } catch (e) {
      _complain('Calibration write failed: $e');
      return false;
    }
  }

  // ── Demo mode ──────────────────────────────────────────────────────────

  /// Bring the link up without a sleeve. See `sim/demo_driver.dart`.
  void beginDemo({String name = 'RehabSense (demo)'}) {
    demoMode = true;
    deviceId = 'demo';
    deviceName = name;
    // What iOS negotiates on its own, so the Settings tab reads plausibly.
    negotiatedMtu = 247;
    seq.reset();
    _lastAcked = -1;
    _setState(LinkState.ready);
  }

  void endDemo() {
    demoMode = false;
    onDemoCommand = null;
    _setState(LinkState.idle);
  }

  /// Feed a notification into the decode path as though it had arrived over
  /// BLE, routed by characteristic UUID exactly as a real subscription would.
  void injectNotification(String uuid, Uint8List bytes) {
    final u = uuid.toLowerCase();
    try {
      if (u == kUuidEvents.toLowerCase()) {
        _onEventsValue(bytes);
      } else if (u == kUuidStatus.toLowerCase()) {
        _onStatusValue(bytes);
      } else if (u == kUuidConfig.toLowerCase()) {
        _onConfigValue(bytes);
      } else if (u == kUuidCalib.toLowerCase()) {
        if (!_calib.isClosed) _calib.add(CalibRecord.parse(bytes));
      } else if (u == kUuidXfer.toLowerCase()) {
        _onXferValue(bytes);
      } else if (u == kUuidRaw.toLowerCase()) {
        _onRawValue(bytes);
      } else if (u == kUuidBackfill.toLowerCase()) {
        _onBackfillValue(bytes);
      } else {
        _complain('Injected a frame for an unknown characteristic $uuid.');
      }
    } catch (e) {
      _complain('$e');
    }
  }

  // ── Teardown ───────────────────────────────────────────────────────────

  Future<void> disconnect() async {
    _wantConnection = false;
    await _connSub?.cancel();
    _connSub = null;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    try {
      await _device?.disconnect();
    } catch (_) {
      // Already gone.
    }
    _chars.clear();
    _setState(LinkState.idle);
  }

  Future<void> dispose() async {
    _disposed = true;
    await disconnect();
    await _scanSub?.cancel();
    await _link.close();
    await _features.close();
    await _events.close();
    await _status.close();
    await _config.close();
    await _calib.close();
    await _xfer.close();
    await _emg.close();
    await _imu.close();
    await _problems.close();
  }
}
