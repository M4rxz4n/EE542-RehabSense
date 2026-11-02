/// The patient view.
///
/// What someone sees while doing the exercise: the arm against where it should
/// be, the rep counter, muscle effort, and the device's own verdict on the last
/// rep. Everything on this screen comes from the sleeve. Nothing is recomputed
/// here.
///
/// ## What this screen is for
///
/// One reader, mid-curl, holding a phone propped a metre away with their arm
/// under load. They can answer three questions and no more: am I high enough,
/// is my elbow drifting, is the muscle doing the work. Everything here serves
/// one of those three; anything that served a fourth would cost one of them.
///
/// That is why the session charts, the rep table and the fatigue trend are on
/// other tabs. They are worth reading — between sets.
///
/// ## Repaint discipline
///
/// Features arrive at 20 Hz. The whole screen is NOT rebuilt at that rate.
/// The parts that move are each a [ValueListenableBuilder] on
/// `state.liveFeature`, wrapped in [RepaintBoundary]; the parts that change on
/// a rep or a status update listen to [SessionState] itself. Rebuilding
/// everything twenty times a second is enough to make a mid-range Android
/// phone start missing BLE connection events, which is the same failure the
/// PRD warns about on the Python side.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../protocol/enums.dart';
import '../session/rep_log.dart';
import '../session/session_state.dart';
import 'arm_pose_painter.dart';
import 'theme.dart';

class PatientScreen extends StatefulWidget {
  const PatientScreen({super.key, required this.state});

  final SessionState state;

  @override
  State<PatientScreen> createState() => _PatientScreenState();
}

class _PatientScreenState extends State<PatientScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _cue = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
  );

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onStateChanged);
  }

  @override
  void dispose() {
    widget.state.removeListener(_onStateChanged);
    _cue.dispose();
    super.dispose();
  }

  /// Mirrors a haptic cue visually. The vibration is the real feedback — this
  /// is for an observer, and for bench work with the motor disconnected.
  void _onStateChanged() {
    if (widget.state.pendingCue != null) {
      widget.state.consumeCue();
      _cue.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;

    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        // A rating prompt replaces the exercise view rather than sitting
        // beside it. The set is over, there is nothing to watch, and a dialog
        // over a live screen is the kind of thing that gets dismissed
        // unanswered.
        if (state.awaitingRatingForSet != null) {
          return _RatingPane(state: state);
        }

        return SafeArea(
          child: Column(
            children: [
              _SessionBar(state: state),
              if (state.autoPaused) _PausedBanner(state: state),
              if (state.isResting) _RestingBanner(state: state),
              Expanded(
                child: RepaintBoundary(
                  child: _PoseStage(state: state, cue: _cue),
                ),
              ),
              if (state.paceOn && !state.isResting) _PaceStrip(state: state),
              _EffortBar(state: state),
              _RepDots(state: state),
              _RepSummary(state: state),
              _Controls(state: state),
            ],
          ),
        );
      },
    );
  }
}

/// The arm drawing, and the two numbers that belong on top of it.
class _PoseStage extends StatelessWidget {
  const _PoseStage({required this.state, required this.cue});

  final SessionState state;
  final Animation<double> cue;

