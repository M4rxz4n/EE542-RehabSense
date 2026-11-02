/// A finished session, as something that can be saved, reloaded and compared.
///
/// The viewer's "Progress over time" tab turns each saved session into one
/// point on four charts. That only works if a session is a self-contained
/// record: the thresholds in force when it ran are part of it, because a rep
/// that reached 95° means something different against a 90° target than
/// against a 120° one. A record that stored only the reps would make the
/// charts quietly meaningless the first time a therapist changed the target.
///
/// So the config snapshot is not metadata, it is data.
library;

import 'dart:convert';

import '../protocol/config_tlv.dart';
import 'rep_log.dart';

/// Pain and perceived effort, as the patient tapped them after a set.
///
/// Both 0–10, both optional: a skipped rating is a real answer and must not
/// become a zero. The therapist view draws these against the set number, and a
/// zero where the patient declined would read as "no pain at all".
class SetRating {
  const SetRating({required this.setNumber, this.pain, this.effort});

  final int setNumber;
  final int? pain;
  final int? effort;

  bool get isEmpty => pain == null && effort == null;

  Map<String, dynamic> toJson() => {
        'set': setNumber,
        if (pain != null) 'pain': pain,
        if (effort != null) 'effort': effort,
      };

  static SetRating fromJson(Map<String, dynamic> j) => SetRating(
        setNumber: (j['set'] as num?)?.toInt() ?? 1,
        pain: (j['pain'] as num?)?.toInt(),
        effort: (j['effort'] as num?)?.toInt(),
      );
}

/// A sample of the two live traces, thinned for storage.
class TraceSample {
  const TraceSample({
    required this.tMs,
    required this.angleDeg,
    required this.envelopePercent,
    required this.activationOn,
    this.repState = 0,
  });

  /// Milliseconds from the start of the recording. Stored relative so a
  /// reloaded session's charts do not depend on the device's epoch.
  final int tMs;
  final double angleDeg;

  /// %MVC, 0–150 as the sleeve reports it. Above 100 is legitimate: the
  /// normalising squeeze may simply have been gentler than the session's.
  final double envelopePercent;

  final bool activationOn;
  final int repState;

  Map<String, dynamic> toJson() => {
        't': tMs,
        'a': _round(angleDeg, 1),
        'e': _round(envelopePercent, 1),
        if (activationOn) 'on': 1,
        if (repState != 0) 's': repState,
      };

  static TraceSample fromJson(Map<String, dynamic> j) => TraceSample(
        tMs: (j['t'] as num?)?.toInt() ?? 0,
        angleDeg: (j['a'] as num?)?.toDouble() ?? 0,
        envelopePercent: (j['e'] as num?)?.toDouble() ?? 0,
        activationOn: j['on'] == 1,
        repState: (j['s'] as num?)?.toInt() ?? 0,
      );
}

double _round(double v, int places) {
  final f = <int, double>{0: 1, 1: 10, 2: 100}[places] ?? 1;
  return (v * f).roundToDouble() / f;
}

/// A fault: a moment a sensor stopped answering. Readings inside one are
/// unreliable, which is why the charts shade them rather than hiding them.
class FaultSpan {
  const FaultSpan({required this.fromMs, required this.toMs});

  final int fromMs;
  final int toMs;

  Map<String, dynamic> toJson() => {'from': fromMs, 'to': toMs};

  static FaultSpan fromJson(Map<String, dynamic> j) => FaultSpan(
        fromMs: (j['from'] as num?)?.toInt() ?? 0,
        toMs: (j['to'] as num?)?.toInt() ?? 0,
      );
}

/// The thresholds a session ran under. Without these its numbers cannot be
/// compared with another session's.
class SessionConfigSnapshot {
  const SessionConfigSnapshot({
    required this.targetAngleDeg,
    required this.peakAngleDeg,
    required this.startAngleDeg,
    required this.finishAngleDeg,
    required this.tempoMinS,
    required this.tempoMaxS,
    required this.repTarget,
    required this.setCount,
    required this.restSeconds,
    this.muscleOnPercent,
    this.paceOn,
  });

  final double targetAngleDeg;

  /// The angle a rep must actually pass — 80% of the target, not the target.
  /// Stored rather than derived: the fraction is a firmware constant today and
  /// a stored session must not silently change meaning if it ever moves.
  final double peakAngleDeg;

