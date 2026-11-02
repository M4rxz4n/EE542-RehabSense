/// The therapist's dashboard: what is happening now, and what to do about it.
///
/// A port of the session viewer's Therapist tab. The patient view answers "am
/// I doing this right". This one answers a different question — "is this
/// prescription working, and is it safe to carry on" — and that is why it is a
/// separate screen rather than more numbers on the patient's.
///
/// ## Alerts come from the sleeve, not from thresholds invented here
///
/// Every line in the alert band traces to something the device reported: a
/// fault code, a fatigue event, a passive-lift rejection, a stream gap. The app
/// adds no clinical judgement of its own. That restraint is the point — an
/// alert the firmware cannot explain is an alert nobody can act on, and a
/// therapist who learns the warnings are guesswork stops reading them.
///
/// ## Prescription against performance
///
/// The prescription is the sleeve's current settings, read back from it, not
/// what the app last tried to write. Those differ in one case that matters:
/// calibration replaces the target angle with the patient's own adaptive one,
/// and announces it only in a printed line. A screen that showed the written
/// value would tell a therapist their 110° target was in force when the sleeve
/// had quietly eased it to 95°.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../protocol/enums.dart';
import '../session/rep_log.dart';
import '../session/session_record.dart';
import '../session/session_state.dart';
import 'charts/chart_kit.dart';
import 'charts/time_series.dart';
import 'charts/trends.dart';
import 'theme.dart';

class TherapistScreen extends StatelessWidget {
  const TherapistScreen({super.key, required this.state});

  final SessionState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 28),
            children: [
              _Alerts(state: state),
              _LiveStrip(state: state),
              _LiveCharts(state: state),
              _FatigueCard(state: state),
              _PainEffortCard(state: state),
              _PrescriptionCard(state: state),
              _FlagsCard(state: state),
            ],
          ),
        );
      },
    );
  }
}

/// What a therapist should be told without having to look for it.
class _Alerts extends StatelessWidget {
  const _Alerts({required this.state});

  final SessionState state;

  @override
  Widget build(BuildContext context) {
    final alerts = state.alerts;
    if (alerts.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Row(
          children: [
            const Icon(Icons.check_circle_outline,
                size: 17, color: RehabColors.good),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Nothing flagged. The sleeve has reported no faults, '
                  'fatigue or rejected reps.',
                  style: RehabText.body.copyWith(fontSize: 12.5)),
            ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: RehabColors.warn.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: RehabColors.warn.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.error_outline, size: 16, color: RehabColors.warn),
              const SizedBox(width: 7),
              Text('${alerts.length} TO LOOK AT',
                  style: RehabText.label.copyWith(color: RehabColors.warn)),
            ],
          ),
          const SizedBox(height: 8),
          for (final a in alerts)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Text('· $a', style: RehabText.body.copyWith(fontSize: 13)),
            ),
        ],
      ),
    );
  }
}

/// State, set, counts and the pace phase, in one line each.
class _LiveStrip extends StatelessWidget {
  const _LiveStrip({required this.state});

  final SessionState state;

  @override
  Widget build(BuildContext context) {
    final s = state;
    final feature = s.liveFeature.value;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          StatTile(
            label: 'Sleeve',
            value: s.autoPaused
                ? 'Paused'
                : s.isResting
                    ? 'Resting'
                    : s.isSessionDone
                        ? 'Done'
                        : (s.status?.stateLabel ?? s.linkState.label),
            detail: s.isCalibrated ? 'calibrated' : 'not calibrated',
            grade: s.isCalibrated ? TileGrade.good : TileGrade.warn,
          ),
          StatTile(
            label: 'Set',
            value: '${s.currentSetNumber}',
            unit: '/ ${s.effectiveSetCount}',
            detail: '${s.repCount} of ${s.effectiveRepTarget} reps',
          ),
          StatTile(
            label: 'Counted',
            value: '${s.countedRows.length}',
            detail: '${s.repRows.length - s.countedRows.length} not counted',
          ),
          StatTile(
            label: 'Elbow now',
            value: (feature?.elbowAngleDeg ?? 0).toStringAsFixed(0),
            unit: '°',
            detail: 'counts above ${s.effectivePeakDeg.round()}°',
          ),
          if (s.paceOn)
            StatTile(
              label: 'Guided pace',
              value: s.pacePhase == PacePhase.off
                  ? 'on'
                  : s.pacePhase.label.split(',').first,
              detail: s.pacePhase.feel.isEmpty
                  ? 'beats on the motor'
                  : s.pacePhase.feel,
            ),
          if (s.status != null)
            StatTile(
              label: 'Battery',
              value: '${s.status!.batteryPct}',
              unit: '%',
              grade: s.status!.batteryPct > 20
                  ? TileGrade.neutral
                  : TileGrade.bad,
            ),
        ],
      ),
    );
  }
}