  /// The last second or so of elbow angle, for the wrist trail.
  ///
  /// Taken from the live trace rather than kept here, so it is the same data
  /// the charts draw and cannot drift from it.
  List<double> _trail() {
    final pts = state.trace;
    if (pts.length < 2) return const [];
    const n = 14;
    final from = math.max(0, pts.length - n);
    return [for (final p in pts.skip(from)) p.angleDeg];
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: state.liveFeature,
      builder: (context, feature, _) {
        final repState = feature?.repState ?? RepState.ready;
        final actual = ArmPose(
          elbowAngleDeg: feature?.elbowAngleDeg ?? 0,
          upperArmDevDeg: feature?.upperArmDevDeg ?? 0,
        );
        final target = targetPoseFor(
          repState,
          startAngleDeg: state.effectiveStartDeg,
          peakAngleDeg: state.effectivePeakDeg,
          finishAngleDeg: state.effectiveFinishDeg,
        );

        return Stack(
          children: [
            Positioned.fill(
              child: AnimatedBuilder(
                animation: cue,
                builder: (context, _) => CustomPaint(
                  painter: ArmPosePainter(
                    actual: actual,
                    target: target,
                    repState: repState,
                    startAngleDeg: state.effectiveStartDeg,
                    peakAngleDeg: state.effectivePeakDeg,
                    targetAngleDeg: state.effectiveTargetDeg,
                    shoulderLimitDeg: state.config.compShoulderDeg,
                    activationOn: feature?.activationOn ?? false,
                    compFlags: feature?.compFlags ?? 0,
                    envelope: state.agonistEnvelope,
                    cueFlash: cue.value,
                    trail: _trail(),
                  ),
                ),
              ),
            ),

            // Angle, top left. The number the patient is being asked about.
            Positioned(
              left: 20,
              top: 12,
              child: _AngleReadout(
                angleDeg: actual.elbowAngleDeg,
                peakDeg: state.effectivePeakDeg,
                repState: repState,
              ),
            ),

            // Rep counter, bottom left, with the set target beside it.
            Positioned(
              left: 20,
              bottom: 16,
              child: _RepCounter(
                count: feature?.repCount ?? 0,
                target: state.effectiveRepTarget,
                setNumber: state.currentSetNumber,
                sets: state.effectiveSetCount,
              ),
            ),

            // Compensation callouts. Named, not merely coloured, and carrying
            // what to change rather than only what went wrong.
            if ((feature?.compFlags ?? 0) != 0)
              Positioned(
                right: 16,
                top: 12,
                child: _CompensationChips(flags: feature!.compFlags),
              ),

            if (feature?.signalDegraded ?? false)
              const Positioned(
                right: 16,
                bottom: 16,
                child: _Chip(
                  label: 'Check electrodes',
                  color: RehabColors.warn,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _AngleReadout extends StatelessWidget {
  const _AngleReadout({
    required this.angleDeg,
    required this.peakDeg,
    required this.repState,
  });

  final double angleDeg;
  final double peakDeg;
  final RepState repState;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('ELBOW', style: RehabText.label),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(angleDeg.toStringAsFixed(0), style: RehabText.hero),
            const Padding(
              padding: EdgeInsets.only(top: 8, left: 2),
              child: Text('°',
                  style:
                      TextStyle(fontSize: 28, color: RehabColors.inkSoft)),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: angleDeg >= peakDeg
                    ? RehabColors.good
                    : RehabColors.inkFaint,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              repState == RepState.extendedHold
                  ? 'HOLD'
                  : repState.label.toUpperCase(),
              style: RehabText.label.copyWith(
                color: repState == RepState.extendedHold
                    ? RehabColors.hold
                    : RehabColors.inkSoft,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _RepCounter extends StatelessWidget {
  const _RepCounter({
    required this.count,
    required this.target,
    required this.setNumber,
    required this.sets,
  });

  final int count;
  final int target;
  final int setNumber;
  final int sets;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text('$count', style: RehabText.hero),
            Text(' / $target',
                style: RehabText.big.copyWith(color: RehabColors.inkFaint)),
            const SizedBox(width: 10),
            const Padding(
              padding: EdgeInsets.only(bottom: 10),
              child: Text('REPS', style: RehabText.label),
            ),
          ],
        ),
        Text('set $setNumber of $sets', style: RehabText.label),
      ],
    );
  }
}

class _CompensationChips extends StatelessWidget {
  const _CompensationChips({required this.flags});

  final int flags;

  @override
  Widget build(BuildContext context) {
    final advice = compAdviceFor(flags);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < compNames(flags).length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _Chip(
              label: compNames(flags)[i],
              color: RehabColors.bad,
              // The fix, not just the fault. A patient who cannot act on
              // feedback stops trusting it.
              hint: i < advice.length ? advice[i] : null,
            ),
          ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.color, this.hint});

  final String label;
  final Color color;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.16),
            border: Border.all(color: color.withValues(alpha: 0.55)),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label.toUpperCase(),
            style: RehabText.label.copyWith(color: color, letterSpacing: 0.6),
          ),
        ),
        if (hint != null)
          Container(
            constraints: const BoxConstraints(maxWidth: 170),
            padding: const EdgeInsets.only(top: 3, right: 2),
            child: Text(hint!,
                textAlign: TextAlign.right,
                style: RehabText.body.copyWith(fontSize: 11.5, color: color)),
          ),
      ],
    );
  }
}

/// Which beat of the guided pace the sleeve is on.
///
/// The motor carries this — a tick to lift, a steady buzz to hold, a double
/// tick to lower. The screen mirrors it for anyone watching, and for the case
/// where the vibration is hard to feel through a sleeve over clothing.
class _PaceStrip extends StatelessWidget {
  const _PaceStrip({required this.state});

