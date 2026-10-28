/// Tests for the pose visualisation.
///
/// Two things worth checking without a sleeve on the bench: that the ghost
/// pose follows the rep phase the way the firmware's state machine expects,
/// and that the painter survives every input the device can actually produce
/// — including the degenerate ones. A painter that throws mid-set takes the
/// whole patient view down, and it would do it at the worst possible moment.
library;

import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:rehabsense/protocol/config_tlv.dart';
import 'package:rehabsense/protocol/enums.dart';
import 'package:rehabsense/ui/arm_pose_painter.dart';

/// Paint onto a throwaway canvas and report whether it completed.
void paintOnce(ArmPosePainter painter, {ui.Size size = const ui.Size(380, 520)}) {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  painter.paint(canvas, size);
  recorder.endRecording().dispose();
}

ArmPosePainter painterFor({
  double elbow = 45,
  double dev = 0,
  RepState state = RepState.concentric,
  int compFlags = 0,
  bool activation = true,
  double cue = 0,
  double targetAngle = 110,
}) {
  return ArmPosePainter(
    actual: ArmPose(elbowAngleDeg: elbow, upperArmDevDeg: dev),
    target: targetPoseFor(
      state,
      startAngleDeg: 15,
      peakAngleDeg: targetAngle * CfgDefaults.peakFraction,
      finishAngleDeg: 10,
    ),
    repState: state,
    startAngleDeg: 15,
    peakAngleDeg: targetAngle * CfgDefaults.peakFraction,
    targetAngleDeg: targetAngle,
    shoulderLimitDeg: 20,
    activationOn: activation,
    compFlags: compFlags,
    cueFlash: cue,
  );
}

void main() {
  group('target pose follows the rep phase', () {
    const start = 15.0;
    const peak = 88.0; // 80% of 110, which is the criterion
    const finish = 10.0;

    ArmPose at(RepState s) => targetPoseFor(
          s,
          startAngleDeg: start,
          peakAngleDeg: peak,
          finishAngleDeg: finish,
        );

    test('at rest the goal is the extended position', () {
      expect(at(RepState.ready).elbowAngleDeg, finish);
    });

    test('while lifting the goal is the criterion, not the target angle', () {
      // 80% of the therapist-set target is what a rep must pass. Showing the
      // target itself as the goal would ask the patient for more than the
      // firmware requires, and every rep would look like a failure.
      expect(at(RepState.concentric).elbowAngleDeg, peak);
      expect(at(RepState.concentric).elbowAngleDeg, lessThan(110));
    });

    test('coming back down the goal is extension again', () {
      expect(at(RepState.eccentric).elbowAngleDeg, finish);
      expect(at(RepState.extendedHold).elbowAngleDeg, finish);
    });

    test('the target upper arm is always neutral', () {
      // Deviation from the calibrated neutral IS the shoulder-hike
      // compensation, so there is no deviation worth showing as a goal.
      for (final s in RepState.values) {
        expect(at(s).upperArmDevDeg, 0.0, reason: 'state $s');
      }
    });
  });

  group('shoulder flag', () {
    test('raises on the device flag even when the angle looks fine', () {
      // The device is authoritative. If it says shoulder, that is shoulder,
      // whatever the instantaneous deviation reads.
      final p = painterFor(dev: 2, compFlags: compShoulder);
      expect(p.shoulderFlagged, isTrue);
    });

    test('raises on deviation past the configured limit', () {
      expect(painterFor(dev: 25).shoulderFlagged, isTrue);
      expect(painterFor(dev: -25).shoulderFlagged, isTrue,
          reason: 'deviation the other way is still deviation');
      expect(painterFor(dev: 12).shoulderFlagged, isFalse);
    });
  });

  group('painter survives everything the device can send', () {
    test('a full sweep of the elbow range', () {
      for (var a = -20.0; a <= 180.0; a += 2.5) {
        expect(() => paintOnce(painterFor(elbow: a)), returnsNormally,
            reason: 'elbow $a');
      }
    });

    test('a full sweep of upper-arm deviation', () {
      for (var d = -90.0; d <= 90.0; d += 5) {
        expect(() => paintOnce(painterFor(dev: d)), returnsNormally,
            reason: 'deviation $d');
      }
    });

    test('every rep state and compensation combination', () {
      for (final s in RepState.values) {
        for (var flags = 0; flags <= 7; flags++) {
          expect(
            () => paintOnce(painterFor(state: s, compFlags: flags)),
            returnsNormally,
            reason: 'state $s flags $flags',
          );
        }
      }
    });

    test('the cue animation across its whole range', () {
      for (var c = 0.0; c <= 1.0; c += 0.05) {
        expect(() => paintOnce(painterFor(cue: c)), returnsNormally);
      }
    });

    // The cases that actually break painters in the field.
    test('a tiny canvas', () {
      expect(() => paintOnce(painterFor(), size: const ui.Size(60, 60)),
          returnsNormally);
    });

    test('a zero-area canvas, as happens for one frame during layout', () {
      expect(() => paintOnce(painterFor(), size: ui.Size.zero),
          returnsNormally);
    });

    test('a degenerate configuration where the rep band has no width', () {
      // start == peak. Possible if someone drags the target angle down far
      // enough, and it makes the range arc a zero-length sweep.
      final p = ArmPosePainter(
        actual: const ArmPose(elbowAngleDeg: 15, upperArmDevDeg: 0),
        target: const ArmPose(elbowAngleDeg: 15, upperArmDevDeg: 0),
        repState: RepState.ready,
        startAngleDeg: 15,
        peakAngleDeg: 15,
        targetAngleDeg: 15,
        shoulderLimitDeg: 20,
        activationOn: false,
        compFlags: 0,
      );
      expect(() => paintOnce(p), returnsNormally);
    });

    test('an inverted band, where finish sits above peak', () {
      final p = ArmPosePainter(
        actual: const ArmPose(elbowAngleDeg: 40, upperArmDevDeg: 0),
        target: const ArmPose(elbowAngleDeg: 40, upperArmDevDeg: 0),
        repState: RepState.concentric,
        startAngleDeg: 90,
        peakAngleDeg: 20,
        targetAngleDeg: 25,
        shoulderLimitDeg: 20,
        activationOn: true,
        compFlags: 0,
      );
      expect(() => paintOnce(p), returnsNormally);
    });
  });

  group('repaint gating', () {
    test('repaints when the angle moves', () {
      expect(painterFor(elbow: 40).shouldRepaint(painterFor(elbow: 41)),
          isTrue);
    });

    test('repaints when a compensation is raised', () {
      expect(
        painterFor().shouldRepaint(painterFor(compFlags: compTrunk)),
        isTrue,
      );
    });

    test('does not repaint when nothing a viewer can see has changed', () {
      // Features arrive at 20 Hz; repainting on identical frames is pure
      // waste on a phone that is also holding a BLE link.
      expect(painterFor().shouldRepaint(painterFor()), isFalse);
    });
  });
}