/// The last thirty seconds, as two panels on one time axis.
class _LiveCharts extends StatelessWidget {
  const _LiveCharts({required this.state});

  final SessionState state;

  /// The live window as [TraceSample]s, so the same painter serves the live
  /// and the recorded charts. Built at paint time rather than held.
  List<TraceSample> _samples() {
    final pts = state.trace.toList();
    if (pts.isEmpty) return const [];
    final t0 = pts.first.tUs;
    final ch = state.config.agonistChannel;
    return [
      for (final p in pts)
        TraceSample(
          tMs: ((p.tUs - t0) / 1000).round(),
          angleDeg: p.angleDeg,
          envelopePercent: p.envelope * 100,
          activationOn: p.activationOn,
          repState: p.repState.wire,
        ),
    ]..removeWhere((_) => ch < 0);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ChartCard(
          title: 'Elbow angle, last 30 seconds',
          subtitle: 'The dashed line is the angle a rep must reach to count.',
          legend: [
            const LegendItem('Elbow angle', Color(0xFF2F9FD4)),
            LegendItem('Counts above ${state.effectivePeakDeg.round()}°',
                RehabColors.good,
                dashed: true),
          ],
          child: LiveTraceChart(
            revision: state.liveTraceRevision,
            samples: _samples,
            value: (s) => s.angleDeg,
            color: ChartPalette.series[0],
            yMax: math.max(120, state.effectiveTargetDeg * 1.25),
            yLabel: (v) => '${v.toStringAsFixed(0)}°',
            thresholds: [
              (state.effectivePeakDeg, RehabColors.good, 'counts above'),
            ],
            height: 150,
          ),
        ),
        ChartCard(
          title: 'Biceps effort, last 30 seconds',
          subtitle: 'The same window as above. The bar along the bottom marks '
              'where the sleeve judged the muscle to be working — a rep needs '
              'that, which is what rejects an arm being lifted for the patient.',
          legend: const [
            LegendItem('Biceps effort', Color(0xFFDE6A45)),
            LegendItem('Muscle working', RehabColors.muscle),
          ],
          child: LiveTraceChart(
            revision: state.liveTraceRevision,
            samples: _samples,
            value: (s) => s.envelopePercent,
            color: ChartPalette.series[1],
            yMax: 150,
            yLabel: (v) => '${v.toStringAsFixed(0)}%',
            shadeActivation: true,
            height: 130,
          ),
        ),
      ],
    );
  }
}

class _FatigueCard extends StatelessWidget {
  const _FatigueCard({required this.state});

  final SessionState state;

  @override
  Widget build(BuildContext context) {
    return ChartCard(
      title: 'Fatigue trend',
      subtitle: 'After each rep the sleeve compares the latest reps with the '
          'session\'s first three. 100% means no change. The dashed lines are '
          'the sleeve\'s own thresholds, so this chart and the device always '
          'agree about when a sign was counted.',
      legend: state.fatigueTrend.isEmpty ? const [] : fatigueLegend(),
      footer: state.lastFatigue == null
          ? null
          : Text(state.lastFatigue!.summary,
              style: RehabText.body.copyWith(
                fontSize: 12.5,
                color: state.lastFatigue!.anySign
                    ? RehabColors.warn
                    : RehabColors.good,
              )),
      child: FatigueTrendChart(snapshots: state.fatigueTrend),
    );
  }
}