  final SessionState state;

  @override
  Widget build(BuildContext context) {
    final phase = state.pacePhase;
    if (phase == PacePhase.off) return const SizedBox.shrink();

    const order = [
      PacePhase.up,
      PacePhase.hold,
      PacePhase.down,
      PacePhase.relax
    ];
    final waiting = phase == PacePhase.waiting;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('GUIDED PACE', style: RehabText.label),
              const Spacer(),
              Text(
                waiting ? 'Straighten your arm' : phase.feel,
                style: RehabText.label.copyWith(color: RehabColors.inkSoft),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              for (final p in order) ...[
                Expanded(
                  child: Container(
                    height: 6,
                    decoration: BoxDecoration(
                      color: p == phase
                          ? RehabColors.actual
                          : RehabColors.surfaceHigh,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
                if (p != order.last) const SizedBox(width: 4),
              ],
            ],
          ),
          const SizedBox(height: 5),
          Text(
            waiting
                ? 'The next lift waits until your arm is straight.'
                : phase.label,
            style: RehabText.body.copyWith(
                fontSize: 13,
                color: waiting ? RehabColors.warn : RehabColors.ink),
          ),
        ],
      ),
    );
  }
}

/// Muscle effort, as a percentage of the calibrated maximum.
///
/// Separate from the arm on purpose: effort and position are different
/// questions, and a patient who can see both learns that a rep needs the
/// muscle to be doing the work — which is what rejects a passively swung arm.
class _EffortBar extends StatelessWidget {
  const _EffortBar({required this.state});

  final SessionState state;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ValueListenableBuilder(
        valueListenable: state.liveFeature,
        builder: (context, feature, _) {
          final env = state.agonistEnvelope;
          final on = feature?.activationOn ?? false;
          final unreliable = feature?.mvcUnreliable ?? false;

          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text('BICEPS EFFORT', style: RehabText.label),
                    const Spacer(),
                    if (unreliable)
                      Text('maximum uncertain',
                          style:
                              RehabText.label.copyWith(color: RehabColors.warn)),
                    const SizedBox(width: 10),
                    Text('${(env * 100).toStringAsFixed(0)}%',
                        style: RehabText.numeric.copyWith(
                          color: on
                              ? RehabColors.muscle
                              : RehabColors.inkFaint,
                        )),
                  ],
                ),
                const SizedBox(height: 7),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: Stack(
                    children: [
                      Container(height: 12, color: RehabColors.surfaceHigh),
                      FractionallySizedBox(
                        widthFactor: env.clamp(0.0, 1.0),
                        child: Container(
                          height: 12,
                          color: on
                              ? RehabColors.muscle
                              : RehabColors.muscle.withValues(alpha: 0.4),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  on
                      ? 'Muscle working'
                      : 'Relaxed — a rep needs the biceps to pull',
                  style: RehabText.label.copyWith(
                    color: on ? RehabColors.muscle : RehabColors.inkFaint,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// One dot per attempt in this set.
///
/// The counter says how many; this says how they went, which is the difference
/// between "eight reps" and "eight reps, three of them flagged". Partials get a
/// hollow dot: a patient who sees nothing after a hard attempt concludes the
/// device is broken.
class _RepDots extends StatelessWidget {
  const _RepDots({required this.state});

  final SessionState state;

  @override
  Widget build(BuildContext context) {
    final set = state.currentSetNumber;
    final rows = state.repRows
        .where((r) => r.setNumber == null || r.setNumber == set)
        .toList();
    if (rows.isEmpty) return const SizedBox(height: 4);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final r in rows)
            Container(
              width: 13,
              height: 13,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: r.counted
                    ? (r.flagged ? RehabColors.warn : RehabColors.good)
                    : Colors.transparent,
                border: r.counted
                    ? null
                    : Border.all(
                        color: r.outcome == RepOutcome.passive
                            ? RehabColors.bad
                            : RehabColors.inkFaint,
                        width: 2,
                      ),
              ),
            ),
          // Empty slots for what is left, so the set reads as a target rather
          // than an open-ended count.
          for (var i = rows.where((r) => r.counted).length;
              i < state.effectiveRepTarget;
              i++)
            Container(
              width: 13,
              height: 13,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: RehabColors.surfaceHigh,
              ),
            ),
        ],
      ),
    );
  }
}