  final double startAngleDeg;
  final double finishAngleDeg;
  final double tempoMinS;
  final double tempoMaxS;
  final int repTarget;
  final int setCount;
  final int restSeconds;
  final double? muscleOnPercent;
  final bool? paceOn;

  factory SessionConfigSnapshot.fromRuntime(RuntimeConfig c, {bool? paceOn}) =>
      SessionConfigSnapshot(
        targetAngleDeg: c.targetAngleDeg,
        peakAngleDeg: c.peakAngleDeg,
        startAngleDeg: c.startAngleDeg,
        finishAngleDeg: c.finishAngleDeg,
        tempoMinS: c.tempoMinS,
        tempoMaxS: c.tempoMaxS,
        repTarget: c.repTarget,
        setCount: c.setCount,
        restSeconds: c.restSeconds,
        paceOn: paceOn,
      );

  Map<String, dynamic> toJson() => {
        'target_angle_deg': targetAngleDeg,
        'peak_angle_deg': peakAngleDeg,
        'start_angle_deg': startAngleDeg,
        'finish_angle_deg': finishAngleDeg,
        'tempo_min_s': tempoMinS,
        'tempo_max_s': tempoMaxS,
        'rep_target': repTarget,
        'set_count': setCount,
        'rest_seconds': restSeconds,
        if (muscleOnPercent != null) 'muscle_on_percent': muscleOnPercent,
        if (paceOn != null) 'pace_on': paceOn,
      };

  static SessionConfigSnapshot fromJson(Map<String, dynamic> j) =>
      SessionConfigSnapshot(
        targetAngleDeg: (j['target_angle_deg'] as num?)?.toDouble() ?? 90,
        peakAngleDeg: (j['peak_angle_deg'] as num?)?.toDouble() ??
            ((j['target_angle_deg'] as num?)?.toDouble() ?? 90) * 0.8,
        startAngleDeg: (j['start_angle_deg'] as num?)?.toDouble() ?? 15,
        finishAngleDeg: (j['finish_angle_deg'] as num?)?.toDouble() ?? 10,
        tempoMinS: (j['tempo_min_s'] as num?)?.toDouble() ?? 3,
        tempoMaxS: (j['tempo_max_s'] as num?)?.toDouble() ?? 8,
        repTarget: (j['rep_target'] as num?)?.toInt() ?? 10,
        setCount: (j['set_count'] as num?)?.toInt() ?? 3,
        restSeconds: (j['rest_seconds'] as num?)?.toInt() ?? 60,
        muscleOnPercent: (j['muscle_on_percent'] as num?)?.toDouble(),
        paceOn: j['pace_on'] as bool?,
      );
}

/// Everything about one session, as saved.
class SessionRecord {
  SessionRecord({
    required this.id,
    required this.patientId,
    required this.startedAt,
    required this.config,
    this.note = '',
    this.endedAt,
    List<RepRow>? reps,
    List<TraceSample>? trace,
    List<SetRating>? ratings,
    List<FaultSpan>? faults,
    List<String>? messages,
    this.fatigueStops = 0,
    this.source = SessionSource.live,
  })  : reps = reps ?? [],
        trace = trace ?? [],
        ratings = ratings ?? [],
        faults = faults ?? [],
        messages = messages ?? [];

  final String id;

  /// Which patient this belongs to. The viewer supports several because a
  /// single sleeve and a single laptop get shared between them in a clinic,
  /// and merging two people's progress into one chart is worse than useless.
  final String patientId;

  final DateTime startedAt;
  DateTime? endedAt;

  /// Free text the therapist adds when saving — "new electrode spot", "first
  /// session after the weekend". Short, and the thing that makes a saved list
  /// navigable six weeks later.
  String note;

  final SessionConfigSnapshot config;
  final List<RepRow> reps;
  final List<TraceSample> trace;
  final List<SetRating> ratings;
  final List<FaultSpan> faults;

  /// The printed lines, kept verbatim. The record's audit trail: when a number
  /// on a chart looks wrong, this is what says why.
  final List<String> messages;

  final int fatigueStops;
  final SessionSource source;

  // ── Derived ──────────────────────────────────────────────────────────