/// Pain and perceived effort, as the patient reported them after each set.
class _PainEffortCard extends StatelessWidget {
  const _PainEffortCard({required this.state});

  final SessionState state;

  @override
  Widget build(BuildContext context) {
    final rated = state.ratings.where((r) => !r.isEmpty).toList();

    return ChartCard(
      title: 'Pain and effort',
      subtitle: 'What the patient tapped after each set, 0–10. A gap is a set '
          'they declined to rate, which is not the same as a zero and is drawn '
          'as a gap rather than a point on the floor.',
      legend: const [
        LegendItem('Pain', Color(0xFFDE6A45)),
        LegendItem('Effort', Color(0xFF2F9FD4)),
      ],
      child: rated.isEmpty
          ? const ChartEmpty(
              message: 'No ratings yet. The patient is asked after each set.',
              icon: Icons.mood,
            )
          : TrendChart(
              height: 160,
              xLabels: [for (final r in rated) 'set ${r.setNumber}'],
              yMin: 0,
              yMax: 10,
              pointLabels: false,
              yLabel: (v) => v.toStringAsFixed(0),
              series: [
                TrendSeries(
                  label: 'Pain',
                  color: ChartPalette.series[1],
                  values: [for (final r in rated) r.pain?.toDouble()],
                ),
                TrendSeries(
                  label: 'Effort',
                  color: ChartPalette.series[0],
                  values: [for (final r in rated) r.effort?.toDouble()],
                ),
              ],
            ),
    );
  }
}

/// What was prescribed against what this session achieved.
class _PrescriptionCard extends StatelessWidget {
  const _PrescriptionCard({required this.state});

  final SessionState state;

  @override
  Widget build(BuildContext context) {
    final s = state;
    final counted = s.countedRows.toList();
    final atTarget = counted
        .where((r) => r.peakAngleDeg >= s.effectiveTargetDeg)
        .length;
    final onPace = counted
        .where((r) =>
            r.durationS >= s.effectiveTempoMinS &&
            r.durationS <= s.effectiveTempoMaxS)
        .length;
    final meanPeak = counted.isEmpty
        ? null
        : counted.map((r) => r.peakAngleDeg).reduce((a, b) => a + b) /
            counted.length;

    final written = s.config.targetAngleDeg;
    final inForce = s.effectiveTargetDeg;
    final eased = (written - inForce).abs() > 1;

    return ChartCard(
      title: 'Prescription and performance',
      subtitle: 'The prescription is what the sleeve reports is in force, not '
          'what the app last wrote.',
      footer: eased
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline,
                    size: 15, color: RehabColors.warn),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    'The sleeve is working to ${inForce.round()}°, not the '
                    '${written.round()}° configured: calibration set an '
                    'adaptive target from the patient\'s own comfortable bend. '
                    'Lock it from the Developer tab if that is not wanted.',
                    style: RehabText.body
                        .copyWith(fontSize: 12.5, color: RehabColors.warn),
                  ),
                ),
              ],
            )
          : null,
      child: Column(
        children: [
          _row('Target angle', '${inForce.round()}°',
              meanPeak == null ? '–' : '${meanPeak.round()}° mean peak',
              meanPeak != null && meanPeak >= inForce * 0.9),
          _row('Reps per set', '${s.effectiveRepTarget}',
              '${s.repCount} this set', s.repCount >= s.effectiveRepTarget),
          _row('Sets', '${s.effectiveSetCount}',
              'on set ${s.currentSetNumber}', true),
          _row(
            'Pace window',
            '${s.effectiveTempoMinS.toStringAsFixed(0)}'
                '–${s.effectiveTempoMaxS.toStringAsFixed(0)} s',
            counted.isEmpty ? '–' : '$onPace of ${counted.length} inside',
            counted.isNotEmpty && onPace >= counted.length * 0.7,
          ),
          _row(
            'Reach the full target',
            'every rep',
            counted.isEmpty ? '–' : '$atTarget of ${counted.length}',
            counted.isNotEmpty && atTarget >= counted.length * 0.8,
          ),
          _row('Rest between sets',
              '${s.sleeveParams?.restSeconds ?? s.config.restSeconds} s',
              s.isResting ? 'resting now' : '–', true),
          if (s.sleeveParams?.muscleOnPercent != null)
            _row(
              'Muscle counts as working',
              'above ${s.sleeveParams!.muscleOnPercent!.round()}%',
              '${(s.agonistEnvelope * 100).round()}% now',
              s.liveFeature.value?.activationOn ?? false,
            ),
        ],
      ),
    );
  }

  Widget _row(String label, String prescribed, String actual, bool ok) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(
                flex: 4,
                child:
                    Text(label, style: RehabText.body.copyWith(fontSize: 13))),
            Expanded(
              flex: 3,
              child: Text(prescribed,
                  style: RehabText.numeric.copyWith(fontSize: 12.5)),
            ),
            Expanded(
              flex: 3,
              child: Text(actual,
                  style: RehabText.body
                      .copyWith(fontSize: 12.5, color: RehabColors.inkSoft)),
            ),
            Icon(ok ? Icons.check : Icons.remove,
                size: 14,
                color: ok ? RehabColors.good : RehabColors.inkFaint),
          ],
        ),
      );
}

