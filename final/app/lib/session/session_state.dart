/// Live session state.
///
/// One place that holds what the sleeve has told us, so the patient view, the
/// calibration wizard, the session analysis, the therapist dashboard and the
/// clinician bridge all read the same numbers.
///
/// ## The device is authoritative
///
/// Every event the sleeve reports — rep counted, compensation, fatigue,
/// fault — is final. This class **records** them. It never re-derives a rep,
/// never recounts, and never second-guesses a score from the raw stream. If a
/// number here disagrees with the firmware, the firmware is right and this is
/// a bug.
///
/// There is exactly one exception, and it is labelled everywhere it surfaces:
/// the lift / hold / lower split of a repetition, which the sleeve does not
/// report and which is reconstructed here by timing `rep_state`. See
/// [PhaseTimer].
///
/// ## Two notifications per repetition
///
/// A counted rep produces `EVT_REP_COMPLETE` **and** a printed `# REP` line,
/// and they carry different fields. The event has the score, range, peak,
/// duration and flags; the line has the tempo verdict in words and the share
/// of the lift the biceps was working, which appear in no frame.
///
/// They arrive in either order. The firmware prints the line first but queues
/// events ahead of lines, so in practice the event wins — but not reliably,
/// and the indices do not match either (the line numbers reps across the
/// session, the event within the set). So they are correlated by adjacency in
/// time rather than by index: see [_pendingPrinted].
///
/// ## Repaint discipline
///
/// Features arrive at 20 Hz. Driving `notifyListeners()` at that rate rebuilds
/// every listening widget 20 times a second, which on a mid-range Android
/// phone is enough to make the BLE link miss connection events — the exact
/// failure the PRD warns about on the Python side.
///
/// So the hot path is split. [liveFeature] is a [ValueNotifier] that only the
/// pose painter and the numeric readouts listen to, behind a
/// `RepaintBoundary`. [liveTraceRevision] is a second one that the live charts
/// watch. `notifyListeners()` fires on the slow things — a rep completing, a
/// state change, status, config, a printed line.
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
import '../protocol/sleeve_messages.dart';
import '../protocol/status.dart';
import '../protocol/xfer.dart';
import 'rep_log.dart';
import 'session_record.dart';

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
      event == RehabEvent.fatigueWarn.wire ||
      event == RehabEvent.passiveSwing.wire ||
      event == RehabEvent.repAbandoned.wire;

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
    required this.repState,
  });

  final int tUs;
  final double angleDeg;

  /// Agonist, %MVC. The sleeve reports 0..1.5 — above 1 is legitimate, and
  /// means the normalising squeeze was gentler than this effort.
  final double envelope;

  /// Agonist median frequency, Hz. Zero below activation, which is why the
  /// fatigue trend only looks at activated samples.
  ///
  /// Always zero against the shipping sleeve: median frequency needs the
  /// MyoWare's RAW output and the prototype uses ENV. The therapist view
  /// therefore leans on the sleeve's own `[FT1]` comparison, not on this.
  final double mdf;

  final bool activationOn;
  final RepState repState;
}

/// The thresholds the sleeve says are in force, from its `# PARAMS` line.
///
/// Distinct from [RuntimeConfig], which is the TLV configuration the host
/// wrote. They disagree in one important case: calibration replaces the target
/// with the patient's own adaptive one `[AT1]`, and that change is announced
/// only in this line. A chart drawn from the TLV target after calibration
/// draws the criterion in the wrong place.
class SleeveParams {
  const SleeveParams({
    required this.targetDeg,
    required this.peakFraction,
    required this.startDeg,
    required this.hystDeg,
    required this.tempoMinS,
    required this.tempoMaxS,
    required this.muscleOnPercent,
    required this.sets,
    required this.repsPerSet,
    required this.restSeconds,
  });

  final double targetDeg;
  final double peakFraction;
  final double startDeg;
  final double hystDeg;
  final double tempoMinS;
  final double tempoMaxS;
  final double muscleOnPercent;
  final int sets;
  final int repsPerSet;
  final int restSeconds;

