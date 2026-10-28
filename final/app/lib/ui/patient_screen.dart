/// The patient view.
///
/// What someone sees while doing the exercise: the arm pose against where it
/// should be, the rep counter, muscle effort, and the device's own verdict on
/// the last rep. Everything on this screen comes from the sleeve. Nothing is
/// recomputed here.
///
/// ## Repaint discipline
///
/// Features arrive at 20 Hz. The whole screen is NOT rebuilt at that rate.
/// The parts that move are each a [ValueListenableBuilder] on
/// `state.liveFeature`, wrapped in [RepaintBoundary]; the parts that change
/// on a rep or a status update listen to [SessionState] itself. Rebuilding
/// everything 20 times a second is enough to make a mid-range Android phone
/// start missing BLE connection events, which is the same failure the PRD
/// warns about on the Python side.
library;

import 'package:flutter/material.dart';

import '../protocol/enums.dart';
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
        return SafeArea(
          child: Column(
            children: [
              _SessionBar(state: state),
              Expanded(
                child: RepaintBoundary(
                  child: _PoseStage(state: state, cue: _cue),
                ),
              ),
              _EffortBar(state: state),
              _RepSummary(state: state),
              _Controls(state: state),
            ],
          ),
        );
      },
    );
  }
}

/// The pose drawing, and the two numbers that belong on top of it.
class _PoseStage extends StatelessWidget {
  const _PoseStage({required this.state, required this.cue});

  final SessionState state;
  final Animation<double> cue;

  @override
  Widget build(BuildContext context) {
    final cfg = state.config;

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
          startAngleDeg: cfg.startAngleDeg,
          peakAngleDeg: cfg.peakAngleDeg,
          finishAngleDeg: cfg.finishAngleDeg,
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
                    startAngleDeg: cfg.startAngleDeg,
                    peakAngleDeg: cfg.peakAngleDeg,
                    targetAngleDeg: cfg.targetAngleDeg,
                    shoulderLimitDeg: cfg.compShoulderDeg,
                    activationOn: feature?.activationOn ?? false,
                    compFlags: feature?.compFlags ?? 0,
                    cueFlash: cue.value,
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
                peakDeg: cfg.peakAngleDeg,
                repState: repState,
              ),
            ),

            // Rep counter, bottom left, with the set target beside it.
            Positioned(
              left: 20,
              bottom: 16,
              child: _RepCounter(
                count: feature?.repCount ?? 0,
                target: cfg.repTarget,
              ),
            ),

            // Compensation callouts. Named, not merely coloured.
            if ((feature?.compFlags ?? 0) != 0)
              Positioned(
                right: 16,
                top: 12,
                child: _CompensationChips(
                  names: feature!.compensations,
                ),
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
                  style: TextStyle(
                      fontSize: 28, color: RehabColors.inkSoft)),
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
  const _RepCounter({required this.count, required this.target});

  final int count;
  final int target;

  @override
  Widget build(BuildContext context) {
    return Row(
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
    );
  }
}

class _CompensationChips extends StatelessWidget {
  const _CompensationChips({required this.names});

  final List<String> names;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (final n in names)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _Chip(label: n, color: RehabColors.bad),
          ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
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
    );
  }
}

/// Muscle effort, as a percentage of the calibrated maximum.
///
/// Separate from the pose on purpose: effort and position are different
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
                          style: RehabText.label
                              .copyWith(color: RehabColors.warn)),
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

/// The device's verdict on the last rep.
///
/// Empty until the firmware emits EVT_REP_COMPLETE — `main.c` does not wire
/// it up yet, so against real firmware this stays blank while the counter
/// still advances from the feature stream. The simulator fills it.
class _RepSummary extends StatelessWidget {
  const _RepSummary({required this.state});

  final SessionState state;

  @override
  Widget build(BuildContext context) {
    final rep = state.lastRep;
    if (rep == null) {
      final mdf = state.mdfTrendHz;
      if (mdf == null || mdf > -2) return const SizedBox(height: 4);
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
        child: Row(
          children: [
            const Icon(Icons.trending_down,
                size: 18, color: RehabColors.warn),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Median frequency down ${mdf.abs().toStringAsFixed(1)} Hz — '
                'fatigue building',
                style: RehabText.body.copyWith(color: RehabColors.warn),
              ),
            ),
          ],
        ),
      );
    }

    final cfg = state.config;
    final tempoColor =
        gradeColor(rep.tempoS, cfg.tempoMinS, cfg.tempoMaxS);

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: RehabColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: rep.flagged
              ? RehabColors.bad.withValues(alpha: 0.5)
              : RehabColors.divider,
        ),
      ),
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('REP ${rep.index}', style: RehabText.label),
              Text('${rep.score}',
                  style: RehabText.big.copyWith(
                    color: rep.flagged
                        ? RehabColors.warn
                        : RehabColors.good,
                  )),
            ],
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Wrap(
              spacing: 18,
              runSpacing: 6,
              children: [
                _Metric(
                  label: 'RANGE',
                  value: '${(rep.romFraction * 100).toStringAsFixed(0)}%',
                ),
                _Metric(
                  label: 'PACE',
                  value: '${rep.tempoS.toStringAsFixed(1)} s',
                  color: tempoColor,
                ),
                _Metric(
                  label: 'SMOOTH',
                  value: '${(rep.smoothness * 100).toStringAsFixed(0)}%',
                ),
                if (rep.flagged)
                  _Metric(
                    label: 'FLAGGED',
                    value: rep.compensations.join(', '),
                    color: RehabColors.bad,
                  ),
              ],
            ),
          ),
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
            style: RehabText.numeric.copyWith(color: color ?? RehabColors.ink)),
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
              status.batteryPct > 20
                  ? Icons.battery_std
                  : Icons.battery_alert,
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

class _Controls extends StatelessWidget {
  const _Controls({required this.state});

  final SessionState state;

  @override
  Widget build(BuildContext context) {
    final live = state.linkState.isLive;
    final running = state.sessionRequested;
    final calibrated = state.calibration?.isCalibrated ?? false;

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
                      'Not calibrated. Scores and effort will not mean much '
                      'until the six steps are done.',
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
                  child: Text(running ? 'Stop set' : 'Start set'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
