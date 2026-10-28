/// Live session state.
///
/// One place that holds what the sleeve has told us, so the patient view, the
/// calibration wizard and the clinician bridge all read the same numbers.
///
/// ## The device is authoritative
///
/// Every event the sleeve reports — rep counted, compensation, fatigue,
/// fault — is final. This class **records** them. It never re-derives a rep,
/// never recounts, and never second-guesses a score from the raw stream. If a
/// number here disagrees with the firmware, the firmware is right and this is
/// a bug.
///
/// ## Repaint discipline
///
/// Features arrive at 20 Hz. Driving `notifyListeners()` at that rate rebuilds
/// every listening widget 20 times a second, which on a mid-range Android
/// phone is enough to make the BLE link miss connection events — the exact
/// failure the PRD warns about on the Python side.
///
/// So the hot path is split: [liveFeature] is a [ValueNotifier] that only the
/// pose painter and the numeric readouts listen to, behind a `RepaintBoundary`.
/// `notifyListeners()` fires on the slow things — a rep completing, a state
/// change, status, config.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../ble/rehab_device.dart';
import '../protocol/calib.dart';
import '../protocol/commands.dart';
import '../protocol/config_tlv.dart';
import '../protocol/enums.dart';
import '../protocol/frames.dart';
import '../protocol/status.dart';
import '../protocol/xfer.dart';

/// One entry in the session log the clinician sees.
class LoggedEvent {
  LoggedEvent(this.tUs, this.event, this.label, {this.detail});

  final int tUs;
  final int event;
  final String label;
  final String? detail;

  final DateTime wallClock = DateTime.now();

  bool get isCompensation =>
      event == RehabEvent.compensationShoulder.wire ||
      event == RehabEvent.compensationTrunk.wire ||
      event == RehabEvent.compensationSwing.wire;

  bool get isConcerning =>
      isCompensation ||
      event == RehabEvent.fault.wire ||
      event == RehabEvent.signalDegraded.wire ||
      event == RehabEvent.fatigueWarn.wire;

  Map<String, dynamic> toJson() => {
        't_us': tUs,
        'event': event,
        'label': label,
        if (detail != null) 'detail': detail,
        'wall_clock': wallClock.toIso8601String(),
        'concerning': isConcerning,
      };
}

/// A point on the live traces.
class TracePoint {
  const TracePoint({
    required this.tUs,
    required this.angleDeg,
    required this.envelope,
    required this.mdf,
    required this.activationOn,
  });

  final int tUs;
  final double angleDeg;

  /// Agonist, %MVC.
  final double envelope;

  /// Agonist median frequency, Hz. Zero below activation, which is why the
  /// fatigue trend only looks at activated samples.
  final double mdf;

  final bool activationOn;
}

class SessionState extends ChangeNotifier {
  SessionState(this.device) {
    _wire();
  }

  final RehabDevice device;
  final List<StreamSubscription<dynamic>> _subs = [];

  // ── Hot path ───────────────────────────────────────────────────────────

  /// The newest feature frame. Listen to this directly for anything that
  /// animates; do not read it inside a widget that also listens to the
  /// [SessionState] itself.
  final ValueNotifier<FeatureFrame?> liveFeature = ValueNotifier(null);

  /// Rolling window for the traces, oldest first.
  ///
  /// 20 Hz for 30 seconds. Long enough to show a few reps in context, short
  /// enough that it never becomes a memory question over a 10-minute session.
  static const int traceCapacity = 20 * 30;
  final Queue<TracePoint> _trace = Queue<TracePoint>();
  Iterable<TracePoint> get trace => _trace;

  // ── Slow path ──────────────────────────────────────────────────────────

  LinkState linkState = LinkState.idle;
  DeviceStatus? status;
  CalibRecord? calibration;
  XferInfo? transfer;
  RuntimeConfig get config => device.currentConfig;

  final List<RepComplete> reps = [];
  final List<LoggedEvent> log = [];
  final List<String> problems = [];

  /// Set to true by START_SESSION and false by STOP_SESSION, so the UI knows
  /// what it is allowed to offer. The device's own [FwState] is the real
  /// answer and arrives on the status characteristic.
  bool sessionRequested = false;

  DateTime? sessionStartedAt;

  /// Which calibration step is running, if any.
  CalibPhase? calibratingPhase;

  /// Completed steps, so the wizard can show progress and offer a re-run of
  /// one step rather than the whole protocol.
  final Set<CalibPhase> calibrationDone = {};

  /// The most recent haptic the device would have played, for the visual
  /// mirror in the patient view. Cleared by the UI once shown.
  HapticPattern? pendingCue;

  /// Broadcast of everything the clinician bridge should relay. Deliberately
  /// a separate stream rather than the bridge listening to this object:
  /// the bridge must not be able to hold a repaint hostage.
  final _bridge = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get bridgeFeed => _bridge.stream;

