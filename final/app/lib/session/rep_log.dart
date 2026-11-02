/// The rep log: one row per attempt, counted or not.
///
/// The session viewer's rep table is the artefact this exists to feed, and its
/// hardest requirement is honesty about where each number came from. Three
/// different provenances end up in one row:
///
/// - **From the device.** Score, range, peak angle, duration and compensation
///   flags arrive in `EVT_REP_COMPLETE`. These are final. The app displays
///   them and never recomputes them.
/// - **From the device's printed line.** The tempo verdict in words, and the
///   share of the lift the biceps was working. Real measurements, but rounded
///   for a human reader, so they are only ever shown and never computed with.
/// - **Reconstructed here.** The lift / hold / lower split. The sleeve reports
///   one total duration; the split comes from timing `rep_state` across the
///   live feature stream at 20 Hz. It is marked [phasesReconstructed] so no
///   display can pass it off as a device measurement.
///
/// A partial rep is a row with no index and no score. It is shown because a
/// patient who sees nothing after a hard attempt concludes the device is
/// broken, which is a worse outcome than a dash in a table.
library;

import '../protocol/commands.dart';
import '../protocol/enums.dart';

enum RepOutcome {
  /// Counted, reached the target, no flags.
  onTarget,

  /// Counted, but the pace was outside the window.
  countedPaceOff,

  /// Counted, with a form flag against it. Still counted — a patient who gets
  /// no credit for a hard-won compensated rep learns the device is broken,
  /// not that their form needs work.
  flagged,

  /// Started and came back down short of the criterion. Not counted.
  partial,

  /// The arm rose with the biceps quiet. Not counted, and the one case a
  /// motion-only device cannot catch.
  passive;

  bool get counted =>
      this == onTarget || this == countedPaceOff || this == flagged;

  String get label => switch (this) {
        onTarget => 'On target',
        countedPaceOff => 'Counted · pace off',
        flagged => 'Flagged',
        partial => 'Partial · stopped short',
        passive => 'Not counted · arm lifted for you',
      };

  String get shortLabel => switch (this) {
        onTarget => 'on target',
        countedPaceOff => 'pace off',
        flagged => 'flagged',
        partial => 'partial',
        passive => 'passive',
      };
}

/// Lift, hold and lower seconds, reconstructed from the rep-state stream.
class RepPhases {
  const RepPhases({
    required this.liftS,
    required this.holdS,
    required this.lowerS,
  });

  final double liftS;
  final double holdS;
  final double lowerS;

  double get totalS => liftS + holdS + lowerS;

  /// The viewer's "controlled pace" band for the three phases together.
  ///
  /// Wider than the sleeve's own tempo window on purpose: the sleeve scores
  /// the whole rep against 3–8 s, while this asks the softer question of
  /// whether the movement was deliberate rather than whether it scored well.
  static const double controlledMinS = 4.0;
  static const double controlledMaxS = 9.0;

  bool get isControlled =>
      totalS >= controlledMinS && totalS <= controlledMaxS;

  Map<String, dynamic> toJson() => {
        'lift_s': liftS,
        'hold_s': holdS,
        'lower_s': lowerS,
      };

  static RepPhases? fromJson(Map<String, dynamic>? j) => j == null
      ? null
      : RepPhases(
          liftS: (j['lift_s'] as num?)?.toDouble() ?? 0,
          holdS: (j['hold_s'] as num?)?.toDouble() ?? 0,
          lowerS: (j['lower_s'] as num?)?.toDouble() ?? 0,
        );
}

class RepRow {
  RepRow({
    required this.atUs,
    required this.outcome,
    this.index,
    this.score,
    this.romPercent,
    required this.peakAngleDeg,
    required this.durationS,
    this.compFlags = 0,
    this.tempoText,
    this.bicepsPercent,
    this.phases,
    this.setNumber,
    this.neededDeg,
    this.fatigue,
  });

  /// Device time, microseconds. The session's own clock; wall time comes from
  /// the host offset and is only ever used for display.
  final int atUs;

  final RepOutcome outcome;

  /// 1-based within the set. Null for anything not counted — a partial
  /// consumes no number, which is why the table shows a dash.
  final int? index;

  /// 0–100 as the device graded it. Null when not counted.
  final int? score;

  /// Peak angle as a percentage of the target.
  final int? romPercent;

  final double peakAngleDeg;
  final double durationS;
  final int compFlags;

  /// "ok", "too fast" or "slow", in the sleeve's own words. From the printed
  /// line; absent if that line was missed.
  final String? tempoText;

  /// Share of the lift the biceps was actually working. The `[FC2]`
  /// criterion. From the printed line only.
  final double? bicepsPercent;

  /// Reconstructed here, not measured by the device. See the library comment.
  final RepPhases? phases;

  final int? setNumber;

  /// For a partial: the angle it needed to reach.
  final double? neededDeg;

  /// The `[FT1]` comparison recorded against this rep, if the line arrived.
  final FatigueSnapshot? fatigue;

