/// The arm pose: where it should be, and where it is.
///
/// Both arms are drawn from the same two numbers the device already derives
/// from the IMUs — `elbow_angle_deg` and `upper_arm_dev_deg` — so nothing
/// here re-derives orientation from raw accelerometer and gyroscope data. The
/// device does the fusion; this draws the answer.
///
/// ## Geometry
///
/// Side view, patient facing left. Canvas coordinates, so y increases
/// downward. The shoulder is fixed; a rotation by θ of the downward unit
/// vector (0, 1) gives (−sin θ, cos θ), which swings down → forward → up as θ
/// grows. That is a curl.
///
///   upper arm direction = R(dev) · (0, 1)
///   forearm direction   = R(dev + elbow) · (0, 1)
///
/// So `elbow = 0` is a straight arm hanging down and `elbow = 110°` is a
/// forearm pointing up and forward, which matches the firmware's convention
/// of 0° being full extension.
///
/// ## What the ghost means
///
/// The target pose is not a fixed picture — it is where the arm should be
/// *at this instant of this rep phase*. Standing still at full extension is
/// correct in READY and wrong in CONCENTRIC. The ghost therefore follows
/// [RepState], which is why it is read from the device rather than invented
/// here.
///
/// The target upper arm is always neutral. Deviation from neutral *is* the
/// shoulder-hike compensation, so there is never a target worth drawing for
/// it other than zero.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../protocol/enums.dart';
import 'theme.dart';

class ArmPose {
  const ArmPose({
    required this.elbowAngleDeg,
    required this.upperArmDevDeg,
  });

  final double elbowAngleDeg;
  final double upperArmDevDeg;
}

class ArmPosePainter extends CustomPainter {
  ArmPosePainter({
    required this.actual,
    required this.target,
    required this.repState,
    required this.startAngleDeg,
    required this.peakAngleDeg,
    required this.targetAngleDeg,
    required this.shoulderLimitDeg,
    required this.activationOn,
    required this.compFlags,
    this.cueFlash = 0.0,
  });

  final ArmPose actual;
  final ArmPose target;
  final RepState repState;

  /// The band a rep lives in. A rep starts above [startAngleDeg] and must
  /// pass [peakAngleDeg] — which is 80% of [targetAngleDeg], not the target
  /// itself.
  final double startAngleDeg;
  final double peakAngleDeg;
  final double targetAngleDeg;

  final double shoulderLimitDeg;
  final bool activationOn;
  final int compFlags;

  /// 0..1, drives the visual mirror of a haptic cue.
  final double cueFlash;

  bool get shoulderFlagged =>
      compFlags & compShoulder != 0 ||
      actual.upperArmDevDeg.abs() > shoulderLimitDeg;

  @override
  void paint(Canvas canvas, Size size) {
    // Shoulder sits high and right, leaving room for the forearm to sweep up
    // and to the left through its whole range without clipping.
    final shoulder = Offset(size.width * 0.70, size.height * 0.26);
    final reach = math.min(size.width * 0.62, size.height * 0.40);
    final upperLen = reach * 0.52;
    final foreLen = reach * 0.48;

    _paintTorso(canvas, size, shoulder, upperLen);
    _paintRangeArc(canvas, shoulder, upperLen, foreLen);

    // Ghost first, so the live arm always draws over it.
    _paintArm(
      canvas,
      shoulder,
      target,
      upperLen,
      foreLen,
      color: RehabColors.target,
      strokeWidth: 10,
      dashed: true,
    );

    final armColor = _liveColor();
    _paintArm(
      canvas,
      shoulder,
      actual,
      upperLen,
      foreLen,
      color: armColor,
      strokeWidth: 13,
      glow: activationOn,
    );

    if (shoulderFlagged) _paintShoulderWarning(canvas, shoulder, upperLen);
    if (cueFlash > 0) _paintCueRing(canvas, shoulder, reach);
  }

  /// Blue while tracking, amber when drifting from the ghost, red when badly
  /// off or compensating. The error that matters is the elbow angle: the
  /// patient can act on it.
  Color _liveColor() {
    if (compFlags != 0) return RehabColors.bad;
    final err = (actual.elbowAngleDeg - target.elbowAngleDeg).abs();
    if (err <= 12) return RehabColors.actual;
    if (err <= 28) return RehabColors.warn;
    return RehabColors.bad;
  }

