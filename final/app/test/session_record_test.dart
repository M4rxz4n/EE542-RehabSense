/// Saved sessions: the record, its derived figures, and its CSV.
///
/// A saved session is the input to every progress chart, so a field lost in a
/// round trip does not fail loudly — it makes one point on one chart quietly
/// wrong, weeks later, with nothing to trace it to. Hence the round-trip
/// tests, and hence the insistence on the configuration snapshot: a rep that
/// reached 95° means something different against a 90° target than against a
/// 120° one, and a record that stored only the reps would make the charts
/// meaningless the first time a therapist changed the target.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rehabsense/protocol/enums.dart';
import 'package:rehabsense/session/rep_log.dart';
import 'package:rehabsense/session/session_record.dart';
import 'package:rehabsense/session/session_store.dart';

const _config = SessionConfigSnapshot(
  targetAngleDeg: 100,
  peakAngleDeg: 80,
  startAngleDeg: 15,
  finishAngleDeg: 10,
  tempoMinS: 3,
  tempoMaxS: 8,
  repTarget: 10,
  setCount: 3,
  restSeconds: 60,
  muscleOnPercent: 10,
  paceOn: true,
);

RepRow counted({
  required int index,
  double peak = 95,
  double duration = 4.5,
  int score = 90,
  int flags = 0,
  RepPhases? phases,
  int atUs = 0,
}) =>
    RepRow(
      atUs: atUs,
      outcome: flags != 0 ? RepOutcome.flagged : RepOutcome.onTarget,
      index: index,
      score: score,
      romPercent: (peak / 100 * 100).round(),
      peakAngleDeg: peak,
      durationS: duration,
      compFlags: flags,
      phases: phases,
      setNumber: 1,
    );

SessionRecord record({
  List<RepRow>? reps,
  List<TraceSample>? trace,
  List<SetRating>? ratings,
  List<FaultSpan>? faults,
  String note = '',
  SessionSource source = SessionSource.live,
}) =>
    SessionRecord(
      id: 's1',
      patientId: 'p1',
      startedAt: DateTime.utc(2026, 10, 30, 14, 5),
      endedAt: DateTime.utc(2026, 10, 30, 14, 23),
      config: _config,
      note: note,
      source: source,
      reps: reps,
      trace: trace,
      ratings: ratings,
      faults: faults,
    );