  /// The angle a rep must pass to count.
  double get peakDeg => targetDeg * peakFraction;

  /// Where a rep ends: below the start angle, minus the hysteresis.
  double get finishDeg => startDeg - hystDeg;

  static SleeveParams? fromMessage(SleeveMessage m) {
    if (m.kind != SleeveMessageKind.params) return null;
    return SleeveParams(
      targetDeg: m.num_('targetDeg') ?? 90,
      peakFraction: m.num_('peakFraction') ?? 0.8,
      startDeg: m.num_('startDeg') ?? 15,
      hystDeg: m.num_('hystDeg') ?? 5,
      tempoMinS: m.num_('tempoMinS') ?? 3,
      tempoMaxS: m.num_('tempoMaxS') ?? 8,
      muscleOnPercent: m.num_('muscleOnPct') ?? 10,
      sets: m.int_('sets') ?? 3,
      repsPerSet: m.int_('repsPerSet') ?? 10,
      restSeconds: m.int_('restS') ?? 60,
    );
  }
}

/// What the sleeve said about itself in its `# LIVE` line.
class SleeveLive {
  const SleeveLive({
    required this.calibrated,
    required this.setNumber,
    required this.sets,
    required this.reps,
    required this.partials,
    required this.resting,
    required this.sessionDone,
    required this.paused,
    required this.paceOn,
  });

  final bool calibrated;
  final int setNumber;
  final int sets;
  final int reps;
  final int partials;
  final bool resting;
  final bool sessionDone;
  final bool paused;
  final bool paceOn;

  static SleeveLive? fromMessage(SleeveMessage m) {
    if (m.kind != SleeveMessageKind.live) return null;
    return SleeveLive(
      calibrated: m.flag('calibrated'),
      setNumber: m.int_('set') ?? 1,
      sets: m.int_('sets') ?? 3,
      reps: m.int_('reps') ?? 0,
      partials: m.int_('partials') ?? 0,
      resting: m.flag('resting'),
      sessionDone: m.flag('done'),
      paused: m.flag('paused'),
      paceOn: m.flag('paceOn'),
    );
  }
}

/// Which beat of the guided pace cycle the sleeve is on.
enum PacePhase {
  up('Pull up', 'tick each beat'),
  hold('Hold at the top', 'steady buzz'),
  down('Lower slowly', 'double tick'),
  relax('Relax, arm straight', 'silence'),
  waiting('Straighten your arm', 'waiting for a straight arm'),
  off('', '');

  const PacePhase(this.label, this.feel);
  final String label;
  final String feel;

  static PacePhase fromWord(String w) => switch (w.toUpperCase()) {
        'UP' => up,
        'HOLD' => hold,
        'DOWN' => down,
        'RELAX' => relax,
        'WAIT' => waiting,
        _ => off,
      };
}

/// A printed `# REP` line waiting for its event, or vice versa.
class _PendingPrinted {
  _PendingPrinted(this.message) : at = DateTime.now();
  final SleeveMessage message;
  final DateTime at;
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

  /// Bumped whenever the rolling trace changes. The live charts watch this
  /// rather than the state object, so a 20 Hz redraw of one chart does not
  /// rebuild the screen around it.
  final ValueNotifier<int> liveTraceRevision = ValueNotifier(0);

  /// Rolling window for the live traces, oldest first.
  ///
  /// 20 Hz for 30 seconds. Long enough to show a few reps in context, short
  /// enough that it never becomes a memory question over a 10-minute session.
  static const int traceCapacity = 20 * 30;
  final Queue<TracePoint> _trace = Queue<TracePoint>();
  Iterable<TracePoint> get trace => _trace;

  // ── The whole session, for saving and for the analysis tab ─────────────

  /// Every sample of the session, thinned to [recordHz].
  ///
  /// Separate from [_trace], which is a 30-second window for the live charts.
  /// This one is the recording, and it is thinned because a 20-minute session
  /// at 20 Hz is 24,000 points — more than any chart can draw and more than is
  /// worth writing to flash. 10 Hz still resolves a 2 s curl into twenty
  /// points, which is plenty for the shapes these charts show.
  static const int recordHz = 10;
  final List<TraceSample> _record = [];
  List<TraceSample> get record => List.unmodifiable(_record);