  bool get counted => outcome.counted;
  bool get flagged => compFlags != 0 || outcome == RepOutcome.flagged;
  List<String> get compensations => compNames(compFlags);
  bool get phasesReconstructed => phases != null;

  /// Why this rep got the result it did, in plain words.
  ///
  /// Assembled rather than stored, because the explanation has to stay true
  /// when a field is missing — which happens whenever a printed line was
  /// dropped, and happened constantly before the firmware's queueing fix.
  List<String> get why {
    final out = <String>[];
    switch (outcome) {
      case RepOutcome.passive:
        out.add('The arm reached ${peakAngleDeg.round()}°, but the biceps was '
            'working for only ${bicepsPercent?.round() ?? 0}% of the lift. '
            'It looked like the arm was lifted for you.');
      case RepOutcome.partial:
        if (neededDeg != null) {
          out.add('Reached ${peakAngleDeg.round()}°, short of the '
              '${neededDeg!.round()}° a rep has to pass.');
        } else {
          out.add('Came back down before passing the target angle.');
        }
      case RepOutcome.onTarget:
      case RepOutcome.countedPaceOff:
      case RepOutcome.flagged:
        if (romPercent != null) {
          out.add('Reached ${peakAngleDeg.round()}° — $romPercent% of the '
              'target.');
        }
        if (tempoText != null && tempoText != 'ok') {
          out.add('Pace ${durationS.toStringAsFixed(1)} s, judged '
              '"$tempoText".');
        }
    }
    out.addAll(compAdviceFor(compFlags));
    if (fatigue != null && fatigue!.anySign) {
      out.add(fatigue!.summary);
    }
    return out;
  }

  /// Fill in the fields that arrive only on the printed line.
  ///
  /// Needed because the event and the line are two notifications and arrive in
  /// either order: the firmware prints first but queues events ahead of lines,
  /// so the event usually wins the race. Whichever lands first creates the
  /// row; this completes it.
  RepRow withPrintedExtras({
    String? tempoText,
    double? bicepsPercent,
    int? setNumber,
    FatigueSnapshot? fatigue,
    RepOutcome? outcome,
  }) =>
      RepRow(
        atUs: atUs,
        outcome: outcome ?? this.outcome,
        index: index,
        score: score,
        romPercent: romPercent,
        peakAngleDeg: peakAngleDeg,
        durationS: durationS,
        compFlags: compFlags,
        tempoText: tempoText ?? this.tempoText,
        bicepsPercent: bicepsPercent ?? this.bicepsPercent,
        phases: phases,
        setNumber: setNumber ?? this.setNumber,
        neededDeg: neededDeg,
        fatigue: fatigue ?? this.fatigue,
      );

  Map<String, dynamic> toJson() => {
        'at_us': atUs,
        'outcome': outcome.name,
        if (index != null) 'index': index,
        if (score != null) 'score': score,
        if (romPercent != null) 'rom_percent': romPercent,
        'peak_angle_deg': peakAngleDeg,
        'duration_s': durationS,
        'comp_flags': compFlags,
        if (tempoText != null) 'tempo_text': tempoText,
        if (bicepsPercent != null) 'biceps_percent': bicepsPercent,
        if (phases != null) 'phases': phases!.toJson(),
        if (setNumber != null) 'set': setNumber,
        if (neededDeg != null) 'needed_deg': neededDeg,
        if (fatigue != null) 'fatigue': fatigue!.toJson(),
      };

  static RepRow fromJson(Map<String, dynamic> j) => RepRow(
        atUs: (j['at_us'] as num?)?.toInt() ?? 0,
        outcome: RepOutcome.values.firstWhere(
          (o) => o.name == j['outcome'],
          orElse: () => RepOutcome.onTarget,
        ),
        index: (j['index'] as num?)?.toInt(),
        score: (j['score'] as num?)?.toInt(),
        romPercent: (j['rom_percent'] as num?)?.toInt(),
        peakAngleDeg: (j['peak_angle_deg'] as num?)?.toDouble() ?? 0,
        durationS: (j['duration_s'] as num?)?.toDouble() ?? 0,
        compFlags: (j['comp_flags'] as num?)?.toInt() ?? 0,
        tempoText: j['tempo_text'] as String?,
        bicepsPercent: (j['biceps_percent'] as num?)?.toDouble(),
        phases: RepPhases.fromJson(j['phases'] as Map<String, dynamic>?),
        setNumber: (j['set'] as num?)?.toInt(),
        neededDeg: (j['needed_deg'] as num?)?.toDouble(),
        fatigue:
            FatigueSnapshot.fromJson(j['fatigue'] as Map<String, dynamic>?),
      );

