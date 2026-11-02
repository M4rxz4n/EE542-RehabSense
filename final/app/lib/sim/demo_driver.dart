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
/// - a partial rep that stops short of the criterion
///
/// ## It also prints what the sleeve prints
///
/// Three things reach the app only as text on the Messages characteristic: the
/// `[FT1]` fatigue percentages, the per-rep `biceps=` activation ratio, and the
/// whole of calibration's output. A demo that emitted frames but no text would
/// leave the therapist's fatigue chart empty, the rep table's pace column
/// blank and the calibration console silent — which is to say it would exercise
/// none of the paths most likely to be wrong.
///
/// So this driver emits the text too, byte-identical in **format** to the
/// firmware's own `Log.printf` strings. `tool/check_message_patterns.py` checks
/// the parser against those same formats from the other direction.
library;

import 'dart:async';
import 'dart:convert';
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

  // State the printed status lines report, which the frames do not carry.
  bool _calibrated = false;
  bool _resting = false;
  bool _sessionDone = false;
  bool _paceOn = true;
  int _setNumber = 1;
  int _partials = 0;

  /// The session's first three counted reps, for the `[FT1]` baseline the
  /// sleeve compares against. Same rule as `fatigue.cpp`: peak, duration and
  /// effort per degree.
  final List<(double, double, double)> _baseline = [];

  // Per-rep scripting.
  double _repPeak = 0;
  double _repStartUs = 0;
  bool _repShoulder = false;
  bool _repIsPassive = false;
  bool _repIsPartial = false;
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

  /// One printed line, as the sleeve would send it on 000A.
  ///
  /// Newline-terminated, because the reassembler keys on newlines and a line
  /// without one would sit in its buffer — which is exactly the behaviour
  /// worth exercising rather than bypassing.
  void _say(String line) =>
      _emit(kUuidMessages, Uint8List.fromList(utf8.encode('$line\n')));

  /// The `# LIVE` and `# PARAMS` pair the `i` command produces.
  ///
  /// Format copied from `comms.cpp`. The app reads its thresholds from these
  /// in preference to the TLV config, because on a real sleeve calibration can
  /// replace the target without the config changing.
  void _sayStatusLines() {
    final setNo = math.min(_setNumber, _cfg.setCount);
    _say('# LIVE calibrated=${_calibrated ? 1 : 0} '
        'set=$setNo/${_cfg.setCount} reps=$_repCount '
        'partials=$_partials resting=${_resting ? 1 : 0} '
        'done=${_sessionDone ? 1 : 0} paused=0 pace=${_paceOn ? 1 : 0}');
    _say('# PARAMS target=${_cfg.targetAngleDeg.toStringAsFixed(0)} '
        'peak=${CfgDefaults.peakFraction.toStringAsFixed(2)} '
        'start=${_cfg.startAngleDeg.toStringAsFixed(0)} '
        'hyst=${(_cfg.startAngleDeg - _cfg.finishAngleDeg).toStringAsFixed(0)} '
        'tempo=${_cfg.tempoMinS.toStringAsFixed(1)}'
        '-${_cfg.tempoMaxS.toStringAsFixed(1)} '
        'muscle=10 sets=${_cfg.setCount}x${_cfg.repTarget} '
        'rest=${_cfg.restSeconds}');
  }

  // ── Command handling ───────────────────────────────────────────────────

  void _onCommand(Uint8List payload) {
    if (payload.isEmpty) return;
    switch (payload.first) {
      case Cmd.startSession:
        // The sleeve calibrates by itself if it has not been calibrated,
        // then starts. Worth reproducing: it is the path most demos take.
        if (!_calibrated) {
          _runCalibration(CalibPhase.all, thenStart: true);
          return;
        }
        _beginSet();

      case Cmd.stopSession:
        _sessionRunning = false;
        _resting = false;
        _sessionDone = true;
        _phase = _Phase.idle;
        _envelope = 0.02;
        _dev = 0;
        _say('');
        _say('# SESSION STOPPED from the app: $_repCount reps.');
        // No payload after a STOP, which is how the app tells a stop from a
        // set that finished on its own.
        _event(RehabEvent.setComplete, const []);
        _event(RehabEvent.stateChange, [FwState.standby.wire]);
        _pushStatus();

      case Cmd.text:
        _onText(utf8.decode(payload.sublist(1), allowMalformed: true).trim());

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

  /// A Serial Monitor command, as the TEXT opcode delivers it.
  ///
  /// Only the commands the app actually sends are answered. An unknown one
  /// gets the sleeve's own reply, because a demo that silently swallowed a
  /// typo would teach the wrong lesson about the real thing.
  void _onText(String cmd) {
    switch (cmd) {
      case 'i':
        _sayStatusLines();
      case 'b':
        _paceOn = !_paceOn;
        _say('# [GP1] Guided pace ${_paceOn ? 'on: tick = UP, steady buzz = '
            'HOLD, double tick = DOWN' : 'off'}');
      case 'z':
        _say('Straight-arm reference saved (0 deg). Angle now '
            '${_angle.toStringAsFixed(1)} deg');
      case 'e':
        _runEmgTest();
      case 'r':
        _repCount = 0;
        _partials = 0;
        _setNumber = 1;
        _sessionDone = false;
        _baseline.clear();
        _say('# New session: set 1 of ${_cfg.setCount}');
      case 'c':
        _runCalibration(CalibPhase.all);
      case 'n':
        // Advancing a step by hand. The scripted timer already paces them, so
        // this only acknowledges.
        _say('>> moving on');
      case 'g':
        if (!_sessionRunning) _beginSet();
      case 't?':
        _say('# [AT4] Target now '
            '${_cfg.targetAngleDeg.toStringAsFixed(0)} deg, saved '
            '${_cfg.targetAngleDeg.toStringAsFixed(0)} deg, adaptive, '
            '3 session(s)');
      case 'tl':
        _say('# [AT3] Target locked at '
            '${_cfg.targetAngleDeg.toStringAsFixed(0)} deg');
      case 'tr':
        _say('# [AT4] Saved progress cleared. The next calibration starts '
            'fresh.');
      default:
        if (cmd.startsWith('h')) {
          _say('# $cmd: (demo mode has no motor to drive)');
        } else if (cmd.startsWith('t') && cmd.length > 1) {
          _say('# [AT3] Target set to ${cmd.substring(1)} deg and locked');
        } else {
          _say('# Unknown command "$cmd". Type ? for help.');
        }
    }
  }

  /// The EMG signal test, with the firmware's own line formats and a healthy
  /// result. Timed rather than instant, because the screen shows it running.
  void _runEmgTest() {
    _say('');
    _say('# === EMG signal-quality test ===');
    _say('# Sit still. Laptop on battery, unplugged from the charger.');
    var step = 0;
    Timer.periodic(const Duration(milliseconds: 900), (t) {
      switch (step++) {
        case 0:
          _say('# Measuring: stay relaxed...');
        case 1:
          _say('# Measuring: keep squeezing...');
        case 2:
          _say('#');
          _say('# REST     mean    118 mV   noise (SD)   3.2 mV   '
              'range   96.. 141 mV');
          _say('#          mains hum: 60 Hz 0.9 mV RMS, 120 Hz 0.3 mV RMS '
              '(28% of the rest noise)');
          _say('# SQUEEZE  mean    965 mV   peak 1218 mV   '
              'rise above rest   847 mV');
          _say('# SNR      24.4 dB (squeeze rise / rest noise)');
          _say('#');
        case 3:
          _say('# PASS  SNR at least 20 dB: clean enough for rep detection '
              'and scoring.');
          _say('# Tips: reseat electrodes with fresh gel, reference on the '
              'elbow bone, keep the leads short.');
          _say('# === End of EMG test ===');
          _say('');
          t.cancel();
      }
    });
  }

  /// Calibration, as the sleeve runs it: three steps, each announced twice
  /// (0% then 100%), with the measured results printed in between.
  ///
  /// Three steps and not six — the shipping sleeve has no contact check, no
  /// triceps channel and no range sweep. A demo that showed six would train
  /// everyone to expect prompts the hardware never sends.
  void _runCalibration(CalibPhase requested, {bool thenStart = false}) {
    const steps = [CalibPhase.rest, CalibPhase.straight, CalibPhase.biceps];
    final run = requested == CalibPhase.all ? steps : [requested];

    _say('');
    _say('=== Calibration ===');
    _say('Started from the app: each step starts by itself after 3 s.');

    var i = 0;
    var half = 0;
    _calib?.cancel();
    _calib = Timer.periodic(const Duration(milliseconds: 1100), (t) {
      if (i >= run.length) {
        t.cancel();
        _calibrated = true;
        _say('=== Calibration done ===');
        _sayStatusLines();
        _emit(kUuidCalib, _calibRecord.pack());
        _event(RehabEvent.calibPhaseDone,
            [CalibPhase.done.wire, 100]);
        if (thenStart) _beginSet();
        return;
      }

      final phase = run[i];
      if (half == 0) {
        _event(RehabEvent.calibPhaseDone, [phase.wire, 0]);
        _say('>> ${_promptFor(phase)}');
        half = 1;
      } else {
        _sayResultsFor(phase);
        _event(RehabEvent.calibPhaseDone, [phase.wire, 100]);
        _say('Step ${i + 1} done.');
        half = 0;
        i++;
      }
    });
  }

  String _promptFor(CalibPhase p) => switch (p) {
        CalibPhase.rest => 'Let your arm hang loose and still',
        CalibPhase.straight => 'Hold your arm straight and still',
        CalibPhase.biceps => 'Squeeze as hard as is comfortable',
        _ => 'Hold still',
      };

  void _sayResultsFor(CalibPhase p) {
    switch (p) {
      case CalibPhase.rest:
        _say('[FC1] Rest EMG noise 3.2 mV (SD)');
        _say('Rest EMG 118 mV, gyro bias upper 0.08/-0.14/0.21, '
            'fore -0.05/0.11/-0.19 deg/s');
      case CalibPhase.straight:
        _say('Straight-arm reference saved (0 deg). Angle now 0.4 deg');
      case CalibPhase.biceps:
        _say('Max contraction EMG 965 mV');
        _say('[FC1] Biceps counts as working above 160 mV (10%), relaxed '
            'below 140 mV');
        final bend = _calibRecord.angleMax.toStringAsFixed(0);
        final target = _cfg.targetAngleDeg.toStringAsFixed(0);
        final counts =
            (_cfg.targetAngleDeg * CfgDefaults.peakFraction).toStringAsFixed(0);
        _say('Comfortable bend $bend deg: target $target deg '
            '(a rep counts from $counts deg)');
      default:
        break;
    }
  }

  void _beginSet() {
    _sessionRunning = true;
    _resting = false;
    _sessionDone = false;
    _repCount = 0;
    _mdf = 96.0;
    _fatigueWarned = false;
    _baseline.clear();
    _phase = _Phase.ready;
    _phaseElapsedMs = 0;
    _angle = _cfg.finishAngleDeg;
    _prepareRep();
    _say('');
    _say('Rep start! Set $_setNumber of ${_cfg.setCount}');
    _event(RehabEvent.stateChange, [FwState.operational.wire]);
    _pushStatus();
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
    // And one honest attempt that stops short of the criterion. It is
    // reported and not counted, which is the case a patient most needs to see
    // handled gracefully — nothing at all after a hard attempt reads as a
    // broken device.
    _repIsPartial = next == 7;
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
        // A partial stops short of the criterion by design: it reaches the
        // band and turns round without crossing the line.
        final top = _repIsPartial
            ? finish + (peakTarget - finish) * 0.62
            : peakTarget + 6;
        _angle = finish + (top - finish) * eased + _noise(0.7);
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

        // A partial turns round at the top of its own shorter travel; a full
        // rep turns round on crossing the criterion.
        if (_repIsPartial ? u >= 1.0 : _angle >= peakTarget) {
          _phase = _Phase.peak;
          _phaseElapsedMs = 0;
          if (_repShoulder) {
            _event(RehabEvent.compensationShoulder, const []);
          }
        }

      case _Phase.peak:
        _angle = (_repIsPartial ? _repPeak : peakTarget + 6) + _noise(0.8);
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
            // Never became a rep. The printed line carries the peak and the
            // activation ratio the event does not.
            _partials++;
            _say('# NOT COUNTED [FC2]: peak ${_repPeak.toStringAsFixed(0)} '
                'deg, but the biceps was working for only 18% of the lift '
                '(needs 60%).');
            _say('#   It looked like the arm was lifted for you. Lift it with '
                'your biceps.');
            _repIsPassive = false;
            _prepareRep();
            _phase = _Phase.ready;
          } else if (_repIsPartial) {
            _partials++;
            final needed =
                (_cfg.targetAngleDeg * CfgDefaults.peakFraction);
            // `<Hh`: the index the NEXT rep would take, and the peak in
            // tenths of a degree. A partial consumes no number.
            final payload = ByteData(4)
              ..setUint16(0, _repCount + 1, Endian.little)
              ..setInt16(2, (_repPeak * 10).round(), Endian.little);
            _event(RehabEvent.repAbandoned,
                payload.buffer.asUint8List().toList());
            _say('# Partial rep (peak ${_repPeak.toStringAsFixed(0)} deg, '
                'needed ${needed.toStringAsFixed(0)})');
            _say('#   That one didn\'t quite reach the target. Rest a moment '
                'if you need to.');
            _repIsPartial = false;
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

    // The printed line, in `rep.cpp`'s format. It carries the two fields the
    // event does not: the tempo verdict in words, and the share of the lift
    // the biceps was working.
    final tempoScore =
        (tempoOk ? 100 : 100 - 25 * (tempoS - _cfg.tempoMaxS).abs())
            .clamp(50, 100)
            .round();
    final tempoText = tempoS < _cfg.tempoMinS
        ? 'too fast'
        : tempoS > _cfg.tempoMaxS
            ? 'slow'
            : 'ok';
    final bicepsPct = _repShoulder ? 71 : 78 + _rng.nextInt(12);
    final flags = _repShoulder ? '  flags=shoulder' : '';
    final flagged = _repShoulder ? '  FLAGGED' : '';

    _say('# REP $_repCount  peak=${_repPeak.toStringAsFixed(1)} deg  '
        'duration=${tempoS.toStringAsFixed(1)} s  '
        'rom=${(rom * 100).round()}  '
        'tempo=$tempoScore ($tempoText)  '
        'score=${rep.score}$flagged$flags  biceps=$bicepsPct%');
    if (_repShoulder) {
      _say('#   [FC4] Your upper arm moved 26 deg: keep your elbow by your '
          'side and sit tall (-20).');
    }
    _say('#   Set $_setNumber: $_repCount of ${_cfg.repTarget}');

    // The `[FT1]` comparison: the last reps against the session's first
    // three, as `fatigue.cpp` computes it. Effort is per degree, so a rep
    // that costs the same muscle for less range counts as fatigue.
    final effortPerDeg = _envelope <= 0 || _repPeak <= 0
        ? 0.0
        : (0.6 * 100) / _repPeak;
    if (_baseline.length < 3) {
      _baseline.add((_repPeak, tempoS, effortPerDeg));
    } else {
      double mean(int i) =>
          _baseline.map((b) => [b.$1, b.$2, b.$3][i]).reduce((a, b) => a + b) /
          _baseline.length;
      final rangePct = _repPeak / mean(0) * 100;
      final timePct = tempoS / mean(1) * 100;
      // Walks up across the set, so the demo reaches a sign rather than
      // sitting at 100% for ever.
      final effortPct = 100 + (_repCount - 3) * 4.5;

      final rangeSign = rangePct < FatigueThresholds.range;
      final effortSign = effortPct > FatigueThresholds.effort;
      final slowSign = timePct > FatigueThresholds.time;
      final marks = '${rangeSign ? '  RANGE' : ''}'
          '${effortSign ? '  EFFORT' : ''}'
          '${slowSign ? '  SLOW' : ''}';
      _say('#   [FT1] vs your first reps: '
          'range ${rangePct.toStringAsFixed(0)}%, '
          'effort ${effortPct.toStringAsFixed(0)}%, '
          'time ${timePct.toStringAsFixed(0)}%$marks');

      final signs =
          (rangeSign ? 1 : 0) + (effortSign ? 1 : 0) + (slowSign ? 1 : 0);
      if (signs >= 1 && !_fatigueWarned) {
        _fatigueWarned = true;
        // `<hH`: the number of signs and the total reps.
        final payload = ByteData(4)
          ..setInt16(0, signs, Endian.little)
          ..setUint16(2, _repCount, Endian.little);
        _event(RehabEvent.fatigueWarn, payload.buffer.asUint8List().toList());
        _say('#   [FT2] You may be getting tired. Take your time.');
      }
    }

    // Median frequency still falls, for the ESP-IDF firmware's own fatigue
    // signal. The shipping sleeve reports zero here and leans on `[FT1]`.
    _mdf = math.max(58.0, _mdf - 1.35 - _rng.nextDouble() * 0.5);

    if (_repCount >= _cfg.repTarget) {
      // u16 reps in the set. Distinct from a STOP, which sends no payload.
      final payload = ByteData(2)..setUint16(0, _repCount, Endian.little);
      _event(RehabEvent.setComplete, payload.buffer.asUint8List().toList());
      _say('');
      _say('Set $_setNumber of ${_cfg.setCount} complete. Well done! Rest for '
          '${_cfg.restSeconds} s: let your arm relax.');
      _sessionRunning = false;
      _resting = _setNumber < _cfg.setCount;
      _sessionDone = !_resting;
      if (_resting) _setNumber++;
      _phase = _Phase.idle;
      _event(RehabEvent.stateChange, [FwState.standby.wire]);
      _sayStatusLines();
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