void main() {
  group('derived figures', () {
    test('counted and partial are separated', () {
      final r = record(reps: [
        counted(index: 1),
        counted(index: 2),
        RepRow(
          atUs: 0,
          outcome: RepOutcome.partial,
          peakAngleDeg: 50,
          durationS: 0,
        ),
        RepRow(
          atUs: 0,
          outcome: RepOutcome.passive,
          peakAngleDeg: 85,
          durationS: 0,
        ),
      ]);
      expect(r.countedCount, 2);
      expect(r.partialCount, 2);
      expect(r.passiveCount, 1);
    });

    test('at-target counts against the full target, not the criterion', () {
      // The criterion is 80°; the therapist's target is 100°. A rep at 85°
      // counts but is not at target, and conflating the two would make every
      // session look like a success.
      final r = record(reps: [
        counted(index: 1, peak: 85),
        counted(index: 2, peak: 102),
        counted(index: 3, peak: 100),
      ]);
      expect(r.atTargetCount, 2);
      expect(r.atTargetFraction, closeTo(2 / 3, 0.001));
    });

    test('mean, best and worst peak', () {
      final r = record(reps: [
        counted(index: 1, peak: 80),
        counted(index: 2, peak: 100),
        counted(index: 3, peak: 90),
      ]);
      expect(r.meanPeakDeg, closeTo(90, 0.001));
      expect(r.bestPeakDeg, 100);
      expect(r.worstPeakDeg, 80);
    });

    test('an empty session yields nulls, not zeros', () {
      // Zero mean peak would be drawn as a point on the floor of a progress
      // chart. Null is drawn as a gap, which is the truth.
      final r = record();
      expect(r.meanPeakDeg, isNull);
      expect(r.meanScore, isNull);
      expect(r.atTargetFraction, isNull);
      expect(r.controlledPaceFraction, isNull);
      expect(r.medianLiftS, isNull);
    });

    test('flag counts are per bit, and a rep with two flags counts in both',
        () {
      final r = record(reps: [
        counted(index: 1, flags: compShoulder),
        counted(index: 2, flags: compShoulder | compDrop),
      ]);
      expect(r.flagCounts[compShoulder], 2);
      expect(r.flagCounts[compDrop], 1);
      expect(r.flagCounts[compSwing], isNull);
      expect(r.flaggedCount, 2);
    });

    test('the controlled-pace share only counts reps that have a split', () {
      final r = record(reps: [
        counted(index: 1, phases: const RepPhases(liftS: 2, holdS: 1, lowerS: 2)),
        counted(
            index: 2,
            phases: const RepPhases(liftS: 0.4, holdS: 0.1, lowerS: 0.4)),
        // No split: excluded from the denominator rather than assumed bad.
        counted(index: 3),
      ]);
      expect(r.controlledPaceFraction, closeTo(0.5, 0.001));
    });

    test('median phase times', () {
      final r = record(reps: [
        counted(index: 1, phases: const RepPhases(liftS: 1, holdS: 1, lowerS: 1)),
        counted(index: 2, phases: const RepPhases(liftS: 2, holdS: 1, lowerS: 3)),
        counted(index: 3, phases: const RepPhases(liftS: 3, holdS: 1, lowerS: 5)),
      ]);
      expect(r.medianLiftS, 2);
      expect(r.medianHoldS, 1);
      expect(r.medianLowerS, 3);
    });

    test('rest and curl envelopes come from different parts of the trace', () {
      final r = record(trace: [
        // Below the start angle, muscle off: rest.
        const TraceSample(
            tMs: 0, angleDeg: 5, envelopePercent: 3, activationOn: false),
        const TraceSample(
            tMs: 100, angleDeg: 6, envelopePercent: 5, activationOn: false),
        // Past 40°: curling.
        const TraceSample(
            tMs: 200, angleDeg: 70, envelopePercent: 60, activationOn: true),
        const TraceSample(
            tMs: 300, angleDeg: 90, envelopePercent: 80, activationOn: true),
      ]);
      expect(r.restEnvelopePercent, closeTo(4, 0.001));
      expect(r.curlEnvelopePercent, closeTo(70, 0.001));
    });

    test('a skipped rating is not averaged in as a zero', () {
      // A zero would read as "no pain at all" on the therapist's chart, which
      // is a different claim from "declined to say".
      final r = record(ratings: const [
        SetRating(setNumber: 1, pain: 4, effort: 6),
        SetRating(setNumber: 2),
        SetRating(setNumber: 3, pain: 6, effort: 8),
      ]);
      expect(r.meanPain, closeTo(5, 0.001));
      expect(r.meanEffort, closeTo(7, 0.001));
    });
  });

  group('round trip', () {
    test('everything survives JSON', () {
      final original = record(
        note: 'new electrode spot',
        reps: [
          counted(
            index: 1,
            peak: 96.5,
            duration: 4.25,
            score: 93,
            flags: compSwing,
            phases: const RepPhases(liftS: 1.5, holdS: 0.5, lowerS: 2.25),
            atUs: 1000000,
          ),
          RepRow(
            atUs: 9000000,
            outcome: RepOutcome.partial,
            peakAngleDeg: 51.5,
            durationS: 0,
            neededDeg: 80,
          ),
        ],
        trace: const [
          TraceSample(
              tMs: 0, angleDeg: 9.4, envelopePercent: 3.2, activationOn: false),
          TraceSample(
              tMs: 100,
              angleDeg: 88.1,
              envelopePercent: 71.5,
              activationOn: true,
              repState: 1),
        ],
        ratings: const [SetRating(setNumber: 1, pain: 3, effort: 7)],
        faults: const [FaultSpan(fromMs: 4000, toMs: 4600)],
      );

      final back = SessionRecord.fromJson(original.toJson());

      expect(back.id, original.id);
      expect(back.patientId, original.patientId);
      expect(back.startedAt, original.startedAt);
      expect(back.endedAt, original.endedAt);
      expect(back.note, 'new electrode spot');
      expect(back.source, SessionSource.live);

      // The configuration snapshot is data, not metadata: without it the
      // reps cannot be compared with another session's.
      expect(back.config.targetAngleDeg, 100);
      expect(back.config.peakAngleDeg, 80);
      expect(back.config.tempoMinS, 3);
      expect(back.config.muscleOnPercent, 10);

      expect(back.reps, hasLength(2));
      expect(back.reps.first.peakAngleDeg, 96.5);
      expect(back.reps.first.compFlags, compSwing);
      expect(back.reps.first.phases!.lowerS, 2.25);
      expect(back.reps.last.outcome, RepOutcome.partial);
      expect(back.reps.last.neededDeg, 80);

      expect(back.trace, hasLength(2));
      expect(back.trace.last.angleDeg, closeTo(88.1, 0.05));
      expect(back.trace.last.activationOn, isTrue);
      expect(back.trace.last.repState, 1);

      expect(back.ratings.first.pain, 3);
      expect(back.faults.first.toMs, 4600);

      // And the derived figures agree, which is the point of the round trip.
      expect(back.countedCount, original.countedCount);
      expect(back.meanPeakDeg, original.meanPeakDeg);
      expect(back.atTargetCount, original.atTargetCount);
    });

    test('the peak criterion is read back, not re-derived', () {
      // It is 80% of the target in this firmware. Storing it means a session
      // does not change meaning if that fraction ever moves.
      final j = record().toJson();
      (j['config'] as Map)['peak_angle_deg'] = 72.0;
      final back = SessionRecord.fromJson(j);
      expect(back.config.peakAngleDeg, 72.0);
    });

    test('a record missing its criterion falls back to 80% of the target', () {
      final j = record().toJson();
      (j['config'] as Map).remove('peak_angle_deg');
      final back = SessionRecord.fromJson(j);
      expect(back.config.peakAngleDeg, closeTo(80, 0.001));
    });

    test('a malformed record degrades rather than throwing', () {
      // A session written by a later build, or half-written by a crash, must
      // not take the progress tab down with it.
      expect(() => SessionRecord.fromJson(const {}), returnsNormally);
      final empty = SessionRecord.fromJson(const {});
      expect(empty.reps, isEmpty);
      expect(empty.patientId, 'default');
    });

    test('a demo session keeps its label through a round trip', () {
      // Synthetic data that is not obviously synthetic is how a demo ends up
      // quoted as a result.
      final back = SessionRecord.fromJson(
          record(source: SessionSource.demo).toJson());
      expect(back.source, SessionSource.demo);
    });
  });

  group('CSV', () {
    test('a header, then one row per attempt including partials', () {
      final csv = record(reps: [
        counted(index: 1, phases: const RepPhases(liftS: 1.5, holdS: 0.5, lowerS: 2)),
        RepRow(
          atUs: 5000000,
          outcome: RepOutcome.partial,
          peakAngleDeg: 50,
          durationS: 0,
        ),
      ]).toCsv();

      final lines = csv.split('\n');
      expect(lines, hasLength(3));
      expect(lines.first, startsWith('rep,time_s,set,outcome'));
      // The reconstructed columns say so in their own names, because a column
      // called "lift_s" in a file that outlives this project will be read as
      // a device measurement.
      expect(lines.first, contains('lift_s_reconstructed'));
      expect(lines[1], startsWith('1,'));
      // A partial has no index: a dash in the table, an empty cell here.
      expect(lines[2], startsWith(','));
      expect(lines[2], contains('partial'));
    });

    test('several flags share one cell without breaking the columns', () {
      // Joined with '|' rather than ', ' precisely so a multi-flag rep does
      // not silently gain a column in every spreadsheet that opens this.
      final csv = record(reps: [
        counted(index: 1, flags: compShoulder | compSwing),
      ]).toCsv();
      final header = csv.split('\n').first.split(',').length;
      final row = csv.split('\n')[1].split(',').length;
      expect(row, header);
      expect(csv.split('\n')[1], contains('shoulder hike|arm swing'));
    });

    test('times are relative to the first attempt', () {
      final csv = record(reps: [
        counted(index: 1, atUs: 10000000),
        counted(index: 2, atUs: 15000000),
      ]).toCsv();
      final rows = csv.split('\n');
      expect(rows[1].split(',')[1], '0.0');
      expect(rows[2].split(',')[1], '5.0');
    });
  });

  group('SessionSummary', () {
    test('carries what the progress charts plot, without the trace', () {
      final s = SessionSummary.of(record(
        reps: [
          counted(index: 1, peak: 90, phases: const RepPhases(liftS: 2, holdS: 1, lowerS: 2)),
          counted(index: 2, peak: 104),
        ],
        trace: const [
          TraceSample(
              tMs: 0, angleDeg: 5, envelopePercent: 4, activationOn: false),
          TraceSample(
              tMs: 100, angleDeg: 70, envelopePercent: 66, activationOn: true),
        ],
        ratings: const [SetRating(setNumber: 1, pain: 2, effort: 5)],
      ));

      expect(s.countedCount, 2);
      expect(s.meanPeakDeg, closeTo(97, 0.001));
      expect(s.atTargetFraction, closeTo(0.5, 0.001));
      expect(s.targetAngleDeg, 100);
      expect(s.restEnvelopePercent, closeTo(4, 0.001));
      expect(s.curlEnvelopePercent, closeTo(66, 0.001));
      expect(s.meanPain, 2);
      expect(s.medianLiftS, 2);
    });

    test('round-trips through JSON', () {
      final s = SessionSummary.of(record(reps: [counted(index: 1)]));
      final back = SessionSummary.fromJson(s.toJson());
      expect(back.id, s.id);
      expect(back.startedAt, s.startedAt);
      expect(back.countedCount, s.countedCount);
      expect(back.meanPeakDeg, s.meanPeakDeg);
      expect(back.source, s.source);
    });

    test('a date label a therapist can scan', () {
      final s = SessionSummary.of(record());
      expect(s.dateLabel, '2026-10-30');
      expect(s.timeLabel, '14:05');
    });
  });

  group('ImportResult', () {
    test('reports what happened, not merely that it finished', () {
      expect(const ImportResult(added: 3, alreadyHad: 1).message,
          contains('3 added'));
      expect(const ImportResult(added: 3, alreadyHad: 1).message,
          contains('1 already saved'));
      expect(const ImportResult().message.toLowerCase(),
          contains('nothing to import'));
      expect(ImportResult.failed('bad file').ok, isFalse);
    });
  });
}