/// The device's verdict on the last rep.
class _RepSummary extends StatelessWidget {
  const _RepSummary({required this.state});

  final SessionState state;

  @override
  Widget build(BuildContext context) {
    final row = state.lastRow;
    if (row == null) {
      final f = state.lastFatigue;
      if (f == null || !f.anySign) return const SizedBox(height: 4);
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
        child: Row(
          children: [
            const Icon(Icons.battery_alert_outlined,
                size: 18, color: RehabColors.warn),
            const SizedBox(width: 8),
            Expanded(
              child: Text(f.summary,
                  style: RehabText.body.copyWith(color: RehabColors.warn)),
            ),
          ],
        ),
      );
    }

    final tempoColor = gradeColor(
        row.durationS, state.effectiveTempoMinS, state.effectiveTempoMaxS);

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: RehabColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: row.counted
              ? (row.flagged
                  ? RehabColors.bad.withValues(alpha: 0.5)
                  : RehabColors.divider)
              : RehabColors.warn.withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      row.counted
                          ? 'REP ${row.index ?? ''}'
                          : 'NOT COUNTED',
                      style: RehabText.label),
                  Text(
                    row.counted ? '${row.score ?? '–'}' : '–',
                    style: RehabText.big.copyWith(
                      color: row.counted
                          ? (row.flagged
                              ? RehabColors.warn
                              : RehabColors.good)
                          : RehabColors.warn,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Wrap(
                  spacing: 18,
                  runSpacing: 6,
                  children: [
                    _Metric(
                      label: 'PEAK',
                      value: '${row.peakAngleDeg.toStringAsFixed(0)}°',
                    ),
                    if (row.romPercent != null)
                      _Metric(label: 'RANGE', value: '${row.romPercent}%'),
                    if (row.durationS > 0)
                      _Metric(
                        label: 'PACE',
                        value: '${row.durationS.toStringAsFixed(1)} s',
                        color: tempoColor,
                      ),
                    if (row.bicepsPercent != null)
                      _Metric(
                        label: 'BICEPS',
                        value: '${row.bicepsPercent!.toStringAsFixed(0)}%',
                        color: RehabColors.muscle,
                      ),
                  ],
                ),
              ),
            ],
          ),
          // The coaching line, in the sleeve's own terms. One at most: a
          // patient mid-set cannot act on three corrections.
          if (row.why.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(row.why.first,
                style: RehabText.body.copyWith(fontSize: 13)),
          ],
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: RehabText.label),
        Text(value,
            style:
                RehabText.numeric.copyWith(color: color ?? RehabColors.ink)),
      ],
    );
  }
}

/// Link, device state and battery. Small, because it is not the patient's
/// business unless something is wrong.
class _SessionBar extends StatelessWidget {
  const _SessionBar({required this.state});

  final SessionState state;

  @override
  Widget build(BuildContext context) {
    final status = state.status;
    final link = state.linkState;

    final Color dot;
    if (link.isLive) {
      dot = (status?.inFault ?? false) ? RehabColors.bad : RehabColors.good;
    } else if (link.isBusy) {
      dot = RehabColors.warn;
    } else {
      dot = RehabColors.inkFaint;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
      child: Row(
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(shape: BoxShape.circle, color: dot),
          ),
          const SizedBox(width: 8),
          Text(
            (status?.inFault ?? false)
                ? status!.faultLabel
                : (link.isLive
                    ? (status?.stateLabel ?? 'Connected')
                    : link.label),
            style: RehabText.label.copyWith(
              color: (status?.inFault ?? false)
                  ? RehabColors.bad
                  : RehabColors.inkSoft,
            ),
          ),
          const Spacer(),

          // A genuine hole in the record, as distinct from data merely not yet
          // acknowledged. Worth surfacing: it cannot be recovered later.
          if (state.hasGap)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Text('DATA GAP',
                  style: RehabText.label.copyWith(color: RehabColors.warn)),
            ),

          if (status != null) ...[
            Icon(
              status.batteryPct > 20 ? Icons.battery_std : Icons.battery_alert,
              size: 15,
              color: status.batteryPct > 20
                  ? RehabColors.inkFaint
                  : RehabColors.bad,
            ),
            const SizedBox(width: 4),
            Text('${status.batteryPct}%', style: RehabText.label),
          ],
        ],
      ),
    );
  }
}

class _PausedBanner extends StatelessWidget {
  const _PausedBanner({required this.state});

