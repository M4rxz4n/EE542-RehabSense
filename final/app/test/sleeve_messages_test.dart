/// The printed-line parser, against the firmware's own output.
///
/// Every sample here is built from a `Log.printf` format string in the
/// firmware, named in a comment beside it. That is what makes these tests
/// worth having: a regex that silently stops matching does not throw, it
/// produces a line classified as `other` — indistinguishable from a line the
/// firmware never sent. The symptom is an empty fatigue chart, days later,
/// with nothing in the logs to explain it.
///
/// `tool/check_message_patterns.py` runs the same corpus against the extracted
/// regexes without a Dart SDK. This is the version that runs in CI.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rehabsense/protocol/sleeve_messages.dart';

Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('reassembly', () {
    test('one notification holding one whole line', () {
      final a = SleeveTextAssembler();
      expect(a.add(bytes('# REP 1  peak=90.0 deg\n')),
          ['# REP 1  peak=90.0 deg']);
    });

    test('several short lines sharing one notification', () {
      // What the firmware actually does: it packs whole lines up to 180 bytes.
      final a = SleeveTextAssembler();
      final lines = a.add(bytes('Step 1 done.\nStep 2 done.\nStep 3 done.\n'));
      expect(lines, ['Step 1 done.', 'Step 2 done.', 'Step 3 done.']);
    });

    test('one line split across notifications', () {
      final a = SleeveTextAssembler();
      expect(a.add(bytes('# REP 1  peak=')), isEmpty);
      expect(a.add(bytes('90.0 deg  duration=4.0 s\n')),
          ['# REP 1  peak=90.0 deg  duration=4.0 s']);
    });

    test('a notification that ends mid-line holds the fragment back', () {
      final a = SleeveTextAssembler();
      expect(a.add(bytes('Step 1 done.\n=== Calib')), ['Step 1 done.']);
      expect(a.add(bytes('ration done ===\n')), ['=== Calibration done ===']);
    });

    test('flush emits an unterminated tail', () {
      // The link usually drops while something is being said about it, so the
      // last fragment is often the interesting one.
      final a = SleeveTextAssembler();
      a.add(bytes('# FAULT: IMU read fai'));
      expect(a.flush(), ['# FAULT: IMU read fai']);
      expect(a.flush(), isEmpty, reason: 'flush must not repeat itself');
    });

    test('blank lines are dropped', () {
      // The firmware prints "\n" freely as a separator.
      final a = SleeveTextAssembler();
      expect(a.add(bytes('\n\n')), isEmpty);
    });

    test('a fragment that never terminates is bounded, not buffered for ever',
        () {
      final a = SleeveTextAssembler();
      final huge = 'x' * (SleeveTextAssembler.maxPartialChars + 10);
      // Emitted as its own line rather than growing without limit: visible
      // and bounded beats invisible and unbounded.
      expect(a.add(bytes(huge)), hasLength(1));
    });

    test('a split multi-byte sequence does not throw', () {
      // A notification boundary can fall inside a UTF-8 sequence. One
      // replacement character beats losing the line.
      final a = SleeveTextAssembler();
      final degrees = utf8.encode('90° bend\n');
      a.add(Uint8List.fromList(degrees.sublist(0, 3)));
      expect(() => a.add(Uint8List.fromList(degrees.sublist(3))),
          returnsNormally);
    });
  });

  group('# LIVE (comms.cpp)', () {
    test('every field', () {
      final m = parseSleeveLine('# LIVE calibrated=1 set=2/3 reps=7 '
          'partials=1 resting=0 done=0 paused=0 pace=1');
      expect(m.kind, SleeveMessageKind.live);
      expect(m.flag('calibrated'), isTrue);
      expect(m.int_('set'), 2);
      expect(m.int_('sets'), 3);
      expect(m.int_('reps'), 7);
      expect(m.int_('partials'), 1);
      expect(m.flag('resting'), isFalse);
      expect(m.flag('paceOn'), isTrue);
    });

    test('firmware older than the 28 Oct update, with no pace field', () {
      final m = parseSleeveLine('# LIVE calibrated=0 set=1/3 reps=0 '
          'partials=0 resting=1 done=0 paused=1');
      expect(m.kind, SleeveMessageKind.live);
      expect(m.flag('calibrated'), isFalse);
      expect(m.flag('resting'), isTrue);
      expect(m.flag('paused'), isTrue);
      // Absent, so false — not a parse failure.
      expect(m.flag('paceOn'), isFalse);
    });
  });

  group('# PARAMS (calib.cpp, comms.cpp)', () {
    test('the criterion is derived, not assumed', () {
      final m = parseSleeveLine('# PARAMS target=95 peak=0.80 start=15 '
          'hyst=5 tempo=3.0-8.0 muscle=10 sets=3x10 rest=60');
      expect(m.kind, SleeveMessageKind.params);
      expect(m.num_('targetDeg'), 95);
      expect(m.num_('peakFraction'), 0.80);
      // The angle a rep must actually pass: the product, not the target.
      expect(m.num_('peakDeg'), closeTo(76, 0.01));
      expect(m.num_('tempoMinS'), 3.0);
      expect(m.num_('tempoMaxS'), 8.0);
      expect(m.int_('repsPerSet'), 10);
      expect(m.int_('restS'), 60);
    });
  });

  group('# REP (rep.cpp)', () {
    test('a clean rep, with the two fields the event lacks', () {
      final m = parseSleeveLine('# REP 3  peak=95.0 deg  duration=4.2 s  '
          'rom=100  tempo=100 (ok)  score=100  biceps=78%');
      expect(m.kind, SleeveMessageKind.rep);
      expect(m.int_('index'), 3);
      expect(m.num_('peakDeg'), 95.0);
      expect(m.num_('durationS'), 4.2);
      expect(m.int_('score'), 100);
      // Neither of these appears in EVT_REP_COMPLETE.
      expect(m.str('tempoText'), 'ok');
      expect(m.num_('bicepsPct'), 78);
      expect(m.flag('flagged'), isFalse);
    });

    test('a flagged rep with a two-word tempo verdict', () {
      final m = parseSleeveLine('# REP 11  peak=62.5 deg  duration=1.8 s  '
          'rom=65  tempo=93 (too fast)  score=79  FLAGGED  flags=swing  '
          'biceps=55%');
      expect(m.int_('index'), 11);
      expect(m.str('tempoText'), 'too fast');
      expect(m.flag('flagged'), isTrue);
      expect(m.str('flagText'), 'swing');
    });

    test('a two-digit duration', () {
      final m = parseSleeveLine('# REP 4  peak=88.0 deg  duration=11.4 s  '
          'rom=92  tempo=83 (slow)  score=87  biceps=61%');
      expect(m.num_('durationS'), 11.4);
      expect(m.str('tempoText'), 'slow');
    });

    test('a line that lost its biceps field still parses', () {
      // A dropped notification should cost one field, not the whole line.
      final m = parseSleeveLine('# REP 2  peak=91.0 deg  duration=3.9 s  '
          'rom=96  tempo=100 (ok)  score=98');
      expect(m.kind, SleeveMessageKind.rep);
      expect(m.int_('index'), 2);
      expect(m.num_('bicepsPct'), isNull);
    });
  });

  group('partial and rejected reps (rep.cpp)', () {
    test('a partial carries the peak and what was needed', () {
      final m = parseSleeveLine('# Partial rep (peak 45 deg, needed 72)');
      expect(m.kind, SleeveMessageKind.partial);
      expect(m.num_('peakDeg'), 45);
      expect(m.num_('neededDeg'), 72);
      expect(m.flag('passive'), isFalse);
    });

    test('a passive lift is a partial, and says so', () {
      final m = parseSleeveLine('# NOT COUNTED [FC2]: peak 90 deg, but the '
          'biceps was working for only 20% of the lift (needs 60%).');
      expect(m.kind, SleeveMessageKind.partial);
      expect(m.flag('passive'), isTrue);
      expect(m.num_('peakDeg'), 90);
      expect(m.num_('bicepsPct'), 20);
      expect(m.num_('neededBicepsPct'), 60);
    });
  });

  group('[FT1] fatigue (rep.cpp)', () {
    test('no signs', () {
      final m = parseSleeveLine('#   [FT1] vs your first reps: range 88%, '
          'effort 112%, time 105%');
      expect(m.kind, SleeveMessageKind.fatigueTrend);
      expect(m.num_('rangePct'), 88);
      expect(m.num_('effortPct'), 112);
      expect(m.num_('timePct'), 105);
      expect(m.int_('signs'), 0);
      expect(m.flag('anySign'), isFalse);
    });

    test('all three signs', () {
      final m = parseSleeveLine('#   [FT1] vs your first reps: range 72%, '
          'effort 141%, time 155%  RANGE  EFFORT  SLOW');
      expect(m.int_('signs'), 3);
      expect(m.flag('range'), isTrue);
      expect(m.flag('effort'), isTrue);
      expect(m.flag('slow'), isTrue);
    });

    test('one sign, named', () {
      final m = parseSleeveLine('#   [FT1] vs your first reps: range 80%, '
          'effort 110%, time 120%  RANGE');
      expect(m.int_('signs'), 1);
      expect(m.flag('range'), isTrue);
      expect(m.flag('effort'), isFalse);
    });
  });

  group('form faults (rep.cpp)', () {
    test('[FC4] shoulder, with the measured tilt', () {
      final m = parseSleeveLine('#   [FC4] Your upper arm moved 25 deg: keep '
          'your elbow by your side and sit tall (-20).');
      expect(m.kind, SleeveMessageKind.formFault);
      expect(m.str('code'), 'FC4');
      expect(m.num_('tiltDeg'), 25);
    });

    test('[FC5] drop, with the measured rate', () {
      final m = parseSleeveLine("#   [FC5] Lowered at 180 deg/s: lower "
          "slowly, don't let it drop (-10).");
      expect(m.str('code'), 'FC5');
      expect(m.num_('dropDps'), 180);
    });

    test('[FC3] swing', () {
      final m = parseSleeveLine('#   [FC3] Swinging: lift slowly, using your '
          'biceps rather than momentum (-15).');
      expect(m.kind, SleeveMessageKind.formFault);
      expect(m.str('code'), 'FC3');
    });

    test('[FC1] is calibration, not a fault', () {
      // It reports the activation threshold during calibration. Classifying
      // it as a fault would put a spurious entry in the therapist's flags.
      final m = parseSleeveLine('[FC1] Rest EMG noise 3.2 mV (SD)');
      expect(m.kind, SleeveMessageKind.calibration);
    });
  });

  group('guided pace (pace.cpp)', () {
    test('each phase', () {
      for (final (line, phase) in const [
        ('# [GP1] >> UP: pull up and squeeze (2 beats)', 'UP'),
        ('# [GP1] >> HOLD at the top (2 beats)', 'HOLD'),
        ('# [GP1] >> DOWN: lower slowly (2 beats)', 'DOWN'),
        ('# [GP1] >> RELAX, arm straight (2 beats)', 'RELAX'),
      ]) {
        final m = parseSleeveLine(line);
        expect(m.kind, SleeveMessageKind.paceePhase, reason: line);
        expect(m.str('phase'), phase, reason: line);
      }
    });

    test('[GP2] waiting for a straight arm', () {
      final m = parseSleeveLine(
          '# [GP2] Waiting: straighten and relax your arm (now 32 deg)');
      expect(m.kind, SleeveMessageKind.paceePhase);
      expect(m.str('phase'), 'WAIT');
    });

    test('[GP3] verdict', () {
      expect(parseSleeveLine('#   [GP3] Right on the beat. Well done!')
          .flag('onBeat'), isTrue);
      expect(parseSleeveLine('#   [GP3] Try to reach the top by the end of UP.')
          .flag('onBeat'), isFalse);
    });
  });

  group('auto-pause (autopause.cpp)', () {
    test('[AP1] paused, [AP2] resumed', () {
      expect(
        parseSleeveLine('[AP1] Paused: no movement for 60 s. Take as long as '
                'you need.')
            .flag('paused'),
        isTrue,
      );
      expect(
        parseSleeveLine('[AP2] Welcome back! (paused 83 s) Carry on with set '
                '2: 4 of 10 done.')
            .flag('paused'),
        isFalse,
      );
    });
  });

  group('calibration (calib.cpp)', () {
    test('a prompt is distinguished from its countdown', () {
      final prompt = parseSleeveLine('>> Hold your arm straight and still');
      expect(prompt.kind, SleeveMessageKind.calibration);
      expect(prompt.str('prompt'), 'Hold your arm straight and still');
      expect(prompt.flag('countdown'), isFalse);

      // The countdown must not replace the prompt on screen.
      final counting = parseSleeveLine('>> Arm relaxed in 3...');
      expect(counting.flag('countdown'), isTrue);
    });

    test('step completion', () {
      final m = parseSleeveLine('Step 3 done. Now relax your arm and let it '
          'hang straight.');
      expect(m.int_('step'), 3);
      expect(m.flag('stepDone'), isTrue);
    });

    test('the headers are told apart', () {
      expect(parseSleeveLine('=== Calibration ===').flag('begin'), isTrue);
      expect(parseSleeveLine('=== Calibration done ===').flag('done'), isTrue);
      expect(
        parseSleeveLine('=== Calibration stopped: aborted from the app. Type '
                'c (or press BOOT) to calibrate again. ===')
            .flag('stopped'),
        isTrue,
      );
    });

    test('the comfortable bend and the target it chose', () {
      final m = parseSleeveLine('Comfortable bend 95 deg: target 95 deg '
          '(a rep counts from 76 deg)');
      expect(m.kind, SleeveMessageKind.calibration);
      expect(m.num_('bendDeg'), 95);
      expect(m.num_('targetDeg'), 95);
    });

    test('the eased-target variant, with "only"', () {
      final m = parseSleeveLine('Comfortable bend only 55 deg: keeping target '
          '90 deg. Ask your therapist to set it (t<deg>).');
      expect(m.num_('bendDeg'), 55);
      expect(m.num_('targetDeg'), 90);
    });
  });

  group('EMG test (emgtest.cpp)', () {
    test('rest, with printf width padding', () {
      // %6.0f and %5.1f pad with spaces, which the pattern has to tolerate.
      final m = parseSleeveLine('# REST     mean    120 mV   '
          'noise (SD)   3.4 mV   range   98.. 145 mV');
      expect(m.kind, SleeveMessageKind.emgTest);
      expect(m.str('part'), 'rest');
      expect(m.num_('meanMv'), 120);
      expect(m.num_('noiseSdMv'), 3.4);
    });

    test('squeeze', () {
      final m = parseSleeveLine('# SQUEEZE  mean    980 mV   peak 1240 mV   '
          'rise above rest   860 mV');
      expect(m.str('part'), 'squeeze');
      expect(m.num_('peakMv'), 1240);
      expect(m.num_('riseMv'), 860);
    });

    test('SNR and verdict', () {
      expect(parseSleeveLine('# SNR      24.0 dB (squeeze rise / rest noise)')
          .num_('snrDb'), 24.0);
      final v = parseSleeveLine('# FAIL  SNR under 10 dB: rest and squeeze '
          'are hard to tell apart.');
      expect(v.str('verdict'), 'FAIL');
      expect(v.isConcerning, isTrue);
    });
  });

  group('session flow (rep.cpp)', () {
    test('the rest countdown prints bare seconds', () {
      expect(parseSleeveLine('60').num_('restSecondsLeft'), 60);
      final ready = parseSleeveLine('Ready! 10');
      expect(ready.num_('restSecondsLeft'), 10);
      expect(ready.flag('ready'), isTrue);
    });

    test('completion and stopping', () {
      expect(
        parseSleeveLine('# SESSION COMPLETE: 30 reps in 3 sets. Excellent '
                'work, rest your arm now.')
            .flag('sessionComplete'),
        isTrue,
      );
      expect(
        parseSleeveLine('# SESSION STOPPED from the app: 12 reps.')
            .flag('sessionStopped'),
        isTrue,
      );
    });
  });

  group('classification does not collide', () {
    test('a REP line is never read as a partial', () {
      final m = parseSleeveLine('# REP 3  peak=95.0 deg  duration=4.2 s  '
          'rom=100  tempo=100 (ok)  score=100  biceps=78%');
      expect(m.kind, SleeveMessageKind.rep);
    });

    test('set progress is never read as a rep', () {
      expect(parseSleeveLine('#   Set 2: 7 of 10').kind,
          SleeveMessageKind.setProgress);
    });

    test('"Rep start!" is session flow, not a countdown', () {
      expect(parseSleeveLine('Rep start! Set 1 of 3').kind,
          SleeveMessageKind.sessionFlow);
    });

    test('an unrecognised line is kept verbatim, never dropped', () {
      const odd = '# Something the firmware grew after this was written';
      final m = parseSleeveLine(odd);
      expect(m.kind, SleeveMessageKind.other);
      expect(m.raw, odd);
    });

    test('parsing never throws, whatever arrives', () {
      for (final s in const [
        '',
        '#',
        '# REP',
        '# REP abc  peak=xx deg',
        '# PARAMS target=',
        '>>',
        '=== ',
        '\u0000\u0001',
        '# LIVE calibrated=',
      ]) {
        expect(() => parseSleeveLine(s), returnsNormally, reason: 'on "$s"');
      }
    });
  });

  group('display', () {
    test('the comment marker goes, the indentation stays', () {
      // The indentation is how the sleeve marks a line as subordinate to the
      // one above, so it has to survive into the log view.
      expect(parseSleeveLine('# REP 1  peak=90.0 deg  duration=4.0 s  rom=95  '
              'tempo=100 (ok)  score=97')
          .display
          .startsWith('REP 1'), isTrue);
      expect(parseSleeveLine('#   Set 2: 7 of 10').display, '  Set 2: 7 of 10');
    });

    test('concerning lines are marked', () {
      expect(parseSleeveLine('# Partial rep (peak 45 deg, needed 72)')
          .isConcerning, isTrue);
      expect(parseSleeveLine('#   [FT1] vs your first reps: range 72%, '
                  'effort 141%, time 155%  RANGE')
          .isConcerning, isTrue);
      expect(parseSleeveLine('#   [FT1] vs your first reps: range 99%, '
                  'effort 101%, time 100%')
          .isConcerning, isFalse);
    });
  });
}