  /// Build a counted row from the device's own event, with the extras from the
  /// matching printed line if it arrived.
  static RepRow fromEvent(
    RepComplete rep,
    int atUs, {
    String? tempoText,
    double? bicepsPercent,
    RepPhases? phases,
    int? setNumber,
    double? targetAngleDeg,
    double tempoMinS = 3.0,
    double tempoMaxS = 8.0,
    FatigueSnapshot? fatigue,
  }) {
    final paceOff = rep.tempoS < tempoMinS || rep.tempoS > tempoMaxS;
    final reachedTarget =
        targetAngleDeg == null || rep.peakAngleDeg >= targetAngleDeg;

    final outcome = rep.flagged
        ? RepOutcome.flagged
        : paceOff
            ? RepOutcome.countedPaceOff
            : reachedTarget
                ? RepOutcome.onTarget
                : RepOutcome.countedPaceOff;

    return RepRow(
      atUs: atUs,
      outcome: outcome,
      index: rep.index,
      score: rep.score,
      romPercent: (rep.romFraction * 100).round(),
      peakAngleDeg: rep.peakAngleDeg,
      durationS: rep.tempoS,
      compFlags: rep.compFlags,
      tempoText: tempoText,
      bicepsPercent: bicepsPercent,
      phases: phases,
      setNumber: setNumber,
      fatigue: fatigue,
    );
  }
}

/// One `[FT1]` comparison: the latest reps against the session's first three.
///
/// 100% means no change. The sleeve counts a sign when range falls below 85%,
/// effort per degree rises above 125%, or duration rises above 140%.
class FatigueSnapshot {
  const FatigueSnapshot({
    required this.rangePercent,
    required this.effortPercent,
    required this.timePercent,
    required this.range,
    required this.effort,
    required this.slow,
  });

  final double rangePercent;
  final double effortPercent;
  final double timePercent;
  final bool range;
  final bool effort;
  final bool slow;

  int get signs => (range ? 1 : 0) + (effort ? 1 : 0) + (slow ? 1 : 0);
  bool get anySign => signs > 0;

  /// The sleeve's own thresholds, so a chart draws the lines the device judges
  /// by rather than lines of its own invention. Defined once, in the protocol
  /// layer, beside the event that reports against them.
  static const double rangeThresholdPercent = FatigueThresholds.range;
  static const double effortThresholdPercent = FatigueThresholds.effort;
  static const double timeThresholdPercent = FatigueThresholds.time;

  String get summary {
    if (!anySign) return 'No sign of fatigue yet.';
    final parts = [
      if (range) 'range down to ${rangePercent.round()}%',
      if (effort) 'effort up to ${effortPercent.round()}%',
      if (slow) 'time up to ${timePercent.round()}%',
    ];
    return 'Fatigue: ${parts.join(', ')} against the first reps.';
  }

  Map<String, dynamic> toJson() => {
        'range_percent': rangePercent,
        'effort_percent': effortPercent,
        'time_percent': timePercent,
        'range': range,
        'effort': effort,
        'slow': slow,
      };

  static FatigueSnapshot? fromJson(Map<String, dynamic>? j) => j == null
      ? null
      : FatigueSnapshot(
          rangePercent: (j['range_percent'] as num?)?.toDouble() ?? 100,
          effortPercent: (j['effort_percent'] as num?)?.toDouble() ?? 100,
          timePercent: (j['time_percent'] as num?)?.toDouble() ?? 100,
          range: j['range'] == true,
          effort: j['effort'] == true,
          slow: j['slow'] == true,
        );
}

/// Times the rep-state stream to recover the lift / hold / lower split.
///
/// The sleeve reports one duration per rep. The split is visible only in the
/// `rep_state` field of the feature frames, so this accumulates time in each
/// state and hands over a [RepPhases] when the rep ends.
///
/// Two things it deliberately does not do. It does not use wall time — the
/// frame timestamps are the device's own clock, which is never adjusted, so
/// they are the only consistent measure. And it does not interpolate: at 20 Hz
/// the quantisation is 50 ms, which is a twentieth of a slow curl and well
/// inside the rounding the sleeve already applies to the printed duration.
class PhaseTimer {
  double _liftS = 0;
  double _holdS = 0;
  double _lowerS = 0;
  RepState _state = RepState.ready;
  int? _lastUs;

  /// Feed every feature frame, in order.
  void onFrame(RepState state, int tUs) {
    final last = _lastUs;
    _lastUs = tUs;

    if (last != null && tUs > last) {
      final dt = (tUs - last) / 1e6;
      // A gap this long means dropped frames or a reconnection, not a long
      // phase. Attributing it would quietly inflate whichever phase happened
      // to be current.
      if (dt < 1.0) {
        if (_state.isLift) {
          _liftS += dt;
        } else if (_state.isHold) {
          _holdS += dt;
        } else if (_state.isLower) {
          _lowerS += dt;
        }
      }
    }

    // Returning to READY ends the attempt; the caller takes the result.
    if (state == RepState.ready && _state != RepState.ready) {
      _state = state;
      return;
    }
    _state = state;
  }

  /// The split for the attempt just finished, or null if nothing was timed.
  RepPhases? take() {
    if (_liftS == 0 && _holdS == 0 && _lowerS == 0) return null;
    final p = RepPhases(liftS: _liftS, holdS: _holdS, lowerS: _lowerS);
    reset();
    return p;
  }

  void reset() {
    _liftS = 0;
    _holdS = 0;
    _lowerS = 0;
  }

  void clear() {
    reset();
    _state = RepState.ready;
    _lastUs = null;
  }
}
