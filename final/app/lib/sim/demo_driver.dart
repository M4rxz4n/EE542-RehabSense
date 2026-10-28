/// Demo mode: a synthetic sleeve, for working without hardware.
///
/// This exists because every screen past the connect pane is gated behind a
/// live BLE link, so without a sleeve on the bench there is nothing to look
/// at — which makes UI work impossible for anyone who is not holding the
/// hardware.
///
/// ## It is not a mock of the app
///
/// The driver builds **real wire-format frames** with the same builders the
/// golden tests use, and pushes them through `RehabDevice.injectNotification`,
/// which runs the same decoders, the same sequence tracker and the same
/// session state as a real sleeve. Nothing above the radio is stubbed. So if
/// the padding in `features_t` were wrong, demo mode would show wrong rep
/// counts too — it is a working integration test of the protocol layer as
/// much as a UI aid.
///
/// What it cannot do: prove anything about platform BLE behaviour, connection
/// intervals, permissions, MTU negotiation or throughput. Those are exactly
/// what the PRD says remain phone-side work against real hardware.
///
/// ## The movement model
///
/// A deliberately well-behaved curl, following the firmware's own rep cycle
/// (PRD §5.4): ready → concentric → peak → eccentric → extended hold →
/// counted. The count lands on the RETURN after a confirming hold, because
/// that is when the firmware counts and when the haptic fires.
///
/// Scripted into the set, so the demo shows the interesting cases rather than
/// twenty identical reps:
///
/// - median frequency declining across the set, with the rest cue when it has
///   fallen far enough — the fatigue story
/// - a shoulder-hike rep, flagged and scored down
/// - a passive swing: the angle rises with the biceps quiet, so no rep starts
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../ble/rehab_device.dart';
import '../protocol/calib.dart';
import '../protocol/commands.dart';
import '../protocol/config_tlv.dart';
import '../protocol/constants.dart';
import '../protocol/enums.dart';
import '../protocol/frames.dart';
import '../protocol/status.dart';
import '../protocol/xfer.dart';

enum _Phase { idle, ready, concentric, peak, eccentric, hold }

class DemoDriver {
  DemoDriver(this.device);

  final RehabDevice device;

  Timer? _tick;
  Timer? _status;
  Timer? _calib;

  // Fixed seed: the demo should behave the same every time it is shown, so a
  // rehearsed walkthrough does not develop a surprise on demo day.
  final _rng = math.Random(475);

  // ── Simulated device state ─────────────────────────────────────────────

  _Phase _phase = _Phase.idle;
  double _phaseElapsedMs = 0;
  double _angle = 10.0;
  double _dev = 0.0;
  double _envelope = 0.02;
  int _repCount = 0;
  int _featureSeq = 0;
  int _emgSeq = 0;
  int _tUs = 0;
  bool _sessionRunning = false;

  /// Walks down across the set. The fatigue signal is this falling.
  double _mdf = 96.0;

  int _batteryPct = 88;
  bool _fatigueWarned = false;

  // Per-rep scripting.
  double _repPeak = 0;
  double _repStartUs = 0;
  bool _repShoulder = false;
  bool _repIsPassive = false;
  int _velocityPeaks = 2;

  CalibRecord _calibRecord = CalibRecord(
    timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    emgRestRms: const [0.011],
    emgRestSd: const [0.0028],
    emgMvc: const [0.82],
    mdfBaseline: const [96.0],
    gyroBias: const [0.08, -0.14, 0.21, -0.05, 0.11, -0.19],
    qUpper0: const [0.9239, 0.0, 0.3827, 0.0],
    qFore0: const [1.0, 0.0, 0.0, 0.0],
    flexionAxis: const [0.02, 0.01, 0.999],
    angleMin: 8.0,
    angleMax: 121.5,
  );

  RuntimeConfig get _cfg => device.currentConfig;

  // ── Lifecycle ──────────────────────────────────────────────────────────

