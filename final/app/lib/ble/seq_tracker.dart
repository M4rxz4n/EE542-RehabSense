/// Sequence accounting for the raw EMG stream.
///
/// ## The two numbering schemes, which are not interchangeable
///
/// Feature frames carry an independent counter that increments by one per
/// frame (`ble_notify_features(&f, seq++)` in main.c).
///
/// Raw EMG frames carry something else entirely: **the session-buffer ring
/// index of the first sample in the batch**. So consecutive EMG frames
/// advance by the header's `n` — 80 on the one-channel build — not by one.
/// main.c is explicit about why: the transmit path never blocks acquisition,
/// so a full queue drops a batch, and the dropped batch's sequence numbers
/// are then simply absent rather than reassigned to later samples.
///
/// ## Why this matters more than it looks
///
/// `CMD_ACK_SEQ` goes straight to `session_buffer_ack()`, and
/// `session_buffer.h` says storage below that value **may be released**. Ack a
/// number from the feature counter, or a number past a gap, and the device
/// frees samples the app never received — the clinical record then has a hole
/// that nothing can recover, and nothing reports an error.
///
/// The firmware had the mirror-image version of this bug: two independent
/// counters that agreed right up until a queue dropped, after which ACK_SEQ
/// freed storage the host had never seen and backfill ranges pointed at the
/// wrong samples.
///
/// So this tracker only ever advances [highestContiguous] across a *verified
/// continuous* run, and gaps are recorded for backfill instead of being
/// stepped over.
library;

/// A missing span of EMG sample indices, inclusive of both ends.
class SeqGap {
  const SeqGap(this.from, this.to);
  final int from;
  final int to;

  int get length => to - from + 1;

  @override
  String toString() => '$from..$to ($length samples)';

  @override
  bool operator ==(Object other) =>
      other is SeqGap && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);
}

class SeqTracker {
  /// Highest sample index below which every sample has been received.
  ///
  /// `-1` means nothing yet. This is the only value safe to put in
  /// `CMD_ACK_SEQ`.
  int highestContiguous = -1;

  /// The next index expected if nothing is dropped.
  int _nextExpected = -1;

  final List<SeqGap> _gaps = [];

  /// Gaps still outstanding, oldest first.
  List<SeqGap> get gaps => List.unmodifiable(_gaps);

  int get missingSamples => _gaps.fold(0, (a, g) => a + g.length);

  /// Total frames seen, and frames that arrived out of the expected order.
  int framesSeen = 0;
  int framesOutOfOrder = 0;

  /// Record a received raw EMG batch: [seq] is the index of its first sample,
  /// [n] the number of samples it carries.
  ///
  /// Returns the gap it opened, if any, so the caller can request a backfill
  /// immediately rather than waiting for a sweep.
  SeqGap? onEmgBatch(int seq, int n) {
    framesSeen++;
    if (n <= 0) return null;

    final last = seq + n - 1;

    if (_nextExpected < 0) {
      // First batch of the session. Everything before it was never ours to
      // have: a reconnect mid-session starts here, and the status
      // characteristic's seq_oldest says what the device still holds if the
      // earlier range is wanted.
      highestContiguous = last;
      _nextExpected = last + 1;
      return null;
    }

    if (seq == _nextExpected) {
      _nextExpected = last + 1;
      _advanceThroughFilledGaps();
      return null;
    }

    if (seq > _nextExpected) {
      final gap = SeqGap(_nextExpected, seq - 1);
      _gaps.add(gap);
      _nextExpected = last + 1;
      // highestContiguous deliberately does NOT move: everything from here on
      // sits behind an unfilled hole.
      return gap;
    }

    // seq < _nextExpected: a retransmission, or a backfill chunk arriving on
    // the raw characteristic. Either way it may close a gap.
    framesOutOfOrder++;
    _fillRange(seq, last);
    _advanceThroughFilledGaps();
    return null;
  }

  /// Record a backfill chunk. Same index space, served below the live stream.
  void onBackfillBatch(int seq, int n) {
    if (n <= 0) return;
    _fillRange(seq, seq + n - 1);
    _advanceThroughFilledGaps();
  }

  void _fillRange(int from, int to) {
    final remaining = <SeqGap>[];
    for (final g in _gaps) {
      if (to < g.from || from > g.to) {
        remaining.add(g); // untouched
        continue;
      }
      // Keep whatever of the gap this range did not cover.
      if (from > g.from) remaining.add(SeqGap(g.from, from - 1));
      if (to < g.to) remaining.add(SeqGap(to + 1, g.to));
    }
    _gaps
      ..clear()
      ..addAll(remaining);
    _gaps.sort((a, b) => a.from.compareTo(b.from));
  }

  /// With no gap below [_nextExpected], everything up to it is contiguous.
  void _advanceThroughFilledGaps() {
    if (_gaps.isEmpty) {
      highestContiguous = _nextExpected - 1;
      return;
    }
    // Contiguous only up to just before the earliest remaining hole.
    final firstHole = _gaps.first.from;
    final candidate = firstHole - 1;
    if (candidate > highestContiguous) highestContiguous = candidate;
  }

  /// Whether an ACK is worth sending, given what was last acknowledged.
  ///
  /// The device releases storage on ACK, so these go out steadily — but one
  /// per frame would be 25 writes a second competing with the stream for the
  /// same connection events.
  bool shouldAck(int lastAcked, {int minAdvance = 400}) =>
      highestContiguous >= 0 && highestContiguous - lastAcked >= minAdvance;

  void reset() {
    highestContiguous = -1;
    _nextExpected = -1;
    _gaps.clear();
    framesSeen = 0;
    framesOutOfOrder = 0;
  }

  Map<String, dynamic> toJson() => {
        'highest_contiguous': highestContiguous,
        'frames_seen': framesSeen,
        'frames_out_of_order': framesOutOfOrder,
        'gap_count': _gaps.length,
        'missing_samples': missingSamples,
      };
}