  void _emit(String kind, Map<String, dynamic> body) {
    if (_bridge.isClosed) return;
    _bridge.add({'kind': kind, 'at': DateTime.now().toIso8601String(), ...body});
  }

  // ── Derived, for the UI ────────────────────────────────────────────────

  int get repCount => liveFeature.value?.repCount ?? status?.repCount ?? 0;

  double get angleDeg => liveFeature.value?.elbowAngleDeg ?? 0.0;

  /// %MVC of the agonist. Which channel that is comes from the config, not an
  /// assumption: `agonist_channel` is settable and the other channel is the
  /// antagonist.
  double get agonistEnvelope {
    final f = liveFeature.value;
    if (f == null) return 0.0;
    final i = config.agonistChannel;
    return i < f.envelope.length ? f.envelope[i] : f.envelope.first;
  }

  double get antagonistEnvelope {
    final f = liveFeature.value;
    if (f == null || f.envelope.length < 2) return 0.0;
    return f.envelope[config.agonistChannel == 0 ? 1 : 0];
  }

  RepState get repState => liveFeature.value?.repState ?? RepState.ready;

  /// Progress through the current set, 0..1.
  double get setProgress =>
      config.repTarget == 0 ? 0 : (repCount / config.repTarget).clamp(0.0, 1.0);

  /// The score the patient sees: the most recent rep the device graded.
  ///
  /// Null until the firmware emits EVT_REP_COMPLETE — see the note in
  /// `RepComplete`. Until that wiring lands this stays empty against real
  /// firmware, and the simulator is the only thing that fills it.
  RepComplete? get lastRep => reps.isEmpty ? null : reps.last;

  double? get meanScore => reps.isEmpty
      ? null
      : reps.map((r) => r.score).reduce((a, b) => a + b) / reps.length;

  /// Fatigue indication: median frequency falling across the set, in Hz.
  ///
  /// Negative means the trend is downwards, which is the fatigue direction.
  /// Only activated samples count — `mdf` is zero below activation, and
  /// including the rests would swamp the trend with zeros.
  ///
  /// This is for display alongside the device's own EVT_FATIGUE_WARN, not a
  /// substitute for it. The device runs the real regression; this is a
  /// coarse first-half/second-half difference so the clinician page has
  /// something to draw. It advises, and never ends a set.
  double? get mdfTrendHz {
    final pts = _trace.where((p) => p.activationOn && p.mdf > 0).toList();
    if (pts.length < 40) return null;
    final half = pts.length ~/ 2;
    double mean(Iterable<TracePoint> xs) =>
        xs.map((p) => p.mdf).reduce((a, b) => a + b) / xs.length;
    return mean(pts.skip(pts.length - half)) - mean(pts.take(half));
  }

  bool get hasGap => status?.gapOccurred ?? false;

  // ── Wiring ─────────────────────────────────────────────────────────────

  void _wire() {
    _subs.add(device.linkState.listen((s) {
      linkState = s;
      _emit('link', {'state': s.name, 'label': s.label});
      notifyListeners();
    }));

    _subs.add(device.features.listen(_onFeature));
    _subs.add(device.events.listen(_onEvent));

    _subs.add(device.status.listen((s) {
      final previous = status;
      status = s;
      // A fault is the one status change that must reach the patient.
      if (s.inFault && previous?.faultCode != s.faultCode) {
        log.add(LoggedEvent(0, RehabEvent.fault.wire, 'Fault', detail: s.faultLabel));
        pendingCue = HapticPattern.fault;
      }
      _emit('status', s.toJson());
      notifyListeners();
    }));

    _subs.add(device.config.listen((c) {
      _emit('config', c.toJson());
      notifyListeners();
    }));

    _subs.add(device.calibration.listen((c) {
      calibration = c;
      _emit('calibration', c.toJson());
      notifyListeners();
    }));

    _subs.add(device.transfer.listen((x) {
      transfer = x;
      _emit('transfer', x.toJson());
      notifyListeners();
    }));

    _subs.add(device.problems.listen((p) {
      problems.add(p);
      if (problems.length > 100) problems.removeAt(0);
      notifyListeners();
    }));
  }

  void _onFeature(FeatureFrame f) {
    liveFeature.value = f;

    final ch = config.agonistChannel < f.envelope.length
        ? config.agonistChannel
        : 0;
    _trace.add(TracePoint(
      tUs: f.tUs,
      angleDeg: f.elbowAngleDeg,
      envelope: f.envelope[ch],
      mdf: ch < f.mdf.length ? f.mdf[ch] : 0.0,
      activationOn: f.activationOn,
    ));
    while (_trace.length > traceCapacity) {
      _trace.removeFirst();
    }

    // Thinned for the bridge: 20 Hz over a WebSocket to a browser is fine,
    // but there is no reason to send every frame when a clinician is reading
    // a trace, and halving it halves the phone's upstream work.
    if (f.seq.isEven) {
      _emit('features', {
        'seq': f.seq,
        't_us': f.tUs,
        'angle_deg': f.elbowAngleDeg,
        'upper_arm_dev_deg': f.upperArmDevDeg,
        'envelope': f.envelope,
        'mdf': f.mdf,
        'rep_state': f.repState.name,
        'rep_count': f.repCount,
        'activation_on': f.activationOn,
        'compensations': f.compensations,
        'signal_degraded': f.signalDegraded,
      });
    }

    // Deliberately NO notifyListeners() here. See the class comment.
  }