  Offset _dir(double degrees) {
    final r = degrees * math.pi / 180.0;
    return Offset(-math.sin(r), math.cos(r));
  }

  void _paintArm(
    Canvas canvas,
    Offset shoulder,
    ArmPose pose,
    double upperLen,
    double foreLen, {
    required Color color,
    required double strokeWidth,
    bool dashed = false,
    bool glow = false,
  }) {
    final upperDir = _dir(pose.upperArmDevDeg);
    final elbow = shoulder + upperDir * upperLen;
    final foreDir = _dir(pose.upperArmDevDeg + pose.elbowAngleDeg);
    final wrist = elbow + foreDir * foreLen;

    if (glow) {
      // Muscle activity, shown as a halo on the upper arm only. It is the
      // biceps that is working, and putting the halo on the whole limb would
      // read as "the arm is in the right place", which is a different claim.
      final halo = Paint()
        ..color = RehabColors.muscle.withValues(alpha: 0.22)
        ..strokeWidth = strokeWidth + 16
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
      canvas.drawLine(shoulder, elbow, halo);
    }

    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    if (dashed) {
      _dashedLine(canvas, shoulder, elbow, paint);
      _dashedLine(canvas, elbow, wrist, paint);
    } else {
      canvas.drawLine(shoulder, elbow, paint);
      canvas.drawLine(elbow, wrist, paint);
    }

    // Joints. The elbow is the one the patient is being asked about, so it is
    // the larger and the only filled one.
    final jointFill = Paint()..color = color;
    final jointHole = Paint()..color = RehabColors.bg;

    canvas.drawCircle(shoulder, strokeWidth * 0.62, jointFill);
    canvas.drawCircle(elbow, strokeWidth * 0.95, jointFill);
    if (!dashed) {
      canvas.drawCircle(elbow, strokeWidth * 0.42, jointHole);
    }

    // Hand, as a short perpendicular stub: enough to read orientation
    // without pretending to track the wrist, which two IMUs cannot do.
    final handDir = Offset(-foreDir.dy, foreDir.dx);
    canvas.drawLine(
      wrist - handDir * (strokeWidth * 0.5),
      wrist + handDir * (strokeWidth * 0.5),
      paint..strokeWidth = strokeWidth * 0.8,
    );
  }

  void _dashedLine(Canvas canvas, Offset a, Offset b, Paint paint) {
    const dash = 11.0;
    const gap = 8.0;
    final total = (b - a).distance;
    if (total <= 0) return;
    final unit = (b - a) / total;
    var travelled = 0.0;
    while (travelled < total) {
      final end = math.min(travelled + dash, total);
      canvas.drawLine(a + unit * travelled, a + unit * end, paint);
      travelled = end + gap;
    }
  }