  Iterable<RepRow> get counted => reps.where((r) => r.counted);
  Iterable<RepRow> get partials => reps.where((r) => !r.counted);

  int get countedCount => counted.length;
  int get partialCount => partials.length;
  int get flaggedCount => counted.where((r) => r.flagged).length;
  int get passiveCount =>
      reps.where((r) => r.outcome == RepOutcome.passive).length;

  Duration get duration =>
      (endedAt ?? DateTime.now()).difference(startedAt);

  double? get meanPeakDeg => _mean(counted.map((r) => r.peakAngleDeg));
  double? get bestPeakDeg =>
      counted.isEmpty ? null : counted.map((r) => r.peakAngleDeg).reduce(_max);
  double? get worstPeakDeg =>
      counted.isEmpty ? null : counted.map((r) => r.peakAngleDeg).reduce(_min);

  double? get meanScore =>
      _mean(counted.where((r) => r.score != null).map((r) => r.score!.toDouble()));

  /// Reps that reached the full therapist target, not merely the 80% criterion
  /// a rep counts at. This is the number the sleeve's own adaptive target
  /// adjusts on, so it is the one worth tracking.
  int get atTargetCount =>
      counted.where((r) => r.peakAngleDeg >= config.targetAngleDeg).length;

  double? get atTargetFraction =>
      countedCount == 0 ? null : atTargetCount / countedCount;

  /// Share of counted reps whose lift, hold and lower together landed in the
  /// controlled band. Null when no rep has a reconstructed split.
  double? get controlledPaceFraction {
    final withPhases = counted.where((r) => r.phases != null).toList();
    if (withPhases.isEmpty) return null;
    final ok = withPhases.where((r) => r.phases!.isControlled).length;
    return ok / withPhases.length;
  }

  double? medianPhase(double Function(RepPhases) pick) {
    final xs = counted
        .where((r) => r.phases != null)
        .map((r) => pick(r.phases!))
        .toList()
      ..sort();
    if (xs.isEmpty) return null;
    final mid = xs.length ~/ 2;
    return xs.length.isOdd ? xs[mid] : (xs[mid - 1] + xs[mid]) / 2;
  }

  double? get medianLiftS => medianPhase((p) => p.liftS);
  double? get medianHoldS => medianPhase((p) => p.holdS);
  double? get medianLowerS => medianPhase((p) => p.lowerS);

  /// Typical effort while the arm rests near straight, and while it is bent
  /// past 40°. Rest should sit near zero; a rest level well above it means the
  /// arm was not relaxed or the gain is high.
  double? get restEnvelopePercent => _median(trace
      .where((s) => s.angleDeg < config.startAngleDeg && !s.activationOn)
      .map((s) => s.envelopePercent));

  double? get curlEnvelopePercent => _median(
      trace.where((s) => s.angleDeg > 40).map((s) => s.envelopePercent));

  /// Pain and effort averaged across the sets that were rated.
  double? get meanPain =>
      _mean(ratings.where((r) => r.pain != null).map((r) => r.pain!.toDouble()));
  double? get meanEffort => _mean(
      ratings.where((r) => r.effort != null).map((r) => r.effort!.toDouble()));

  /// How often each form fault happened.
  Map<int, int> get flagCounts {
    final out = <int, int>{};
    for (final r in counted) {
      for (var bit = 0; bit < 8; bit++) {
        final mask = 1 << bit;
        if (r.compFlags & mask != 0) {
          out[mask] = (out[mask] ?? 0) + 1;
        }
      }
    }
    return out;
  }

  // ── Serialisation ────────────────────────────────────────────────────

  Map<String, dynamic> toJson() => {
        'id': id,
        'patient_id': patientId,
        'started_at': startedAt.toIso8601String(),
        if (endedAt != null) 'ended_at': endedAt!.toIso8601String(),
        'note': note,
        'source': source.name,
        'fatigue_stops': fatigueStops,
        'config': config.toJson(),
        'reps': reps.map((r) => r.toJson()).toList(),
        'trace': trace.map((t) => t.toJson()).toList(),
        'ratings': ratings.map((r) => r.toJson()).toList(),
        'faults': faults.map((f) => f.toJson()).toList(),
        'messages': messages,
      };