  void _onEvent(EventFrame e) {
    final kind = e.kind;
    String? detail;

    switch (kind) {
      case RehabEvent.repComplete:
        if (e.payload.length >= RepComplete.bytes) {
          final rep = RepComplete.parse(e.payload);
          reps.add(rep);
          detail = 'rep ${rep.index}, score ${rep.score}';
          pendingCue =
              rep.flagged ? HapticPattern.repFlagged : HapticPattern.repClean;
          _emit('rep', rep.toJson());
        }

      case RehabEvent.setComplete:
        pendingCue = HapticPattern.setComplete;

      case RehabEvent.fatigueWarn:
        pendingCue = HapticPattern.rest;

      case RehabEvent.fault:
        pendingCue = HapticPattern.fault;
        if (e.payload.isNotEmpty) detail = Fault.nameOf(e.payload.first);

      case RehabEvent.calibPhaseDone:
        final phase = e.payload.isNotEmpty
            ? CalibPhase.fromWire(e.payload.first)
            : calibratingPhase;
        if (phase != null) {
          calibrationDone.add(phase);
          detail = phase.label;
        }
        calibratingPhase = null;

      case RehabEvent.passiveSwing:
        // Worth logging prominently: it looks like a missed rep to a patient,
        // and it is the demo item that proves activation gating works.
        detail = 'arm moved without biceps activation — not counted';

      case RehabEvent.stateChange:
        if (e.payload.isNotEmpty) detail = FwState.nameOf(e.payload.first);

      default:
        break;
    }

    final entry = LoggedEvent(e.tUs, e.event, e.label, detail: detail);
    log.add(entry);
    if (log.length > 500) log.removeAt(0);

    _emit('event', entry.toJson());
    notifyListeners();
  }

  // ── Commands, with the local bookkeeping they imply ────────────────────

  Future<void> startSession() async {
    if (await device.startSession(config.exerciseId)) {
      sessionRequested = true;
      sessionStartedAt = DateTime.now();
      reps.clear();
      log.clear();
      _trace.clear();
      device.seq.reset();
      _emit('session', {'started': true});
      notifyListeners();
    }
  }

  Future<void> stopSession() async {
    if (await device.stopSession()) {
      sessionRequested = false;
      _emit('session', {'started': false, 'reps': reps.length});
      notifyListeners();
    }
  }

  Future<void> runCalibrationStep(CalibPhase phase) async {
    if (await device.startCalibration(phase)) {
      calibratingPhase = phase;
      calibrationDone.remove(phase);
      notifyListeners();
    }
  }

  Future<void> abortCalibration() async {
    if (await device.abortCalibration()) {
      calibratingPhase = null;
      notifyListeners();
    }
  }

  /// Push the parameters that changed and read them back.
  ///
  /// Build [blocks] with the `cfgU8` / `cfgU16` / `cfgF32` helpers. Sending
  /// only what changed matters during a session: each write competes with the
  /// live stream for the same connection events.
  ///
  /// The read-back is not cosmetic. The firmware rejects a recognised tag
  /// carrying the wrong length and says nothing on the wire, so comparing
  /// what comes back is the only confirmation a change took effect — which is
  /// what demo item 6 depends on.
  Future<bool> setParameters(List<Uint8List> blocks) =>
      device.setConfigTags(blocks);

  void consumeCue() {
    pendingCue = null;
  }

  /// A full snapshot, for a clinician page that has just connected and needs
  /// to render something before the next frame arrives.
  Map<String, dynamic> snapshot() => {
        'kind': 'snapshot',
        'at': DateTime.now().toIso8601String(),
        'link': linkState.name,
        'device': {'id': device.deviceId, 'name': device.deviceName},
        'session_active': sessionRequested,
        'started_at': sessionStartedAt?.toIso8601String(),
        'config': config.toJson(),
        'status': status?.toJson(),
        'calibration': calibration?.toJson(),
        'rep_count': repCount,
        'reps': reps.map((r) => r.toJson()).toList(),
        'mean_score': meanScore,
        'mdf_trend_hz': mdfTrendHz,
        'log': log.reversed.take(50).map((e) => e.toJson()).toList(),
        'stream': device.seq.toJson(),
        'trace': _trace
            .map((p) => {
                  't_us': p.tUs,
                  'angle_deg': p.angleDeg,
                  'envelope': p.envelope,
                  'mdf': p.mdf,
                  'activation_on': p.activationOn,
                })
            .toList(),
      };

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    liveFeature.dispose();
    _bridge.close();
    super.dispose();
  }
}