  /// A hint of a body, so the pose reads as an arm rather than two sticks.
  void _paintTorso(Canvas canvas, Size size, Offset shoulder, double upperLen) {
    final paint = Paint()
      ..color = RehabColors.divider
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    // Neck and trunk line, straight down from the shoulder.
    canvas.drawLine(
      shoulder + const Offset(0, -26),
      shoulder + Offset(0, upperLen * 1.9),
      paint,
    );
    canvas.drawCircle(
      shoulder + const Offset(2, -44),
      19,
      Paint()
        ..color = RehabColors.divider
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );

    // Trunk-lean indication: the firmware detects it as a common-mode
    // rotation of both IMUs, so it is a property of the body, not the arm.
    if (compFlags & compTrunk != 0) {
      final warn = Paint()
        ..color = RehabColors.bad.withValues(alpha: 0.75)
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        shoulder + const Offset(0, -20),
        shoulder + Offset(upperLen * 0.30, upperLen * 1.6),
        warn,
      );
    }
  }

  /// The band the rep must travel through, drawn as an arc at the elbow.
  void _paintRangeArc(
      Canvas canvas, Offset shoulder, double upperLen, double foreLen) {
    final elbow = shoulder + _dir(actual.upperArmDevDeg) * upperLen;
    final radius = foreLen * 0.78;
    final rect = Rect.fromCircle(center: elbow, radius: radius);

    // Canvas arcs measure from +x anticlockwise-negative; the forearm at
    // angle θ sits at atan2 of its direction vector, so derive both ends from
    // the same _dir() the arm uses rather than re-deriving the trigonometry.
    double sweepStart(double deg) {
      final d = _dir(actual.upperArmDevDeg + deg);
      return math.atan2(d.dy, d.dx);
    }

    final a0 = sweepStart(startAngleDeg);
    final a1 = sweepStart(peakAngleDeg);

    canvas.drawArc(
      rect,
      a0,
      a1 - a0,
      false,
      Paint()
        ..color = RehabColors.good.withValues(alpha: 0.18)
        ..strokeWidth = 16
        ..strokeCap = StrokeCap.butt
        ..style = PaintingStyle.stroke,
    );

    // The peak criterion: the line a rep must cross to count.
    final peakDir = _dir(actual.upperArmDevDeg + peakAngleDeg);
    canvas.drawLine(
      elbow + peakDir * (radius - 14),
      elbow + peakDir * (radius + 14),
      Paint()
        ..color = RehabColors.good
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round,
    );

    // And the therapist-set target, which is further out and not the
    // criterion — worth distinguishing so nobody reads the arc as the goal.
    final targetDir = _dir(actual.upperArmDevDeg + targetAngleDeg);
    canvas.drawLine(
      elbow + targetDir * (radius - 8),
      elbow + targetDir * (radius + 8),
      Paint()
        ..color = RehabColors.inkFaint
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
  }

  void _paintShoulderWarning(Canvas canvas, Offset shoulder, double upperLen) {
    // An upward chevron at the shoulder: the direction the patient needs to
    // correct, not merely that something is wrong.
    final paint = Paint()
      ..color = RehabColors.bad
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final apex = shoulder + const Offset(0, -34);
    canvas.drawLine(apex, apex + const Offset(-15, 15), paint);
    canvas.drawLine(apex, apex + const Offset(15, 15), paint);

    canvas.drawCircle(
      shoulder,
      22,
      Paint()
        ..color = RehabColors.bad.withValues(alpha: 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  /// The visual mirror of a haptic cue. The vibration is the real feedback —
  /// this is for anyone watching, and for a bench session with the motor
  /// disconnected.
  void _paintCueRing(Canvas canvas, Offset shoulder, double reach) {
    canvas.drawCircle(
      shoulder,
      reach * (0.5 + cueFlash * 0.7),
      Paint()
        ..color = RehabColors.actual.withValues(alpha: 0.35 * (1 - cueFlash))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6 * (1 - cueFlash) + 1,
    );
  }

  @override
  bool shouldRepaint(ArmPosePainter old) =>
      old.actual.elbowAngleDeg != actual.elbowAngleDeg ||
      old.actual.upperArmDevDeg != actual.upperArmDevDeg ||
      old.target.elbowAngleDeg != target.elbowAngleDeg ||
      old.repState != repState ||
      old.activationOn != activationOn ||
      old.compFlags != compFlags ||
      old.cueFlash != cueFlash ||
      old.peakAngleDeg != peakAngleDeg ||
      old.startAngleDeg != startAngleDeg;
}

/// Where the arm should be at this instant of this rep phase.
///
/// Standing still at full extension is correct in READY and wrong halfway
/// through a concentric phase, so the ghost has to follow the device's own
/// rep state rather than show one fixed pose.
///
/// The target upper-arm deviation is always zero: deviation from the
/// calibrated neutral *is* the shoulder-hike compensation.
ArmPose targetPoseFor(
  RepState state, {
  required double startAngleDeg,
  required double peakAngleDeg,
  required double finishAngleDeg,
}) {
  final elbow = switch (state) {
    // At rest, below the start threshold, waiting to begin.
    RepState.ready => finishAngleDeg,

    // Rising. The goal is the criterion, not the therapist's target angle.
    RepState.concentric => peakAngleDeg,

    RepState.peak => peakAngleDeg,

    // Coming back down. The count happens on the return, after a confirming
    // hold at the extended position.
    RepState.eccentric => finishAngleDeg,
    RepState.extendedHold => finishAngleDeg,
  };
  return ArmPose(elbowAngleDeg: elbow, upperArmDevDeg: 0.0);
}