  /// Cap on the recording, about two hours at [recordHz]. A session that runs
  /// past it keeps counting reps and stops extending the trace, which is the
  /// right way round: the reps are the data, the trace is context.
  static const int recordCapacity = recordHz * 60 * 120;

  int? _recordT0Us;
  int _lastRecordedMs = -1000;

  final List<RepRow> repRows = [];
  final List<SetRating> ratings = [];
  final List<FaultSpan> faults = [];
  int? _faultOpenedMs;
  int fatigueStops = 0;

  // ── Printed lines ──────────────────────────────────────────────────────

  /// Every line the sleeve printed, newest last.
  final List<SleeveMessage> messages = [];

  /// Bumped on each new line, for the log view to watch without the rest of
  /// the screen rebuilding.
  final ValueNotifier<int> messageRevision = ValueNotifier(0);

  static const int messageCapacity = 2000;

  _PendingPrinted? _pendingPrinted;

  /// How long a printed `# REP` line will wait for its event, or an event for
  /// its line. Generous: the firmware sends a few queued items per 10 ms tick,
  /// so a busy link can separate them by a noticeable margin — but not by
  /// seconds, and pairing the wrong two would be worse than pairing neither.
  static const Duration printedPairingWindow = Duration(seconds: 3);

  // ── Slow path ──────────────────────────────────────────────────────────

  LinkState linkState = LinkState.idle;
  DeviceStatus? status;
  CalibRecord? calibration;
  XferInfo? transfer;
  RuntimeConfig get config => device.currentConfig;

  /// What the sleeve itself last reported. Prefer [effectiveTargetDeg] and
  /// friends over reading either source directly.
  SleeveParams? sleeveParams;
  SleeveLive? sleeveLive;

  PacePhase pacePhase = PacePhase.off;
  bool paceOn = false;
  bool autoPaused = false;

  /// The most recent `[FT1]` comparison.
  FatigueSnapshot? lastFatigue;

  /// Every `[FT1]` comparison in order, which is what the therapist's fatigue
  /// trend chart plots. One per counted rep once the baseline is set.
  final List<FatigueSnapshot> fatigueTrend = [];

  /// The last EMG signal test, as its lines arrived.
  final List<SleeveMessage> emgTestLines = [];
  bool emgTestRunning = false;

  /// The calibration prompt currently in front of the patient, if any.
  String? calibrationPrompt;

  final List<RepComplete> reps = [];
  final List<LoggedEvent> log = [];
  final List<String> problems = [];

  /// Set to true by START_SESSION and false by STOP_SESSION, so the UI knows
  /// what it is allowed to offer. The device's own [FwState] is the real
  /// answer and arrives on the status characteristic.
  bool sessionRequested = false;

  DateTime? sessionStartedAt;
  DateTime? sessionEndedAt;

  /// Which calibration step is running, if any.
  CalibPhase? calibratingPhase;

  /// Completed steps, so the wizard can show progress and offer a re-run of
  /// one step rather than the whole protocol.
  final Set<CalibPhase> calibrationDone = {};

  /// The most recent haptic the device would have played, for the visual
  /// mirror in the patient view. Cleared by the UI once shown.
  HapticPattern? pendingCue;

  /// Set when the sleeve finishes a set, so the patient view can offer the
  /// pain and effort rating. Cleared once rated or skipped.
  int? awaitingRatingForSet;

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

  /// The target in force, preferring what the sleeve says over what the host
  /// wrote. They differ after calibration, which replaces the target with the
  /// patient's own adaptive one and announces it only in `# PARAMS`.
  double get effectiveTargetDeg =>
      sleeveParams?.targetDeg ?? config.targetAngleDeg;

  /// The angle a rep must pass to count — 80% of the target, not the target.
  double get effectivePeakDeg => sleeveParams?.peakDeg ?? config.peakAngleDeg;