/// How often each form fault happened, and what to do about each.
class _FlagsCard extends StatelessWidget {
  const _FlagsCard({required this.state});

  final SessionState state;

  @override
  Widget build(BuildContext context) {
    final counted = state.countedRows.toList();
    final counts = <int, int>{};
    for (final r in counted) {
      for (final bit in [compShoulder, compTrunk, compSwing, compDrop]) {
        if (r.compFlags & bit != 0) counts[bit] = (counts[bit] ?? 0) + 1;
      }
    }
    final passive = state.repRows
        .where((r) => r.outcome == RepOutcome.passive)
        .length;
    final partial = state.repRows
        .where((r) => r.outcome == RepOutcome.partial)
        .length;

    final rows = <(String, int, String)>[
      ('Shoulder hike or lean', counts[compShoulder] ?? 0,
          compAdvice[compShoulder]!),
      ('Momentum or swing', counts[compSwing] ?? 0, compAdvice[compSwing]!),
      ('Dropped the arm', counts[compDrop] ?? 0, compAdvice[compDrop]!),
      ('Arm lifted for them', passive,
          'Not counted. If this keeps happening with real effort, check '
              'electrode contact before concluding the arm was lifted.'),
      ('Stopped short', partial,
          'Reported, not counted. A run of these is a sign the target is too '
              'high for today.'),
    ];

    return ChartCard(
      title: 'Form and safety flags',
      subtitle: 'How often each issue happened in this session, and what it '
          'asks the patient to change.',
      child: Column(
        children: [
          for (final (label, count, advice) in rows)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 9),
              decoration: const BoxDecoration(
                border: Border(
                    bottom:
                        BorderSide(color: RehabColors.divider, width: 0.5)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 30,
                    alignment: Alignment.centerLeft,
                    child: Text('$count',
                        style: RehabText.numeric.copyWith(
                          fontSize: 17,
                          color: count == 0
                              ? RehabColors.inkFaint
                              : count <= 2
                                  ? RehabColors.warn
                                  : RehabColors.bad,
                        )),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label,
                            style: RehabText.body.copyWith(
                                fontSize: 13, color: RehabColors.ink)),
                        if (count > 0)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(advice,
                                style: RehabText.body.copyWith(fontSize: 12)),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.info_outline,
                  size: 14, color: RehabColors.inkFaint),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  'Trunk lean is never raised by this sleeve: separating a lean '
                  'from a shoulder hike needs common-mode rotation of both '
                  'IMUs, so a lean is reported here as a shoulder hike.',
                  style: RehabText.body.copyWith(fontSize: 11.5),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