  final SessionState state;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 6, 20, 2),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: RehabColors.hold.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.pause_circle_outline,
              size: 19, color: RehabColors.hold),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Paused — take as long as you need. Move your arm, or press the '
              'button on the sleeve, to carry on. Your reps are kept.',
              style: RehabText.body.copyWith(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _RestingBanner extends StatelessWidget {
  const _RestingBanner({required this.state});

  final SessionState state;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 6, 20, 2),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: RehabColors.actual.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.self_improvement,
              size: 19, color: RehabColors.actual),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Resting between sets. Let your arm relax — curls during the '
              'rest are not counted. Start set when you are ready to skip '
              'ahead.',
              style: RehabText.body.copyWith(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// Pain and effort after a set.
///
/// Both optional. A skipped rating is a real answer and is stored as nothing
/// rather than as a zero — a zero on the therapist's chart would read as "no
/// pain at all", which is a different claim from "did not say".
class _RatingPane extends StatefulWidget {
  const _RatingPane({required this.state});

  final SessionState state;

  @override
  State<_RatingPane> createState() => _RatingPaneState();
}

class _RatingPaneState extends State<_RatingPane> {
  int? _pain;
  int? _effort;

  @override
  Widget build(BuildContext context) {
    final set = widget.state.awaitingRatingForSet ?? 1;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(26),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Set $set done', style: RehabText.hero.copyWith(fontSize: 42)),
            const SizedBox(height: 10),
            Text(
              'Two quick questions, then rest. Both are optional — skip if you '
              'would rather not say.',
              style: RehabText.body,
            ),
            const SizedBox(height: 30),
            _Scale(
              label: 'PAIN',
              hint: '0 is none, 10 is the worst you can imagine',
              value: _pain,
              color: RehabColors.bad,
              onChanged: (v) => setState(() => _pain = v),
            ),
            const SizedBox(height: 24),
            _Scale(
              label: 'EFFORT',
              hint: '0 is nothing at all, 10 is as hard as you could push',
              value: _effort,
              color: RehabColors.actual,
              onChanged: (v) => setState(() => _effort = v),
            ),
            const SizedBox(height: 34),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: (_pain == null && _effort == null)
                        ? null
                        : () => widget.state
                            .recordRating(pain: _pain, effort: _effort),
                    child: const Text('Done'),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton(
                  onPressed: widget.state.dismissRating,
                  child: const Text('Skip'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Scale extends StatelessWidget {
  const _Scale({
    required this.label,
    required this.hint,
    required this.value,
    required this.color,
    required this.onChanged,
  });

  final String label;
  final String hint;
  final int? value;
  final Color color;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: RehabText.label),
        const SizedBox(height: 2),
        Text(hint, style: RehabText.body.copyWith(fontSize: 12.5)),
        const SizedBox(height: 10),
        Wrap(
          spacing: 7,
          runSpacing: 7,
          children: [
            for (var i = 0; i <= 10; i++)
              SizedBox(
                // 44pt, the floor for something a weak hand has to hit.
                width: 44,
                height: 44,
                child: Material(
                  color: value == i
                      ? color.withValues(alpha: 0.26)
                      : RehabColors.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(
                      color: value == i ? color : RehabColors.divider,
                      width: value == i ? 2 : 1,
                    ),
                  ),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => onChanged(i),
                    child: Center(
                      child: Text('$i',
                          style: RehabText.numeric.copyWith(
                            fontSize: 16,
                            color:
                                value == i ? color : RehabColors.inkSoft,
                          )),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.state});

  final SessionState state;

  @override
  Widget build(BuildContext context) {
    final live = state.linkState.isLive;
    final running = state.sessionRequested;
    final calibrated = state.isCalibrated;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Column(
        children: [
          if (live && !calibrated && !running)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  const Icon(Icons.info_outline,
                      size: 17, color: RehabColors.warn),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Not calibrated. Starting a set calibrates first — or '
                      'use the Calibrate tab to walk it step by step.',
                      style:
                          RehabText.body.copyWith(color: RehabColors.warn),
                    ),
                  ),
                ],
              ),
            ),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: !live
                      ? null
                      : (running ? state.stopSession : state.startSession),
                  style: FilledButton.styleFrom(
                    backgroundColor:
                        running ? RehabColors.bad : RehabColors.actual,
                    foregroundColor: RehabColors.bg,
                  ),
                  child: Text(running
                      ? 'Stop set'
                      : state.isResting
                          ? 'Skip the rest'
                          : 'Start set'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