  static SessionRecord fromJson(Map<String, dynamic> j) => SessionRecord(
        id: j['id'] as String? ?? '',
        patientId: j['patient_id'] as String? ?? 'default',
        startedAt:
            DateTime.tryParse(j['started_at'] as String? ?? '') ?? DateTime.now(),
        endedAt: DateTime.tryParse(j['ended_at'] as String? ?? ''),
        note: j['note'] as String? ?? '',
        source: SessionSource.values.firstWhere(
          (s) => s.name == j['source'],
          orElse: () => SessionSource.live,
        ),
        fatigueStops: (j['fatigue_stops'] as num?)?.toInt() ?? 0,
        config: SessionConfigSnapshot.fromJson(
            (j['config'] as Map?)?.cast<String, dynamic>() ?? const {}),
        reps: [
          for (final r in (j['reps'] as List? ?? const []))
            RepRow.fromJson((r as Map).cast<String, dynamic>()),
        ],
        trace: [
          for (final t in (j['trace'] as List? ?? const []))
            TraceSample.fromJson((t as Map).cast<String, dynamic>()),
        ],
        ratings: [
          for (final r in (j['ratings'] as List? ?? const []))
            SetRating.fromJson((r as Map).cast<String, dynamic>()),
        ],
        faults: [
          for (final f in (j['faults'] as List? ?? const []))
            FaultSpan.fromJson((f as Map).cast<String, dynamic>()),
        ],
        messages: [
          for (final m in (j['messages'] as List? ?? const [])) m as String,
        ],
      );

  /// The rep log as CSV, one row per attempt.
  ///
  /// Columns match the viewer's rep table so a CSV from either tool lands in
  /// the same spreadsheet. Reconstructed phase columns are named as such in
  /// the header, because a column called "lift_s" in a file that outlives this
  /// conversation will otherwise be read as a device measurement.
  String toCsv() {
    final rows = <List<String>>[
      [
        'rep',
        'time_s',
        'set',
        'outcome',
        'peak_deg',
        'duration_s',
        'rom_percent',
        'score',
        'tempo',
        'biceps_percent',
        'lift_s_reconstructed',
        'hold_s_reconstructed',
        'lower_s_reconstructed',
        'flags',
      ],
    ];
    final t0 = reps.isEmpty ? 0 : reps.first.atUs;
    for (final r in reps) {
      rows.add([
        r.index?.toString() ?? '',
        ((r.atUs - t0) / 1e6).toStringAsFixed(1),
        r.setNumber?.toString() ?? '',
        r.outcome.shortLabel,
        r.peakAngleDeg.toStringAsFixed(1),
        r.durationS.toStringAsFixed(2),
        r.romPercent?.toString() ?? '',
        r.score?.toString() ?? '',
        r.tempoText ?? '',
        r.bicepsPercent?.toStringAsFixed(0) ?? '',
        r.phases?.liftS.toStringAsFixed(2) ?? '',
        r.phases?.holdS.toStringAsFixed(2) ?? '',
        r.phases?.lowerS.toStringAsFixed(2) ?? '',
        r.compensations.join('|'),
      ]);
    }
    return rows.map((r) => r.map(_csvCell).join(',')).join('\n');
  }

  static String _csvCell(String v) =>
      v.contains(RegExp('[",\n]')) ? '"${v.replaceAll('"', '""')}"' : v;

  String toPrettyJson() => const JsonEncoder.withIndent('  ').convert(toJson());
}

enum SessionSource {
  /// Recorded over BLE from the sleeve.
  live,

  /// Replayed from a Serial Monitor log.
  replay,

  /// Generated by the built-in simulator. Labelled so it can never be
  /// mistaken for a real session on a progress chart.
  demo,
}

double _max(double a, double b) => a > b ? a : b;
double _min(double a, double b) => a < b ? a : b;

double? _mean(Iterable<double> xs) {
  final l = xs.toList();
  if (l.isEmpty) return null;
  return l.reduce((a, b) => a + b) / l.length;
}

double? _median(Iterable<double> xs) {
  final l = xs.toList()..sort();
  if (l.isEmpty) return null;
  final mid = l.length ~/ 2;
  return l.length.isOdd ? l[mid] : (l[mid - 1] + l[mid]) / 2;
}
