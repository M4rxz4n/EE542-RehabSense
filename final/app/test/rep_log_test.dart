/// The rep log and the phase reconstruction.
///
/// [PhaseTimer] is the one place in this app that produces a number the device
/// did not report, so it is the one place where a bug cannot be caught by
/// comparing against the firmware. These tests are the substitute.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rehabsense/protocol/commands.dart';
import 'package:rehabsense/protocol/enums.dart';
import 'package:rehabsense/protocol/frames.dart' show ProtocolError;
import 'package:rehabsense/session/rep_log.dart';

/// Microseconds, so the arithmetic in the tests reads as seconds.
int s(double seconds) => (seconds * 1e6).round();

void main() {
  group('PhaseTimer', () {
    test('a plain curl splits into lift, hold and lower', () {
      final t = PhaseTimer();
      // 1.2 s lifting, 0.4 s at the peak, 1.6 s lowering, at 20 Hz.
      var now = 0.0;
      void feed(RepState state, double seconds) {
        for (var i = 0; i < (seconds * 20).round(); i++) {
          t.onFrame(state, s(now));
          now += 0.05;
        }
      }

      t.onFrame(RepState.ready, s(now));
      feed(RepState.concentric, 1.2);
      feed(RepState.peak, 0.4);
      feed(RepState.eccentric, 1.6);
      t.onFrame(RepState.ready, s(now));

      final p = t.take();
      expect(p, isNotNull);
      // Within one frame period: the split is quantised at 20 Hz, which is
      // stated wherever it is shown.
      expect(p!.liftS, closeTo(1.2, 0.1));
      expect(p.holdS, closeTo(0.4, 0.1));
      expect(p.lowerS, closeTo(1.6, 0.1));
      expect(p.totalS, closeTo(3.2, 0.2));
    });

    test('a long gap is not attributed to whichever phase was current', () {
      // Dropped frames or a reconnection. Counting the gap would silently
      // inflate one phase, and the inflated number would look like a patient
      // pausing mid-rep.
      final t = PhaseTimer();
      t.onFrame(RepState.concentric, s(0));
      t.onFrame(RepState.concentric, s(0.05));
      // A five-second hole in the stream.
      t.onFrame(RepState.concentric, s(5.05));
      t.onFrame(RepState.ready, s(5.10));

      final p = t.take();
      expect(p, isNotNull);
      expect(p!.liftS, lessThan(0.5),
          reason: 'the 5 s gap must not become 5 s of lifting');
    });

    test('take() is once only', () {
      final t = PhaseTimer();
      t.onFrame(RepState.concentric, s(0));
      t.onFrame(RepState.concentric, s(0.5));
      t.onFrame(RepState.ready, s(0.55));
      expect(t.take(), isNotNull);
      expect(t.take(), isNull, reason: 'the second rep must start from zero');
    });

    test('nothing timed yields nothing, not a row of zeros', () {
      // A zero split would be drawn as three zero-length segments, which
      // reads as a measurement. Null is drawn as absent.
      expect(PhaseTimer().take(), isNull);
    });

    test('out-of-order timestamps are ignored rather than counted backwards',
        () {
      final t = PhaseTimer();
      t.onFrame(RepState.concentric, s(1.0));
      t.onFrame(RepState.concentric, s(0.5)); // earlier than the last
      t.onFrame(RepState.ready, s(1.1));
      final p = t.take();
      // Either null or a small positive number; never negative.
      if (p != null) {
        expect(p.liftS, greaterThanOrEqualTo(0));
      }
    });

    test('the extended hold counts as lowering', () {
      // The ESP-IDF firmware's confirming hold happens at the extended
      // position, so it belongs to the return, not to a fourth phase.
      expect(RepState.extendedHold.isLower, isTrue);
      expect(RepState.extendedHold.isHold, isFalse);
      expect(RepState.peak.isHold, isTrue);
      expect(RepState.concentric.isLift, isTrue);
    });

    test('clear resets the state as well as the totals', () {
      final t = PhaseTimer();
      t.onFrame(RepState.concentric, s(10));
      t.clear();
      t.onFrame(RepState.concentric, s(0));
      t.onFrame(RepState.ready, s(0.05));
      final p = t.take();
      if (p != null) expect(p.totalS, lessThan(0.2));
    });
  });

  group('RepPhases', () {
    test('the controlled band is wider than the sleeve\'s tempo score', () {
      // Deliberately: the sleeve asks whether a rep scored well, this asks
      // whether the movement was deliberate.
      expect(
        const RepPhases(liftS: 2, holdS: 1, lowerS: 2).isControlled,
        isTrue,
      );
      expect(
        const RepPhases(liftS: 0.5, holdS: 0.2, lowerS: 0.5).isControlled,
        isFalse,
        reason: '1.2 s total is below the 4 s floor',
      );
      expect(
        const RepPhases(liftS: 4, holdS: 3, lowerS: 4).isControlled,
        isFalse,
        reason: '11 s total is above the 9 s ceiling',
      );
    });

    test('round-trips through JSON', () {
      const p = RepPhases(liftS: 1.25, holdS: 0.5, lowerS: 1.75);
      final back = RepPhases.fromJson(p.toJson())!;
      expect(back.liftS, p.liftS);
      expect(back.holdS, p.holdS);
      expect(back.lowerS, p.lowerS);
    });
  });

  group('RepRow outcomes', () {
    RepComplete rep({
      int index = 1,
      int score = 90,
      double rom = 0.95,
      double peak = 95,
      int flags = 0,
      int ms = 4000,
    }) =>
        RepComplete(
          index: index,
          score: score,
          romFraction: rom,
          cocontraction: 0,
          smoothness: 0.8,
          holdSteadiness: 0.8,
          peakAngleDeg: peak,
          compFlags: flags,
          durationMs: ms,
        );

    test('on target when the full target was reached and nothing flagged', () {
      final r = RepRow.fromEvent(rep(), 0,
          targetAngleDeg: 90, tempoMinS: 3, tempoMaxS: 8);
      expect(r.outcome, RepOutcome.onTarget);
      expect(r.counted, isTrue);
      expect(r.flagged, isFalse);
    });

    test('a compensation flag wins over pace and range', () {
      final r = RepRow.fromEvent(rep(flags: compShoulder), 0,
          targetAngleDeg: 90, tempoMinS: 3, tempoMaxS: 8);
      expect(r.outcome, RepOutcome.flagged);
      // Still counted. A patient who gets no credit for a hard-won
      // compensated rep learns the device is broken, not that their form
      // needs work.
      expect(r.counted, isTrue);
      expect(r.compensations, contains('shoulder hike'));
    });

    test('a rushed rep is counted with the pace marked', () {
      final r = RepRow.fromEvent(rep(ms: 1200), 0,
          targetAngleDeg: 90, tempoMinS: 3, tempoMaxS: 8);
      expect(r.outcome, RepOutcome.countedPaceOff);
      expect(r.counted, isTrue);
    });

    test('reaching the criterion but not the full target still counts', () {
      // 76° passes the criterion for a 95° target; it is not "on target".
      final r = RepRow.fromEvent(rep(peak: 80), 0,
          targetAngleDeg: 95, tempoMinS: 3, tempoMaxS: 8);
      expect(r.counted, isTrue);
      expect(r.outcome, isNot(RepOutcome.onTarget));
    });

    test('the printed extras fill in without disturbing the event fields', () {
      final r = RepRow.fromEvent(rep(score: 97), 0,
              targetAngleDeg: 90, tempoMinS: 3, tempoMaxS: 8)
          .withPrintedExtras(tempoText: 'slow', bicepsPercent: 71);
      expect(r.score, 97, reason: 'the event is authoritative');
      expect(r.tempoText, 'slow');
      expect(r.bicepsPercent, 71);
    });

    test('a partial has no index and no score', () {
      final r = RepRow(
        atUs: 0,
        outcome: RepOutcome.partial,
        peakAngleDeg: 45,
        durationS: 0,
        neededDeg: 72,
      );
      expect(r.index, isNull);
      expect(r.score, isNull);
      expect(r.counted, isFalse);
      // And it explains itself in numbers the patient can act on.
      expect(r.why.first, contains('45'));
      expect(r.why.first, contains('72'));
    });

    test('a passive lift names the activation ratio', () {
      final r = RepRow(
        atUs: 0,
        outcome: RepOutcome.passive,
        peakAngleDeg: 90,
        durationS: 0,
        bicepsPercent: 18,
      );
      expect(r.why.first, contains('18%'));
      expect(r.why.first.toLowerCase(), contains('lifted for you'));
    });

    test('why() lists the coaching for every flag raised', () {
      final r = RepRow(
        atUs: 0,
        outcome: RepOutcome.flagged,
        index: 2,
        score: 60,
        romPercent: 90,
        peakAngleDeg: 88,
        durationS: 4,
        compFlags: compShoulder | compDrop,
      );
      final joined = r.why.join(' ');
      expect(joined, contains('elbow by your side'));
      expect(joined, contains('Lower slowly'));
    });

    test('round-trips through JSON', () {
      final r = RepRow(
        atUs: 1234567,
        outcome: RepOutcome.flagged,
        index: 5,
        score: 72,
        romPercent: 88,
        peakAngleDeg: 84.5,
        durationS: 5.25,
        compFlags: compSwing,
        tempoText: 'slow',
        bicepsPercent: 63,
        phases: const RepPhases(liftS: 1.5, holdS: 0.4, lowerS: 3.3),
        setNumber: 2,
        fatigue: const FatigueSnapshot(
          rangePercent: 82,
          effortPercent: 130,
          timePercent: 145,
          range: true,
          effort: true,
          slow: true,
        ),
      );
      final back = RepRow.fromJson(r.toJson());
      expect(back.atUs, r.atUs);
      expect(back.outcome, r.outcome);
      expect(back.index, r.index);
      expect(back.score, r.score);
      expect(back.peakAngleDeg, r.peakAngleDeg);
      expect(back.compFlags, r.compFlags);
      expect(back.tempoText, r.tempoText);
      expect(back.bicepsPercent, r.bicepsPercent);
      expect(back.phases!.liftS, 1.5);
      expect(back.setNumber, 2);
      expect(back.fatigue!.signs, 3);
    });

    test('a row from a future version of the format degrades rather than '
        'throwing', () {
      // A session saved by a later build must not take the progress tab down.
      final back = RepRow.fromJson(const {
        'at_us': 1,
        'outcome': 'something_new',
        'peak_angle_deg': 50,
      });
      expect(back.outcome, RepOutcome.onTarget);
      expect(back.peakAngleDeg, 50);
    });
  });

  group('FatigueSnapshot', () {
    test('signs follow the sleeve\'s own thresholds', () {
      expect(FatigueSnapshot.rangeThresholdPercent, FatigueThresholds.range);
      expect(FatigueSnapshot.effortThresholdPercent, FatigueThresholds.effort);
      expect(FatigueSnapshot.timeThresholdPercent, FatigueThresholds.time);
    });

    test('the summary names which signs fired', () {
      const f = FatigueSnapshot(
        rangePercent: 80,
        effortPercent: 130,
        timePercent: 100,
        range: true,
        effort: true,
        slow: false,
      );
      expect(f.signs, 2);
      expect(f.summary, contains('range'));
      expect(f.summary, contains('effort'));
      expect(f.summary, isNot(contains('time')));
    });

    test('no signs says so plainly', () {
      const f = FatigueSnapshot(
        rangePercent: 100,
        effortPercent: 100,
        timePercent: 100,
        range: false,
        effort: false,
        slow: false,
      );
      expect(f.anySign, isFalse);
      expect(f.summary.toLowerCase(), contains('no sign'));
    });
  });

  group('event payloads', () {
    test('REP_ABANDONED carries the NEXT index, not this attempt\'s', () {
      // A partial consumes no number, which is why the table shows a dash.
      final b = ByteData(4)
        ..setUint16(0, 8, Endian.little)
        ..setInt16(2, 455, Endian.little);
      final p = RepAbandoned.tryParse(b.buffer.asUint8List())!;
      expect(p.nextIndex, 8);
      expect(p.peakAngleDeg, closeTo(45.5, 0.01));
    });

    test('a short REP_ABANDONED payload is rejected, not guessed at', () {
      expect(RepAbandoned.tryParse(Uint8List(2)), isNull);
    });

    test('FATIGUE_WARN 9 means three partials in a row, not nine signs', () {
      // Reading the sentinel as a count would display catastrophe.
      final b = ByteData(4)
        ..setInt16(0, 9, Endian.little)
        ..setUint16(2, 12, Endian.little);
      final w = FatigueWarn.tryParse(b.buffer.asUint8List())!;
      expect(w.isThreePartials, isTrue);
      expect(w.signCount, 0);
      expect(w.endsSet, isFalse);
      expect(w.label.toLowerCase(), contains('three reps'));
    });

    test('FATIGUE_WARN with two signs ends the set', () {
      final b = ByteData(4)
        ..setInt16(0, 2, Endian.little)
        ..setUint16(2, 7, Endian.little);
      final w = FatigueWarn.tryParse(b.buffer.asUint8List())!;
      expect(w.endsSet, isTrue);
      expect(w.signCount, 2);
      expect(w.totalReps, 7);
    });

    test('FATIGUE_WARN with one sign is only a note', () {
      final b = ByteData(4)
        ..setInt16(0, 1, Endian.little)
        ..setUint16(2, 5, Endian.little);
      expect(FatigueWarn.tryParse(b.buffer.asUint8List())!.endsSet, isFalse);
    });

    test('SET_COMPLETE with no payload means stopped, not zero reps', () {
      // "The set ended and we are not told how many" is not the same claim as
      // "the set ended with no reps".
      final stopped = SetComplete.parse(Uint8List(0));
      expect(stopped.wasStopped, isTrue);
      expect(stopped.repsInSet, isNull);

      final b = ByteData(2)..setUint16(0, 10, Endian.little);
      final finished = SetComplete.parse(b.buffer.asUint8List());
      expect(finished.wasStopped, isFalse);
      expect(finished.repsInSet, 10);
    });

    test('CALIB_PHASE_DONE at 0% is a start, not a completion', () {
      // Treating every one of these as a completion marks each step done the
      // moment it begins, which puts the display a step ahead of the patient.
      final start = CalibProgress.tryParse(
          Uint8List.fromList([CalibPhase.biceps.wire, 0]))!;
      expect(start.started, isTrue);
      expect(start.finished, isFalse);
      expect(start.phase, CalibPhase.biceps);

      final done = CalibProgress.tryParse(
          Uint8List.fromList([CalibPhase.biceps.wire, 100]))!;
      expect(done.finished, isTrue);
    });

    test('a one-byte CALIB_PHASE_DONE is treated as finished', () {
      // Older firmware sent the phase alone.
      final m = CalibProgress.tryParse(
          Uint8List.fromList([CalibPhase.rest.wire]))!;
      expect(m.finished, isTrue);
    });
  });

  group('TEXT command', () {
    test('builds with the right opcode', () {
      final p = Commands.text('i');
      expect(p.first, Cmd.text);
      expect(p.length, 2);
      expect(p[1], 'i'.codeUnitAt(0));
    });

    test('refuses a command longer than the sleeve\'s line buffer', () {
      // The sleeve drops the overflow silently, so a long string would arrive
      // as a different but perfectly valid command.
      expect(() => Commands.text('t' * 40), throwsA(isA<ProtocolError>()));
    });

    test('refuses non-ASCII and empty commands', () {
      expect(() => Commands.text('t110°'), throwsA(isA<ProtocolError>()));
      expect(() => Commands.text('   '), throwsA(isA<ProtocolError>()));
    });

    test('the convenience builders send what the sleeve expects', () {
      expect(Commands.calibNext().sublist(1), 'n'.codeUnits);
      expect(Commands.calibGo().sublist(1), 'g'.codeUnits);
      expect(Commands.reZero().sublist(1), 'z'.codeUnits);
      expect(Commands.requestStatusLines().sublist(1), 'i'.codeUnits);
      expect(Commands.setTargetLocked(110).sublist(1), 't110'.codeUnits);
      expect(Commands.hapticByIndex(11).sublist(1), 'h11'.codeUnits);
    });
  });

  group('compensation flags', () {
    test('drop has its own bit and its own coaching', () {
      // Swinging is a fault of the lift; dropping is a fault of the return,
      // where a weak limb usually fails first. They need different coaching,
      // so they cannot share a name.
      expect(compDrop, isNot(compSwing));
      expect(compNames(compDrop), ['dropped']);
      expect(compAdvice[compDrop], isNot(compAdvice[compSwing]));
    });

    test('names and advice stay in step', () {
      for (final bit in [compShoulder, compTrunk, compSwing, compDrop]) {
        expect(compNames(bit), hasLength(1), reason: 'bit $bit');
        expect(compAdviceFor(bit), hasLength(1), reason: 'bit $bit');
      }
    });
  });
}
