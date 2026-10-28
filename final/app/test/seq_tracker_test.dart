/// Tests for raw-stream sequence accounting.
///
/// This logic is worth testing hard because getting it wrong destroys data
/// silently. `CMD_ACK_SEQ` goes to `session_buffer_ack()`, and
/// `session_buffer.h` says storage below that value may be released — so an
/// ack that steps over a gap tells the sleeve to free samples the app never
/// received, and the clinical record ends up with an unrecoverable hole that
/// nothing reports.
///
/// The firmware shipped the mirror image of this bug: two independent
/// counters that agreed right up until a queue drop, after which ACK_SEQ freed
/// storage the host had never seen.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rehabsense/ble/seq_tracker.dart';

/// The one-channel build's batch size. EMG seq advances by this, not by 1.
const int batch = 80;

void main() {
  group('clean stream', () {
    test('advances by n per batch, not by one', () {
      final t = SeqTracker();
      t.onEmgBatch(0, batch);
      expect(t.highestContiguous, 79);
      t.onEmgBatch(80, batch);
      expect(t.highestContiguous, 159);
      t.onEmgBatch(160, batch);
      expect(t.highestContiguous, 239);
      expect(t.gaps, isEmpty);
      expect(t.framesSeen, 3);
    });

    test('a mid-session join starts where it joined, claiming nothing before',
        () {
      // A reconnect lands partway through. Everything earlier was never ours;
      // seq_oldest on the status characteristic says what is still available.
      final t = SeqTracker();
      t.onEmgBatch(4000, batch);
      expect(t.highestContiguous, 4079);
      expect(t.gaps, isEmpty, reason: 'must not invent a 0..3999 gap');
    });

    test('an empty batch changes nothing', () {
      final t = SeqTracker();
      t.onEmgBatch(0, batch);
      t.onEmgBatch(80, 0);
      expect(t.highestContiguous, 79);
    });
  });

  group('a dropped batch', () {
    test('opens a gap and freezes the ack', () {
      final t = SeqTracker();
      t.onEmgBatch(0, batch);
      expect(t.highestContiguous, 79);

      // 80..159 never arrives — xQueueSend dropped it under load.
      final gap = t.onEmgBatch(160, batch);
      expect(gap, const SeqGap(80, 159));
      expect(t.gaps, [const SeqGap(80, 159)]);
      expect(t.missingSamples, 80);

      // THE important assertion. The ack must not move past the hole, however
      // much arrives after it.
      expect(t.highestContiguous, 79);
      t.onEmgBatch(240, batch);
      t.onEmgBatch(320, batch);
      expect(t.highestContiguous, 79,
          reason: 'acking past a gap frees data the host never received');
    });

    test('backfill closes the gap and releases the ack', () {
      final t = SeqTracker();
      t.onEmgBatch(0, batch);
      t.onEmgBatch(160, batch);
      t.onEmgBatch(240, batch);
      expect(t.highestContiguous, 79);

      t.onBackfillBatch(80, batch);
      expect(t.gaps, isEmpty);
      expect(t.highestContiguous, 319, reason: 'now contiguous to the newest');
    });

    test('a partial backfill leaves the remainder outstanding', () {
      final t = SeqTracker();
      t.onEmgBatch(0, batch);
      t.onEmgBatch(400, batch); // 80..399 missing, four batches' worth
      expect(t.missingSamples, 320);

      // The device may serve fewer frames than asked for if part of the range
      // has aged out — session_buffer_read_emg says so explicitly.
      t.onBackfillBatch(80, batch);
      expect(t.gaps, [const SeqGap(160, 399)]);
      expect(t.highestContiguous, 159);

      t.onBackfillBatch(160, batch);
      t.onBackfillBatch(240, batch);
      expect(t.highestContiguous, 319);
      expect(t.gaps, [const SeqGap(320, 399)]);

      t.onBackfillBatch(320, batch);
      expect(t.gaps, isEmpty);
      expect(t.highestContiguous, 479);
    });

    test('several gaps are tracked and closed independently', () {
      final t = SeqTracker();
      t.onEmgBatch(0, batch); // 0..79
      t.onEmgBatch(160, batch); // gap 80..159
      t.onEmgBatch(400, batch); // gap 240..399
      expect(t.gaps, [const SeqGap(80, 159), const SeqGap(240, 399)]);
      expect(t.highestContiguous, 79);

      // Closing the later one does not release the ack past the earlier one.
      t.onBackfillBatch(240, batch);
      t.onBackfillBatch(320, batch);
      expect(t.gaps, [const SeqGap(80, 159)]);
      expect(t.highestContiguous, 79);

      t.onBackfillBatch(80, batch);
      expect(t.gaps, isEmpty);
      expect(t.highestContiguous, 479);
    });

    test('a gap filled by the live stream out of order also closes', () {
      final t = SeqTracker();
      t.onEmgBatch(0, batch);
      t.onEmgBatch(160, batch);
      // A retransmission on the raw characteristic rather than backfill.
      t.onEmgBatch(80, batch);
      expect(t.gaps, isEmpty);
      expect(t.highestContiguous, 239);
      expect(t.framesOutOfOrder, 1);
    });

    test('a backfill chunk overlapping a gap edge trims rather than drops it',
        () {
      final t = SeqTracker();
      t.onEmgBatch(0, batch);
      t.onEmgBatch(400, batch); // gap 80..399

      // A chunk that starts before the gap and ends inside it.
      t.onBackfillBatch(40, 200); // covers 40..239
      expect(t.gaps, [const SeqGap(240, 399)]);
      expect(t.highestContiguous, 239);
    });
  });

  group('ack pacing', () {
    test('holds off until enough has accumulated', () {
      final t = SeqTracker();
      t.onEmgBatch(0, batch);
      // One batch is 80 samples; the default threshold is several batches, so
      // acking every frame would be 25 writes a second competing with the
      // stream for the same connection events.
      expect(t.shouldAck(-1), isFalse);

      for (var i = 1; i <= 6; i++) {
        t.onEmgBatch(i * batch, batch);
      }
      expect(t.shouldAck(-1), isTrue);
    });

    test('never asks to ack while nothing is contiguous', () {
      final t = SeqTracker();
      expect(t.highestContiguous, -1);
      expect(t.shouldAck(-1), isFalse);
    });

    test('does not re-ack a value already sent', () {
      final t = SeqTracker();
      for (var i = 0; i < 6; i++) {
        t.onEmgBatch(i * batch, batch);
      }
      expect(t.shouldAck(-1), isTrue);
      expect(t.shouldAck(t.highestContiguous), isFalse);
    });

    test('a long gap stalls the ack entirely, which is the correct behaviour',
        () {
      final t = SeqTracker();
      t.onEmgBatch(0, batch);
      t.onEmgBatch(800, batch); // a big drop
      for (var i = 11; i < 40; i++) {
        t.onEmgBatch(i * batch, batch);
      }
      // Thousands of samples arrived, but none of them may be acknowledged
      // while 80..799 is missing. The device's buffer fills instead — which is
      // recoverable. Freeing unreceived data is not.
      expect(t.shouldAck(-1), isFalse);
      expect(t.highestContiguous, 79);
    });
  });

  test('reset clears everything for a new session', () {
    final t = SeqTracker();
    t.onEmgBatch(0, batch);
    t.onEmgBatch(400, batch);
    expect(t.gaps, isNotEmpty);

    t.reset();
    expect(t.highestContiguous, -1);
    expect(t.gaps, isEmpty);
    expect(t.framesSeen, 0);
    expect(t.missingSamples, 0);

    // And a fresh stream starts clean rather than inheriting the old indices.
    t.onEmgBatch(0, batch);
    expect(t.highestContiguous, 79);
  });

  test('wraps nothing: a 32-bit counter at 2 kHz lasts about 25 days', () {
    // Sanity check on the assumption that wraparound is not worth handling.
    // One sample per channel at 2 kHz: 2^32 / 2000 seconds.
    const seconds = 4294967296 / 2000;
    expect(seconds / 86400, greaterThan(24));
  });
}