  double get effectiveStartDeg =>
      sleeveParams?.startDeg ?? config.startAngleDeg;

  double get effectiveFinishDeg =>
      sleeveParams?.finishDeg ?? config.finishAngleDeg;

  double get effectiveTempoMinS =>
      sleeveParams?.tempoMinS ?? config.tempoMinS;

  double get effectiveTempoMaxS =>
      sleeveParams?.tempoMaxS ?? config.tempoMaxS;

  int get effectiveRepTarget => sleeveParams?.repsPerSet ?? config.repTarget;
  int get effectiveSetCount => sleeveParams?.sets ?? config.setCount;

  int get currentSetNumber => sleeveLive?.setNumber ?? 1;

  bool get isCalibrated =>
      sleeveLive?.calibrated ?? (calibration?.isCalibrated ?? false);

  bool get isResting => sleeveLive?.resting ?? false;
  bool get isSessionDone => sleeveLive?.sessionDone ?? false;

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
  double get setProgress => effectiveRepTarget == 0
      ? 0
      : (repCount / effectiveRepTarget).clamp(0.0, 1.0);

  /// The score the patient sees: the most recent rep the device graded.
  RepComplete? get lastRep => reps.isEmpty ? null : reps.last;

  RepRow? get lastRow => repRows.isEmpty ? null : repRows.last;

  Iterable<RepRow> get countedRows => repRows.where((r) => r.counted);

  double? get meanScore => reps.isEmpty
      ? null
      : reps.map((r) => r.score).reduce((a, b) => a + b) / reps.length;

  /// Fatigue indication: median frequency falling across the set, in Hz.
  ///
  /// Negative means the trend is downwards, which is the fatigue direction.
  /// Only activated samples count — `mdf` is zero below activation, and
  /// including the rests would swamp the trend with zeros.
  ///
  /// Always null against the shipping sleeve, which reports no median
  /// frequency at all. The sleeve's own `[FT1]` comparison — [fatigueTrend] —
  /// is what the therapist view draws, and this stays for the ESP-IDF
  /// firmware, which does measure it.
  double? get mdfTrendHz {
    final pts = _trace.where((p) => p.activationOn && p.mdf > 0).toList();
    if (pts.length < 40) return null;
    final half = pts.length ~/ 2;
    double mean(Iterable<TracePoint> xs) =>
        xs.map((p) => p.mdf).reduce((a, b) => a + b) / xs.length;
    return mean(pts.skip(pts.length - half)) - mean(pts.take(half));
  }

  bool get hasGap => status?.gapOccurred ?? false;

  /// Things a therapist should be told without having to look for them.
  ///
  /// Assembled from what the sleeve reported rather than from thresholds of
  /// our own, so an alert here always traces to a line in the log.
  List<String> get alerts => [
        if (status?.inFault ?? false)
          'Sensor fault: ${status!.faultLabel}. Readings are unreliable.',
        if (hasGap)
          'A gap in the recorded stream — some of this session was not captured.',
        if (autoPaused)
          'Session auto-paused: no movement for a while.',
        if (fatigueStops > 0)
          'Fatigue stopped a set ${fatigueStops == 1 ? 'once' : '$fatigueStops times'}.',
        if (lastFatigue?.anySign ?? false) lastFatigue!.summary,
        if (_passiveCount >= 2)
          '$_passiveCount reps were not counted because the biceps was quiet — '
              'check electrode contact before assuming the arm was lifted.',
        if (!isCalibrated && sessionRequested)
          'Not calibrated. Scores and effort percentages do not mean much yet.',
      ];

  int get _passiveCount =>
      repRows.where((r) => r.outcome == RepOutcome.passive).length;

  // ── Wiring ─────────────────────────────────────────────────────────────

  final PhaseTimer _phases = PhaseTimer();
  RepState _lastRepState = RepState.ready;
  RepPhases? _lastCompletedPhases;