  void start() {
    device.beginDemo();
    device.onDemoCommand = _onCommand;

    // The link handshake a real connection performs, so the UI lands in the
    // same state it would with a sleeve attached.
    _emit(kUuidCalib, _calibRecord.pack());
    _emit(kUuidConfig, _cfg.toTlv());
    _pushStatus();

    _status = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_batteryPct > 5 && _rng.nextInt(12) == 0) _batteryPct--;
      _pushStatus();
    });

    // 20 Hz, which is the rate the device transmits features at. Analysis
    // runs at 50 Hz on the device; only the transmitted rate matters here.
    _tick = Timer.periodic(
      const Duration(milliseconds: 1000 ~/ kFeatureTxRateHz),
      (_) => _step(1000 / kFeatureTxRateHz),
    );
  }

  void stop() {
    _tick?.cancel();
    _status?.cancel();
    _calib?.cancel();
    _tick = null;
    _status = null;
    _calib = null;
    device.endDemo();
  }

  void dispose() => stop();

  void _emit(String uuid, Uint8List bytes) =>
      device.injectNotification(uuid, bytes);

  // ── Command handling ───────────────────────────────────────────────────

  void _onCommand(Uint8List payload) {
    if (payload.isEmpty) return;
    switch (payload.first) {
      case Cmd.startSession:
        _sessionRunning = true;
        _repCount = 0;
        _mdf = 96.0;
        _fatigueWarned = false;
        _phase = _Phase.ready;
        _phaseElapsedMs = 0;
        _angle = _cfg.finishAngleDeg;
        _prepareRep();
        _event(RehabEvent.stateChange, [FwState.operational.wire]);
        _pushStatus();

      case Cmd.stopSession:
        _sessionRunning = false;
        _phase = _Phase.idle;
        _envelope = 0.02;
        _dev = 0;
        _event(RehabEvent.stateChange, [FwState.standby.wire]);
        _pushStatus();

      case Cmd.startCalibration:
        final phase = payload.length > 1
            ? CalibPhase.fromWire(payload[1])
            : CalibPhase.all;
        _runCalibration(phase ?? CalibPhase.all);

      case Cmd.abortCalibration:
        _calib?.cancel();
        _calib = null;

      case Cmd.getConfig:
        _emit(kUuidConfig, _cfg.toTlv());

      case Cmd.setConfig:
        // The real device applies the TLV and the host confirms by reading
        // back. RehabDevice has already applied it to its own copy, so
        // echoing the whole config is exactly the confirmation the UI wants.
        _emit(kUuidConfig, _cfg.toTlv());

      case Cmd.hapticTest:
        // No motor to drive. The event gives the UI something to mirror.
        _event(RehabEvent.stateChange, [FwState.operational.wire]);

      case Cmd.startTransfer:
        if (_sessionRunning) {
          // The refusal the firmware actually gives: one radio, and the live
          // stream wins. Worth demonstrating rather than papering over.
          _emit(
            kUuidXfer,
            const XferInfo(
              state: 4, // failed
              clients: 0,
              secondsRemaining: 0,
              ipv4: '0.0.0.0',
              port: 0,
              bytesServed: 0,
              ssid: '',
              password: '',
            ).pack(),
          );
        } else {
          _emit(
            kUuidXfer,
            const XferInfo(
              state: 2, // ready
              clients: 0,
              secondsRemaining: 240,
              ipv4: '192.168.4.1',
              port: 80,
              bytesServed: 0,
              ssid: 'RehabSense-DEMO',
              password: 'demo-only-1234',
            ).pack(),
          );
        }

      case Cmd.stopTransfer:
        _emit(
          kUuidXfer,
          const XferInfo(
            state: 0,
            clients: 0,
            secondsRemaining: 0,
            ipv4: '0.0.0.0',
            port: 0,
            bytesServed: 0,
            ssid: '',
            password: '',
          ).pack(),
        );

      default:
        break;
    }
  }

  void _runCalibration(CalibPhase requested) {
    final steps = requested == CalibPhase.all
        ? CalibPhase.wizardSteps
        : [requested];
    var i = 0;
    _calib?.cancel();
    _calib = Timer.periodic(const Duration(milliseconds: 1400), (t) {
      if (i >= steps.length) {
        t.cancel();
        _emit(kUuidCalib, _calibRecord.pack());
        return;
      }
      _event(RehabEvent.calibPhaseDone, [steps[i].wire]);
      i++;
    });
  }

  // ── The movement ───────────────────────────────────────────────────────

  void _prepareRep() {
    final next = _repCount + 1;
    // Every fifth rep, hike the shoulder. Demo item 3: detected live,
    // flagged, scored down, and named on the display.
    _repShoulder = next % 5 == 0;
    // One passive swing partway in: the angle rises with the biceps quiet,
    // so no rep starts at all. Demo item 4.
    _repIsPassive = next == 4;
    _velocityPeaks = 2 + (_repShoulder ? 2 : 0) + _rng.nextInt(2);
    _repPeak = 0;
  }

  void _step(double dtMs) {
    _tUs += (dtMs * 1000).round();

    if (!_sessionRunning) {
      // Idle: at rest, muscle quiet, small sensor noise so the traces are
      // alive rather than a flat line.
      _angle = _cfg.finishAngleDeg + _noise(0.4);
      _envelope = 0.02 + _noise(0.01).abs();
      _dev = _noise(0.5);
      _pushFeatures(RepState.ready, activation: false);
      return;
    }

    _phaseElapsedMs += dtMs;

    final peakTarget = _cfg.peakAngleDeg;
    final finish = _cfg.finishAngleDeg;

    switch (_phase) {
      case _Phase.idle:
        _phase = _Phase.ready;
        _phaseElapsedMs = 0;

      case _Phase.ready:
        _angle = finish + _noise(0.4);
        _envelope = 0.03 + _noise(0.012).abs();
        _dev = _noise(0.5);
        _pushFeatures(RepState.ready, activation: false);
        if (_phaseElapsedMs > 900) {
          _phase = _Phase.concentric;
          _phaseElapsedMs = 0;
          _repStartUs = _tUs.toDouble();
          if (!_repIsPassive) {
            _event(RehabEvent.repStart, const []);
            _event(RehabEvent.startPosOk, const []);
          }
        }

      case _Phase.concentric:
        // ~1.3 s up, eased so the velocity profile is not a sawtooth.
        const durMs = 1300.0;
        final u = (_phaseElapsedMs / durMs).clamp(0.0, 1.0);
        final eased = 0.5 - 0.5 * math.cos(u * math.pi);
        _angle = finish + (peakTarget + 6 - finish) * eased + _noise(0.7);
        _repPeak = math.max(_repPeak, _angle);

        if (_repIsPassive) {
          // Momentum, not muscle. The envelope stays below activation, which
          // is what makes the firmware refuse to count it.
          _envelope = 0.04 + _noise(0.015).abs();
          _dev = _noise(1.0);
          _pushFeatures(RepState.ready, activation: false);
          if (u >= 1.0) {
            _event(RehabEvent.passiveSwing, const []);
            _phase = _Phase.eccentric;
            _phaseElapsedMs = 0;
          }
          return;
        }

        _envelope = 0.08 + 0.58 * eased + _noise(0.03);
        _dev = _repShoulder ? 26.0 * eased + _noise(1.2) : _noise(1.4);
        _pushFeatures(RepState.concentric, activation: true);

        if (_angle >= peakTarget) {
          _phase = _Phase.peak;
          _phaseElapsedMs = 0;
          if (_repShoulder) {
            _event(RehabEvent.compensationShoulder, const []);
          }
        }

      case _Phase.peak:
        _angle = peakTarget + 6 + _noise(0.8);
        _repPeak = math.max(_repPeak, _angle);
        _envelope = 0.64 + _noise(0.04);
        _dev = _repShoulder ? 26.0 + _noise(1.5) : _noise(1.4);
        _pushFeatures(RepState.peak, activation: true);
        if (_phaseElapsedMs > 260) {
          _phase = _Phase.eccentric;
          _phaseElapsedMs = 0;
        }

      case _Phase.eccentric:
        const durMs = 1450.0;
        final u = (_phaseElapsedMs / durMs).clamp(0.0, 1.0);
        final eased = 0.5 - 0.5 * math.cos(u * math.pi);
        _angle = _repPeak - (_repPeak - finish) * eased + _noise(0.7);
        _envelope = _repIsPassive
            ? 0.04 + _noise(0.015).abs()
            : (0.62 * (1 - eased) + 0.06 + _noise(0.03));
        _dev = _repShoulder ? 26.0 * (1 - eased) + _noise(1.2) : _noise(1.4);
        _pushFeatures(
          _repIsPassive ? RepState.ready : RepState.eccentric,
          activation: !_repIsPassive,
        );
        if (u >= 1.0) {
          if (_repIsPassive) {
            // Never became a rep. Straight back to waiting.
            _repIsPassive = false;
            _prepareRep();
            _phase = _Phase.ready;
          } else {
            _phase = _Phase.hold;
            _event(RehabEvent.holdStart, const []);
          }
          _phaseElapsedMs = 0;
        }

      case _Phase.hold:
        _angle = finish + _noise(0.35);
        _envelope = 0.05 + _noise(0.015).abs();
        _dev = _noise(0.5);
        _pushFeatures(RepState.extendedHold, activation: false);
        // The confirming hold. Its duration is the live-tunable parameter, so
        // changing it in Settings visibly changes the demo's cadence.
        if (_phaseElapsedMs >= _cfg.holdMs) {
          _completeRep();
          _phase = _Phase.ready;
          _phaseElapsedMs = 0;
        }
    }
  }

  void _completeRep() {
    _repCount++;
    _event(RehabEvent.holdComplete, const []);

    final rom = _calibRecord.rom <= 0
        ? 1.0
        : ((_repPeak - _calibRecord.angleMin) / _calibRecord.rom)
            .clamp(0.0, 1.2);
    final tempoS = (_tUs - _repStartUs) / 1e6;
    final smoothness = (1.0 - (_velocityPeaks - 2) * 0.17).clamp(0.0, 1.0);
    final cocon = 0.12 + _rng.nextDouble() * 0.1;
    final steady = 0.6 + _rng.nextDouble() * 0.3;

    // Scored roughly the way grading.c weighs it: range, tempo and
    // smoothness equally, with a deduction for compensation. The real score
    // comes from the device; this only has to be plausible.
    final tempoOk = tempoS >= _cfg.tempoMinS && tempoS <= _cfg.tempoMaxS;
    var score = 100 *
        (0.34 * rom.clamp(0.0, 1.0) +
            0.33 * (tempoOk ? 1.0 : 0.55) +
            0.33 * smoothness);
    if (_repShoulder) score -= 18;

    final rep = RepComplete(
      index: _repCount,
      score: score.round().clamp(0, 100),
      romFraction: rom.toDouble(),
      cocontraction: cocon,
      smoothness: smoothness,
      holdSteadiness: steady,
      peakAngleDeg: _repPeak,
      compFlags: _repShoulder ? compShoulder : 0,
      durationMs: (tempoS * 1000).round(),
    );
    _event(RehabEvent.repComplete, rep.pack());

    // Fatigue: median frequency falls as the set goes on. Advises, never
    // ends the set.
    _mdf = math.max(58.0, _mdf - 1.35 - _rng.nextDouble() * 0.5);
    if (!_fatigueWarned && _mdf < 82.0) {
      _fatigueWarned = true;
      _event(RehabEvent.fatigueWarn, const []);
    }

    if (_repCount >= _cfg.repTarget) {
      _event(RehabEvent.setComplete, const []);
      _sessionRunning = false;
      _phase = _Phase.idle;
      _event(RehabEvent.stateChange, [FwState.standby.wire]);
    }

    _prepareRep();
    _pushStatus();
  }

  // ── Emitters ───────────────────────────────────────────────────────────

  void _pushFeatures(RepState state, {required bool activation}) {
    _emit(
      kUuidEvents,
      buildFeatureFrame(
        _featureSeq++,
        _tUs,
        envelope: [_envelope.clamp(0.0, 1.5)],
        // Zero below activation, as the firmware reports it.
        mdf: [activation ? _mdf + _noise(1.2) : 0.0],
        elbowAngleDeg: _angle,
        upperArmDevDeg: _dev,
        repState: state.wire,
        repCount: _repCount,
        compFlags: _repShoulder && activation && _dev.abs() > _cfg.compShoulderDeg
            ? compShoulder
            : 0,
        sigFlags: 0,
        activationOn: activation,
        // The layout the firmware actually emits, pad byte included.
        padded: true,
      ),
    );

    // A trickle of raw frames so the sequence tracker, ACK pacing and the
    // gap display in Settings have something to show. Not the real 25/s.
    if (_sessionRunning && _featureSeq % 4 == 0) {
      final samples = List<List<int>>.generate(
        kBleEmgBatch,
        (i) => [((_envelope * 9000) * math.sin(i * 0.3) + _noise(300)).round()],
      );
      _emit(kUuidRaw, buildEmgFrame(_emgSeq, _tUs, samples));
      _emgSeq += kBleEmgBatch;
    }
  }

  void _event(RehabEvent e, List<int> payload) =>
      _emit(kUuidEvents, buildEventFrame(_tUs, e.wire, payload));

  void _pushStatus() {
    _emit(
      kUuidStatus,
      DeviceStatus(
        fwState:
            _sessionRunning ? FwState.operational.wire : FwState.standby.wire,
        faultCode: 0,
        batteryPct: _batteryPct,
        batteryMv: 3300 + _batteryPct * 9,
        signalQuality: [88 + _rng.nextInt(8)],
        seqOldest: math.max(0, _emgSeq - 40000),
        seqNewest: _emgSeq,
        clipCount: const [0],
        flags: statusFlagPsramBacked,
        repCount: _repCount,
        hostTimeOffsetUs:
            DateTime.now().toUtc().microsecondsSinceEpoch - _tUs,
      ).pack(),
    );
  }

  double _noise(double scale) => (_rng.nextDouble() - 0.5) * 2 * scale;
}
