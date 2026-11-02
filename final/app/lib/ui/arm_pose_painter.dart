/// The arm pose: where it should be, and where it is.
///
/// Both arms are drawn from the same two numbers the device already derives
/// from the IMUs — `elbow_angle_deg` and `upper_arm_dev_deg` — so nothing here
/// re-derives orientation from raw accelerometer and gyroscope data. The
/// device does the fusion; this draws the answer.
///
/// ## Why an anatomical arm rather than two sticks
///
/// The stick figure this replaces was legible but it was not *readable*. A
/// patient mid-curl has to answer three questions at a glance — am I high
/// enough, is my elbow drifting, is the muscle doing the work — and a line
/// with a dot on it answers the first one only. A limb with a shoulder, a
/// tapered upper arm, a forearm and a visible biceps belly answers all three,
/// because the shape itself carries the second and the third.
///
/// The biceps belly is the point of the exercise, so it is drawn as a real
/// muscle, with two signals deliberately kept on separate visual channels:
///
/// - **Shape** follows the elbow angle. A contracting biceps shortens and
///   thickens, so the belly's bulge grows and its centre creeps toward the
///   shoulder as the elbow flexes. This happens whether or not the muscle is
///   doing the work, because it is a consequence of the joint angle.
/// - **Colour** follows the EMG envelope. Cool and flat at rest, warm and
///   saturated under load.
///
/// So an arm somebody else is lifting shows a flexed shape in a cold colour —
/// visibly different from a rep the patient drove, and the exact case a
/// motion-only device cannot show at all.
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
/// forearm pointing up and forward, which matches the firmware's convention of
/// 0° being full extension.
///
/// ## What the ghost means
///
/// The target pose is not a fixed picture — it is where the arm should be *at
/// this instant of this rep phase*. Standing still at full extension is
/// correct in READY and wrong in CONCENTRIC. The ghost therefore follows
/// [RepState], which is why it is read from the device rather than invented
/// here.
///
/// The target upper arm is always neutral. Deviation from neutral *is* the
/// shoulder-hike compensation, so there is never a target worth drawing for it
/// other than zero.
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
    this.envelope = 0.0,
    this.cueFlash = 0.0,
    this.trail = const [],
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

  /// Agonist %MVC, 0..1.5. Drives the biceps colour only — never its shape,
  /// which follows the elbow angle. Keeping the two on separate channels is
  /// what lets a viewer see "moving but not working".
  final double envelope;

  /// 0..1, drives the visual mirror of a haptic cue.
  final double cueFlash;

  /// Recent elbow angles, oldest first, for the wrist trail. Empty is fine.
  final List<double> trail;

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

    _paintTorso(canvas, shoulder, upperLen);
    _paintRangeArc(canvas, shoulder, upperLen, foreLen);

    // Ghost first, so the live arm always draws over it.
    _paintGhost(canvas, shoulder, target, upperLen, foreLen);

    if (trail.length > 1) _paintTrail(canvas, shoulder, upperLen, foreLen);

    _paintLimb(canvas, shoulder, actual, upperLen, foreLen);

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

  Offset _perp(Offset d) => Offset(-d.dy, d.dx);

  Offset _elbowOf(ArmPose pose, Offset shoulder, double upperLen) =>
      shoulder + _dir(pose.upperArmDevDeg) * upperLen;

  Offset _wristOf(
          ArmPose pose, Offset shoulder, double upperLen, double foreLen) =>
      _elbowOf(pose, shoulder, upperLen) +
      _dir(pose.upperArmDevDeg + pose.elbowAngleDeg) * foreLen;

  // ── The limb ───────────────────────────────────────────────────────────

  /// A tapered segment: wider at the proximal end than the distal one, with
  /// rounded ends and a slight outward bow, which is how a limb reads. A
  /// straight-sided taper reads as a cone, and a cone does not read as an arm.
  Path _segment(Offset from, Offset to, double wFrom, double wTo) {
    final len = (to - from).distance;
    if (len <= 0.01) return Path();
    final d = (to - from) / len;
    final p = _perp(d);

    final a = from + p * (wFrom / 2);
    final b = to + p * (wTo / 2);
    final c = to - p * (wTo / 2);
    final e = from - p * (wFrom / 2);

    return Path()
      ..moveTo(a.dx, a.dy)
      ..quadraticBezierTo(
        (a.dx + b.dx) / 2 + p.dx * wFrom * 0.10,
        (a.dy + b.dy) / 2 + p.dy * wFrom * 0.10,
        b.dx,
        b.dy,
      )
      ..arcToPoint(c, radius: Radius.circular(wTo / 2), clockwise: false)
      ..quadraticBezierTo(
        (c.dx + e.dx) / 2 - p.dx * wFrom * 0.10,
        (c.dy + e.dy) / 2 - p.dy * wFrom * 0.10,
        e.dx,
        e.dy,
      )
      ..arcToPoint(a, radius: Radius.circular(wFrom / 2), clockwise: false)
      ..close();
  }

  void _paintLimb(Canvas canvas, Offset shoulder, ArmPose pose,
      double upperLen, double foreLen) {
    final limb = _liveColor();
    final elbow = _elbowOf(pose, shoulder, upperLen);
    final wrist = _wristOf(pose, shoulder, upperLen, foreLen);

    final upperW = upperLen * 0.34;
    final elbowW = upperLen * 0.24;
    final wristW = upperLen * 0.17;

    // A halo under the whole upper arm while the muscle is working. On the
    // limb rather than the background so it reads as the arm doing something,
    // and at low alpha so it never competes with the biceps itself.
    if (activationOn) {
      canvas.drawPath(
        _segment(shoulder, elbow, upperW + 14, elbowW + 10),
        Paint()
          ..color = RehabColors.muscle.withValues(alpha: 0.18)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
      );
    }

    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..color = limb.withValues(alpha: 0.95);

    // Upper arm. Darker than the forearm so the two segments separate at the
    // elbow without needing a drawn joint line.
    final upperPath = _segment(shoulder, elbow, upperW, elbowW);
    canvas.drawPath(upperPath,
        Paint()..color = Color.lerp(limb, RehabColors.bg, 0.62)!);
    canvas.drawPath(upperPath, edge);

    _paintBiceps(canvas, shoulder, elbow, upperW, pose.elbowAngleDeg);

    final forePath = _segment(elbow, wrist, elbowW, wristW);
    canvas.drawPath(forePath,
        Paint()..color = Color.lerp(limb, RehabColors.bg, 0.52)!);
    canvas.drawPath(forePath, edge);

    _paintElbowJoint(canvas, elbow, elbowW, limb);
    _paintHand(canvas, elbow, wrist, wristW, limb);
  }

  /// The biceps belly. See the library comment for why shape and colour carry
  /// different signals.
  void _paintBiceps(Canvas canvas, Offset shoulder, Offset elbow,
      double upperW, double elbowAngleDeg) {
    final len = (elbow - shoulder).distance;
    if (len <= 1) return;
    final d = (elbow - shoulder) / len;
    final p = _perp(d);

    // 0 at full extension, 1 at a deep curl. Past 120° the belly stops
    // growing: the muscle is already fully shortened, and a bulge that kept
    // inflating would be a cartoon.
    final flex = (elbowAngleDeg / 120.0).clamp(0.0, 1.0);

    // The belly sits on the anterior side and migrates proximally as it
    // shortens — 46% of the way down the humerus relaxed, 38% contracted.
    final centre = shoulder + d * (len * (0.46 - 0.08 * flex));
    final bellyLen = len * (0.56 - 0.10 * flex);
    final bulge = upperW * (0.26 + 0.46 * flex);

    final from = centre - d * (bellyLen / 2);
    final to = centre + d * (bellyLen / 2);

    // Anterior is the side the forearm swings toward, so this follows the
    // curl direction rather than being fixed.
    final anterior = p * -1;

    final belly = Path()
      ..moveTo(from.dx, from.dy)
      ..cubicTo(
        from.dx + d.dx * bellyLen * 0.18 + anterior.dx * bulge,
        from.dy + d.dy * bellyLen * 0.18 + anterior.dy * bulge,
        to.dx - d.dx * bellyLen * 0.18 + anterior.dx * bulge,
        to.dy - d.dy * bellyLen * 0.18 + anterior.dy * bulge,
        to.dx,
        to.dy,
      )
      ..cubicTo(
        to.dx - d.dx * bellyLen * 0.22 + anterior.dx * bulge * 0.18,
        to.dy - d.dy * bellyLen * 0.22 + anterior.dy * bulge * 0.18,
        from.dx + d.dx * bellyLen * 0.22 + anterior.dx * bulge * 0.18,
        from.dy + d.dy * bellyLen * 0.22 + anterior.dy * bulge * 0.18,
        from.dx,
        from.dy,
      )
      ..close();

    // Colour from the envelope. Clamped at 1.0 for the ramp even though the
    // sleeve legitimately reports more — above the calibration squeeze the
    // colour is already at full warmth and has nowhere to go.
    final load = envelope.clamp(0.0, 1.0);
    final cool = Color.lerp(RehabColors.muscle, RehabColors.bg, 0.68)!;
    final tone = Color.lerp(cool, RehabColors.muscle, load)!;

    final bounds = belly.getBounds();
    if (!bounds.isEmpty) {
      canvas.drawPath(
        belly,
        Paint()
          ..shader = RadialGradient(
            colors: [
              tone.withValues(alpha: 0.30 + 0.55 * load),
              tone.withValues(alpha: 0.10 + 0.30 * load),
            ],
          ).createShader(bounds),
      );
    }

    // The fibre line along the belly: enough to read as muscle rather than a
    // blob, and it tightens with the contraction.
    canvas.drawPath(
      belly,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0 + 1.4 * load
        ..color = tone.withValues(alpha: 0.45 + 0.4 * load),
    );

    // A tendon at each end, so the belly is anchored rather than floating.
    final tendon = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..color = RehabColors.inkFaint.withValues(alpha: 0.35);
    canvas.drawLine(shoulder + d * (len * 0.10), from, tendon);
    canvas.drawLine(to, elbow - d * (len * 0.06), tendon);
  }

  void _paintElbowJoint(Canvas canvas, Offset elbow, double w, Color limb) {
    // The elbow is the joint the patient is being asked about, so it is the
    // only one drawn as a joint: a filled cap with a lighter centre, which
    // reads as a hinge rather than a dot.
    canvas.drawCircle(elbow, w * 0.62,
        Paint()..color = Color.lerp(limb, RehabColors.bg, 0.35)!);
    canvas.drawCircle(
      elbow,
      w * 0.62,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..color = limb,
    );
    canvas.drawCircle(
        elbow, w * 0.22, Paint()..color = limb.withValues(alpha: 0.85));
  }

  /// A hand, as a short wedge continuing the forearm.
  ///
  /// Deliberately crude: two IMUs cannot track the wrist, and a detailed hand
  /// would imply they can. It is here to make the limb read as an arm and to
  /// show which way the forearm points, nothing more.
  void _paintHand(
      Canvas canvas, Offset elbow, Offset wrist, double wristW, Color limb) {
    final len = (wrist - elbow).distance;
    if (len <= 1) return;
    final d = (wrist - elbow) / len;
    final tip = wrist + d * (wristW * 1.5);
    final path = _segment(wrist, tip, wristW * 1.15, wristW * 0.95);
    canvas.drawPath(
        path, Paint()..color = Color.lerp(limb, RehabColors.bg, 0.45)!);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..color = limb.withValues(alpha: 0.9),
    );
  }

  // ── The ghost ──────────────────────────────────────────────────────────

  /// Where the arm should be, as an outline of the same silhouette.
  ///
  /// An outline makes the comparison a matter of overlap, which is read
  /// instantly, instead of two different shapes in roughly the same place.
  void _paintGhost(Canvas canvas, Offset shoulder, ArmPose pose,
      double upperLen, double foreLen) {
    final elbow = _elbowOf(pose, shoulder, upperLen);
    final wrist = _wristOf(pose, shoulder, upperLen, foreLen);

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..color = RehabColors.target.withValues(alpha: 0.85);

    canvas.drawPath(
        _segment(shoulder, elbow, upperLen * 0.34, upperLen * 0.24), paint);
    canvas.drawPath(
        _segment(elbow, wrist, upperLen * 0.24, upperLen * 0.17), paint);
    canvas.drawCircle(
      elbow,
      upperLen * 0.15,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..color = RehabColors.target.withValues(alpha: 0.7),
    );
  }

  /// Where the wrist has just been. Decays to nothing, so it reads as motion
  /// rather than as a second arm.
  void _paintTrail(
      Canvas canvas, Offset shoulder, double upperLen, double foreLen) {
    final n = trail.length;
    for (var i = 0; i < n; i++) {
      final age = i / (n - 1); // 0 oldest, 1 newest
      final pose = ArmPose(
          elbowAngleDeg: trail[i], upperArmDevDeg: actual.upperArmDevDeg);
      final wrist = _wristOf(pose, shoulder, upperLen, foreLen);
      canvas.drawCircle(
        wrist,
        1.0 + 2.6 * age,
        Paint()
          ..color = RehabColors.actual.withValues(alpha: 0.05 + 0.20 * age),
      );
    }
  }

  // ── Body and reference marks ───────────────────────────────────────────

  /// A hint of a body, so the pose reads as an arm attached to someone.
  void _paintTorso(Canvas canvas, Offset shoulder, double upperLen) {
    final lean = compFlags & compTrunk != 0;

    // Trunk, as a tapered shape rather than a line. It leans when the
    // firmware reports trunk lean, because the lean is a property of the body
    // and not of the arm.
    final hipOffset = lean ? upperLen * 0.26 : 0.0;
    final neck = shoulder + const Offset(0, -24);
    final hip = shoulder + Offset(hipOffset, upperLen * 2.0);
    final accent = lean ? RehabColors.bad : RehabColors.divider;

    final trunk = _segment(neck, hip, upperLen * 0.95, upperLen * 0.74);
    canvas.drawPath(
      trunk,
      Paint()..color = accent.withValues(alpha: lean ? 0.18 : 0.30),
    );
    canvas.drawPath(
      trunk,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = lean ? 2.5 : 1.6
        ..color = accent.withValues(alpha: lean ? 0.8 : 0.9),
    );

    // Neck and head.
    final head = shoulder + Offset(2 + hipOffset * 0.15, -52);
    canvas.drawLine(
      shoulder + const Offset(0, -18),
      head + const Offset(0, 16),
      Paint()
        ..strokeWidth = upperLen * 0.22
        ..strokeCap = StrokeCap.round
        ..color = RehabColors.divider.withValues(alpha: 0.30),
    );
    canvas.drawCircle(
        head, 20, Paint()..color = RehabColors.divider.withValues(alpha: 0.26));
    canvas.drawCircle(
      head,
      20,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..color = RehabColors.divider,
    );
  }

  /// The band the rep must travel through, drawn as an arc at the elbow, with
  /// the travelled part filled so the arc reads as progress and not decoration.
  void _paintRangeArc(
      Canvas canvas, Offset shoulder, double upperLen, double foreLen) {
    final elbow = shoulder + _dir(actual.upperArmDevDeg) * upperLen;
    final radius = foreLen * 0.82;
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
        ..color = RehabColors.good.withValues(alpha: 0.14)
        ..strokeWidth = 18
        ..strokeCap = StrokeCap.butt
        ..style = PaintingStyle.stroke,
    );

    final reached = actual.elbowAngleDeg.clamp(startAngleDeg, peakAngleDeg);
    if (reached > startAngleDeg) {
      canvas.drawArc(
        rect,
        a0,
        sweepStart(reached) - a0,
        false,
        Paint()
          ..color = RehabColors.good.withValues(alpha: 0.34)
          ..strokeWidth = 18
          ..strokeCap = StrokeCap.butt
          ..style = PaintingStyle.stroke,
      );
    }

    // The peak criterion: the line a rep must cross to count.
    final peakDir = _dir(actual.upperArmDevDeg + peakAngleDeg);
    canvas.drawLine(
      elbow + peakDir * (radius - 15),
      elbow + peakDir * (radius + 15),
      Paint()
        ..color = RehabColors.good
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round,
    );

    // And the therapist-set target, which is further out and not the
    // criterion — worth distinguishing so nobody reads the arc as the goal.
    final targetDir = _dir(actual.upperArmDevDeg + targetAngleDeg);
    canvas.drawLine(
      elbow + targetDir * (radius - 9),
      elbow + targetDir * (radius + 9),
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
      upperLen * 0.30,
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
      old.envelope != envelope ||
      old.compFlags != compFlags ||
      old.cueFlash != cueFlash ||
      old.peakAngleDeg != peakAngleDeg ||
      old.startAngleDeg != startAngleDeg ||
      old.trail.length != trail.length;
}

/// Where the arm should be at this instant of this rep phase.
///
/// Standing still at full extension is correct in READY and wrong halfway
/// through a concentric phase, so the ghost has to follow the device's own rep
/// state rather than show one fixed pose.
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

    // Coming back down. The shipping firmware counts on crossing below the
    // finish angle; the ESP-IDF firmware adds a confirming hold there.
    RepState.eccentric => finishAngleDeg,
    RepState.extendedHold => finishAngleDeg,
  };
  return ArmPose(elbowAngleDeg: elbow, upperArmDevDeg: 0.0);
}