  void _wire() {
    _subs.add(device.linkState.listen((s) {
      linkState = s;
      _emit('link', {'state': s.name, 'label': s.label});
      notifyListeners();
    }));

    _subs.add(device.features.listen(_onFeature));
    _subs.add(device.events.listen(_onEvent));
    _subs.add(device.messages.listen(_onMessage));

    _subs.add(device.status.listen((s) {
      final previous = status;
      status = s;
      // A fault is the one status change that must reach the patient.
      if (s.inFault && previous?.faultCode != s.faultCode) {
        log.add(LoggedEvent(0, RehabEvent.fault.wire, 'Fault',
            detail: s.faultLabel));
        pendingCue = HapticPattern.fault;
      }
      _noteFault(s.inFault);
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

    final ch =
        config.agonistChannel < f.envelope.length ? config.agonistChannel : 0;
    _trace.add(TracePoint(
      tUs: f.tUs,
      angleDeg: f.elbowAngleDeg,
      envelope: f.envelope[ch],
      mdf: ch < f.mdf.length ? f.mdf[ch] : 0.0,
      activationOn: f.activationOn,
      repState: f.repState,
    ));
    while (_trace.length > traceCapacity) {
      _trace.removeFirst();
    }
    liveTraceRevision.value++;

    // The lift / hold / lower reconstruction. Fed every frame; harvested when
    // the state returns to READY, which is the moment the sleeve itself
    // decides the attempt is over.
    _phases.onFrame(f.repState, f.tUs);
    if (_lastRepState != RepState.ready && f.repState == RepState.ready) {
      _lastCompletedPhases = _phases.take();
    }
    _lastRepState = f.repState;

    _appendToRecord(f, ch);

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

  void _appendToRecord(FeatureFrame f, int channel) {
    _recordT0Us ??= f.tUs;
    final ms = ((f.tUs - _recordT0Us!) / 1000).round();
    const stepMs = 1000 ~/ recordHz;
    if (ms - _lastRecordedMs < stepMs) return;
    _lastRecordedMs = ms;
    if (_record.length >= recordCapacity) return;
    _record.add(TraceSample(
      tMs: ms,
      angleDeg: f.elbowAngleDeg,
      envelopePercent: f.envelope[channel] * 100,
      activationOn: f.activationOn,
      repState: f.repState.wire,
    ));
  }

  /// Faults are recorded as spans so the charts can shade the stretches where
  /// readings are unreliable, rather than showing a line that looks like data.
  void _noteFault(bool inFault) {
    final nowMs = _lastRecordedMs < 0 ? 0 : _lastRecordedMs;
    if (inFault && _faultOpenedMs == null) {
      _faultOpenedMs = nowMs;
    } else if (!inFault && _faultOpenedMs != null) {
      faults.add(FaultSpan(fromMs: _faultOpenedMs!, toMs: nowMs));
      _faultOpenedMs = null;
    }
  }

  // ── Events ─────────────────────────────────────────────────────────────

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
          _addCountedRow(rep, e.tUs);
          _emit('rep', rep.toJson());
        }

      case RehabEvent.repAbandoned:
        final partial = RepAbandoned.tryParse(e.payload);
        if (partial != null) {
          detail = 'peak ${partial.peakAngleDeg.toStringAsFixed(0)}°, '
              'short of ${effectivePeakDeg.toStringAsFixed(0)}°';
          repRows.add(RepRow(
            atUs: e.tUs,
            outcome: RepOutcome.partial,
            peakAngleDeg: partial.peakAngleDeg,
            durationS: 0,
            neededDeg: effectivePeakDeg,
            setNumber: currentSetNumber,
            phases: _takePhases(),
          ));
        }

      case RehabEvent.passiveSwing:
        // Worth logging prominently: it looks like a missed rep to a patient,
        // and it is the demo item that proves activation gating works. The
        // peak angle and the activation ratio arrive on the printed line, so
        // the row is created here and completed there.
        detail = 'arm moved without biceps activation — not counted';
        repRows.add(RepRow(
          atUs: e.tUs,
          outcome: RepOutcome.passive,
          peakAngleDeg: _trace.isEmpty
              ? 0
              : _trace.map((p) => p.angleDeg).reduce((a, b) => a > b ? a : b),
          durationS: 0,
          setNumber: currentSetNumber,
          phases: _takePhases(),
        ));

      case RehabEvent.setComplete:
        pendingCue = HapticPattern.setComplete;
        final set = SetComplete.parse(e.payload);
        detail = set.wasStopped
            ? 'stopped from the app'
            : '${set.repsInSet} reps in the set';
        // The rating prompt belongs here, not at session end: asking after
        // every set tracks how pain and effort move through a session, and
        // asking once at the end does not.
        awaitingRatingForSet = currentSetNumber;

      case RehabEvent.fatigueWarn:
        pendingCue = HapticPattern.rest;
        final warn = FatigueWarn.tryParse(e.payload);
        if (warn != null) {
          detail = warn.label;
          if (warn.endsSet) fatigueStops++;
        }

      case RehabEvent.fault:
        pendingCue = HapticPattern.fault;
        if (e.payload.isNotEmpty) detail = Fault.nameOf(e.payload.first);

      case RehabEvent.calibPhaseDone:
        final progress = CalibProgress.tryParse(e.payload);
        if (progress != null) {
          final phase = progress.phase;
          detail = '${phase?.label ?? 'step'} '
              '${progress.started ? 'started' : 'done'}';
          if (phase != null) {
            if (progress.finished) {
              calibrationDone.add(phase);
              calibratingPhase = null;
              if (phase == CalibPhase.failed) calibrationDone.clear();
            } else {
              calibratingPhase = phase;
            }
          }
        }

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

  RepPhases? _takePhases() {
    final p = _lastCompletedPhases ?? _phases.take();
    _lastCompletedPhases = null;
    return p;
  }

  void _addCountedRow(RepComplete rep, int tUs) {
    // If the printed line got here first, use it now.
    final pending = _freshPending();
    final row = RepRow.fromEvent(
      rep,
      tUs,
      tempoText: pending?.str('tempoText'),
      bicepsPercent: pending?.num_('bicepsPct'),
      phases: _takePhases(),
      setNumber: currentSetNumber,
      targetAngleDeg: effectiveTargetDeg,
      tempoMinS: effectiveTempoMinS,
      tempoMaxS: effectiveTempoMaxS,
    );
    if (pending != null) _pendingPrinted = null;
    repRows.add(row);
  }

  SleeveMessage? _freshPending() {
    final p = _pendingPrinted;
    if (p == null) return null;
    if (DateTime.now().difference(p.at) > printedPairingWindow) {
      _pendingPrinted = null;
      return null;
    }
    return p.message;
  }

  // ── Printed lines ──────────────────────────────────────────────────────

  void _onMessage(SleeveMessage m) {
    messages.add(m);
    while (messages.length > messageCapacity) {
      messages.removeAt(0);
    }
    messageRevision.value++;

    switch (m.kind) {
      case SleeveMessageKind.params:
        sleeveParams = SleeveParams.fromMessage(m) ?? sleeveParams;

      case SleeveMessageKind.live:
        final live = SleeveLive.fromMessage(m);
        if (live != null) {
          sleeveLive = live;
          paceOn = live.paceOn;
          autoPaused = live.paused;
        }

      case SleeveMessageKind.rep:
        // The matching event either already made the row, in which case
        // complete it, or has not arrived yet, in which case hold this line
        // for [_addCountedRow] to pick up.
        final row = lastRow;
        if (row != null && row.counted && row.tempoText == null) {
          repRows[repRows.length - 1] = row.withPrintedExtras(
            tempoText: m.str('tempoText'),
            bicepsPercent: m.num_('bicepsPct'),
          );
        } else {
          _pendingPrinted = _PendingPrinted(m);
        }

      case SleeveMessageKind.partial:
        // Completes the row the REP_ABANDONED or PASSIVE_SWING event made.
        final row = lastRow;
        if (row != null && !row.counted) {
          repRows[repRows.length - 1] = RepRow(
            atUs: row.atUs,
            outcome: m.flag('passive') ? RepOutcome.passive : row.outcome,
            peakAngleDeg: m.num_('peakDeg') ?? row.peakAngleDeg,
            durationS: row.durationS,
            compFlags: row.compFlags,
            bicepsPercent: m.num_('bicepsPct') ?? row.bicepsPercent,
            phases: row.phases,
            setNumber: row.setNumber,
            neededDeg: m.num_('neededDeg') ?? row.neededDeg,
            fatigue: row.fatigue,
          );
        }

      case SleeveMessageKind.fatigueTrend:
        final snap = FatigueSnapshot(
          rangePercent: m.num_('rangePct') ?? 100,
          effortPercent: m.num_('effortPct') ?? 100,
          timePercent: m.num_('timePct') ?? 100,
          range: m.flag('range'),
          effort: m.flag('effort'),
          slow: m.flag('slow'),
        );
        lastFatigue = snap;
        fatigueTrend.add(snap);
        // Attach to the rep it was measured against, which is the one just
        // counted — the sleeve prints this line immediately after the REP
        // line.
        final row = lastRow;
        if (row != null && row.counted && row.fatigue == null) {
          repRows[repRows.length - 1] = row.withPrintedExtras(fatigue: snap);
        }

      case SleeveMessageKind.setProgress:
        final set = m.int_('set');
        final row = lastRow;
        if (set != null && row != null && row.setNumber == null) {
          repRows[repRows.length - 1] = row.withPrintedExtras(setNumber: set);
        }

      case SleeveMessageKind.paceePhase:
        pacePhase = PacePhase.fromWord(m.str('phase') ?? '');

      case SleeveMessageKind.pause:
        autoPaused = m.flag('paused');

      case SleeveMessageKind.calibration:
        final prompt = m.str('prompt');
        if (prompt != null && prompt.isNotEmpty && !m.flag('countdown')) {
          calibrationPrompt = prompt;
        }
        if (m.flag('done') || m.flag('stopped')) calibrationPrompt = null;
        if (m.flag('begin')) {
          calibrationDone.clear();
          calibrationPrompt = null;
        }

      case SleeveMessageKind.emgTest:
        final part = m.str('part');
        if (part == 'begin') {
          emgTestLines.clear();
          emgTestRunning = true;
        }
        emgTestLines.add(m);
        if (part == 'end') emgTestRunning = false;

      case SleeveMessageKind.target:
        // The adaptive target changed. The `# PARAMS` line that follows
        // carries the new value, so nothing to do but let it through.
        break;

      case SleeveMessageKind.formFault:
      case SleeveMessageKind.paceVerdict:
      case SleeveMessageKind.sessionFlow:
      case SleeveMessageKind.other:
        break;
    }

    _emit('message', m.toJson());
    notifyListeners();
  }

  // ── Commands, with the local bookkeeping they imply ────────────────────

  Future<void> startSession() async {
    if (await device.startSession(config.exerciseId)) {
      sessionRequested = true;
      sessionStartedAt = DateTime.now();
      sessionEndedAt = null;
      _resetRecording();
      device.seq.reset();
      _emit('session', {'started': true});
      notifyListeners();
    }
  }

  Future<void> stopSession() async {
    if (await device.stopSession()) {
      sessionRequested = false;
      sessionEndedAt = DateTime.now();
      _emit('session', {'started': false, 'reps': reps.length});
      notifyListeners();
    }
  }

  void _resetRecording() {
    reps.clear();
    repRows.clear();
    log.clear();
    _trace.clear();
    _record.clear();
    ratings.clear();
    faults.clear();
    fatigueTrend.clear();
    lastFatigue = null;
    fatigueStops = 0;
    awaitingRatingForSet = null;
    _recordT0Us = null;
    _lastRecordedMs = -1000;
    _faultOpenedMs = null;
    _pendingPrinted = null;
    _phases.clear();
    _lastCompletedPhases = null;
    _lastRepState = RepState.ready;
  }

  /// Clear the recording without touching the sleeve. For starting a fresh
  /// analysis after loading a saved session into the viewer.
  void clearRecording() {
    _resetRecording();
    notifyListeners();
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
      calibrationPrompt = null;
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
  /// what comes back is the only confirmation a change took effect.
  Future<bool> setParameters(List<Uint8List> blocks) =>
      device.setConfigTags(blocks);

  /// Record the patient's pain and effort for a set.
  ///
  /// A skipped rating is stored as nulls rather than zeros: declining to say
  /// is a real answer, and a zero would read as "no pain at all" on the
  /// therapist's chart.
  void recordRating({int? pain, int? effort, int? setNumber}) {
    final n = setNumber ?? awaitingRatingForSet ?? currentSetNumber;
    ratings
      ..removeWhere((r) => r.setNumber == n)
      ..add(SetRating(setNumber: n, pain: pain, effort: effort));
    ratings.sort((a, b) => a.setNumber.compareTo(b.setNumber));
    awaitingRatingForSet = null;
    notifyListeners();
  }

  void dismissRating() {
    awaitingRatingForSet = null;
    notifyListeners();
  }

  void consumeCue() {
    pendingCue = null;
  }

  /// Everything recorded so far, as a saveable session.
  ///
  /// Callable mid-session on purpose: a therapist who has to stop early still
  /// wants the reps that happened, and a record that only existed after a
  /// clean finish would be lost exactly when the session was interesting.
  SessionRecord buildRecord({
    required String patientId,
    String note = '',
    DateTime? startedAt,
    SessionSource source = SessionSource.live,
  }) {
    final start = startedAt ?? sessionStartedAt ?? DateTime.now();
    final openFault = _faultOpenedMs;
    return SessionRecord(
      id: 's${start.microsecondsSinceEpoch}',
      patientId: patientId,
      startedAt: start,
      endedAt: sessionEndedAt,
      note: note,
      source: source,
      fatigueStops: fatigueStops,
      config: SessionConfigSnapshot(
        targetAngleDeg: effectiveTargetDeg,
        peakAngleDeg: effectivePeakDeg,
        startAngleDeg: effectiveStartDeg,
        finishAngleDeg: effectiveFinishDeg,
        tempoMinS: effectiveTempoMinS,
        tempoMaxS: effectiveTempoMaxS,
        repTarget: effectiveRepTarget,
        setCount: effectiveSetCount,
        restSeconds: sleeveParams?.restSeconds ?? config.restSeconds,
        muscleOnPercent: sleeveParams?.muscleOnPercent,
        paceOn: paceOn,
      ),
      reps: List.of(repRows),
      trace: List.of(_record),
      ratings: List.of(ratings),
      faults: [
        ...faults,
        // A fault still open at save time is closed at the end of the
        // recording rather than dropped: a session that ended *in* a fault is
        // precisely the one where the shading matters.
        if (openFault != null)
          FaultSpan(fromMs: openFault, toMs: _lastRecordedMs),
      ],
      messages: messages.map((m) => m.raw).toList(),
    );
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
        'sleeve_target_deg': effectiveTargetDeg,
        'sleeve_peak_deg': effectivePeakDeg,
        'status': status?.toJson(),
        'calibration': calibration?.toJson(),
        'calibrated': isCalibrated,
        'rep_count': repCount,
        'set_number': currentSetNumber,
        'resting': isResting,
        'auto_paused': autoPaused,
        'pace_phase': pacePhase.name,
        'reps': reps.map((r) => r.toJson()).toList(),
        'rep_rows': repRows.map((r) => r.toJson()).toList(),
        'mean_score': meanScore,
        'mdf_trend_hz': mdfTrendHz,
        'fatigue': lastFatigue?.toJson(),
        'fatigue_trend': fatigueTrend.map((f) => f.toJson()).toList(),
        'ratings': ratings.map((r) => r.toJson()).toList(),
        'alerts': alerts,
        'log': log.reversed.take(50).map((e) => e.toJson()).toList(),
        'messages': messages.reversed.take(50).map((m) => m.toJson()).toList(),
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
    liveTraceRevision.dispose();
    messageRevision.dispose();
    _bridge.close();
    super.dispose();
  }
}
