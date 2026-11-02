/// Control-characteristic command builders. Mirrors `rehab_protocol.py`.
library;

import 'dart:typed_data';

import 'config_tlv.dart';
import 'enums.dart';
import 'frames.dart';

abstract final class Commands {
  static Uint8List startSession([int exerciseId = 0]) =>
      Uint8List.fromList([Cmd.startSession, exerciseId & 0xFF]);

  static Uint8List stopSession() => Uint8List.fromList([Cmd.stopSession]);

  /// [CalibPhase.all] runs the whole protocol. Naming a single step re-runs
  /// just that one, so a rejected step does not cost the entire protocol.
  static Uint8List calibrate([CalibPhase phase = CalibPhase.all]) =>
      Uint8List.fromList([Cmd.startCalibration, phase.wire & 0xFF]);

  static Uint8List abortCalibration() =>
      Uint8List.fromList([Cmd.abortCalibration]);

  static Uint8List requestRecalibration() =>
      Uint8List.fromList([Cmd.requestRecalibration]);

  /// Highest contiguous sequence number received. The device frees anything
  /// below it, so send this steadily or the buffer fills.
  static Uint8List ackSeq(int seq) {
    final b = ByteData(4)..setUint32(0, seq & 0xFFFFFFFF, Endian.little);
    return Uint8List.fromList([Cmd.ackSeq, ...b.buffer.asUint8List()]);
  }

  /// Replay a range the app missed. Served below the live stream in priority,
  /// so it arrives slowly during a set and quickly afterwards.
  static Uint8List requestBackfill(int start, int end) {
    final b = ByteData(8)
      ..setUint32(0, start & 0xFFFFFFFF, Endian.little)
      ..setUint32(4, end & 0xFFFFFFFF, Endian.little);
    return Uint8List.fromList([Cmd.requestBackfill, ...b.buffer.asUint8List()]);
  }

  static Uint8List getConfig() => Uint8List.fromList([Cmd.getConfig]);

  /// A clinician-supplied normalisation value goes a different way: a whole
  /// `calib_record_t` written to the calibration characteristic, never
  /// through here.
  static Uint8List setConfig(Uint8List tlvBlock) =>
      Uint8List.fromList([Cmd.setConfig, ...tlvBlock]);

  static Uint8List setConfigTags(List<Uint8List> blocks) =>
      setConfig(concatTlv(blocks));

  static Uint8List hapticTest(HapticPattern pattern) =>
      Uint8List.fromList([Cmd.hapticTest, pattern.wire & 0xFF]);

  /// The device records the offset and reports it, but never adjusts its own
  /// clock. Send this once on connection so timestamps can be related to wall
  /// time afterwards.
  static Uint8List setTime(int epochUs) {
    final b = ByteData(8);
    writeU64(b, 0, epochUs);
    return Uint8List.fromList([Cmd.setTime, ...b.buffer.asUint8List()]);
  }

  static Uint8List setTimeNow() =>
      setTime(DateTime.now().toUtc().microsecondsSinceEpoch);

  static Uint8List powerOff() => Uint8List.fromList([Cmd.powerOff]);

  /// Brings up the SoftAP. Refused while OPERATIONAL — stop the session
  /// first. That refusal is deliberate and not overridable.
  static Uint8List startTransfer() => Uint8List.fromList([Cmd.startTransfer]);

  static Uint8List stopTransfer() => Uint8List.fromList([Cmd.stopTransfer]);

  /// Run a Serial Monitor command on the sleeve, as though typed. See
  /// [Cmd.text] for why this exists.
  ///
  /// ASCII only and 40 characters at most: the sleeve's line buffer is 24
  /// bytes and it drops the overflow silently, so a long string would be
  /// truncated into a *different, valid* command rather than rejected. Every
  /// real command is one to five characters.
  static Uint8List text(String command) {
    final trimmed = command.trim();
    if (trimmed.isEmpty) {
      throw ProtocolError('empty TEXT command');
    }
    final bytes = <int>[];
    for (final c in trimmed.codeUnits) {
      if (c < 0x20 || c > 0x7E) {
        throw ProtocolError(
            'TEXT takes printable ASCII only; got code unit $c');
      }
      bytes.add(c);
    }
    if (bytes.length > 23) {
      throw ProtocolError(
          'TEXT command "$trimmed" is ${bytes.length} chars; the sleeve\'s '
          'line buffer holds 23 and silently drops the rest');
    }
    return Uint8List.fromList([Cmd.text, ...bytes]);
  }

  /// `h1`..`h12` — one haptic pattern, by the sleeve's own numbering.
  ///
  /// Distinct from [hapticTest], which uses the frozen team pattern ids. The
  /// sleeve's own list is longer (it includes the guided-pace beats and the
  /// rest-countdown cues), so the Developer tab drives it this way to reach
  /// all of them.
  static Uint8List hapticByIndex(int n) => text('h$n');

  /// `hx` then `h?` — play a random pattern, then reveal which it was. The
  /// point is to check a pattern is distinguishable *without* knowing which
  /// one is playing, which is the only way to tell whether the vocabulary
  /// actually carries meaning.
  static Uint8List hapticBlind() => text('hx');
  static Uint8List hapticReveal() => text('h?');
  static Uint8List hapticStop() => text('h0');

  /// `i` — print the `# LIVE` and `# PARAMS` lines on the Messages
  /// characteristic. Worth sending on every connect: it is how a host that
  /// joined mid-session learns the thresholds and the counts so far.
  static Uint8List requestStatusLines() => text('i');

  /// `n` — advance to the next calibration step. `g` — start counting reps.
  /// `z` — re-zero the straight-arm reference only.
  static Uint8List calibNext() => text('n');
  static Uint8List calibGo() => text('g');
  static Uint8List reZero() => text('z');

  /// `e` — EMG signal-quality test: 3 s relaxed, then 3 s squeezing.
  static Uint8List emgTest() => text('e');

  /// `b` — toggle the guided pace beats.
  static Uint8List togglePace() => text('b');

  /// `r` — new session: counts and sets back to zero.
  static Uint8List newSession() => text('r');

  /// `t<deg>` sets the target and locks it against the adaptive adjustment;
  /// `tl` toggles that lock; `tr` clears the saved progress; `t?` reports all
  /// three. The sleeve rejects anything outside 40–140°.
  static Uint8List setTargetLocked(int degrees) => text('t$degrees');
  static Uint8List toggleTargetLock() => text('tl');
  static Uint8List clearProgress() => text('tr');
  static Uint8List showTarget() => text('t?');
}

/// `EVT_REP_ABANDONED` — a partial repetition.
///
/// The arm rose past the start angle and came back down without passing the
/// peak criterion, or `[FC6]` timed it out at 10 s. Reported, never counted.
///
/// Payload is `<Hh`: the index the *next* rep would take, and the peak reached
/// in tenths of a degree. Note it is the next index, not this attempt's — a
/// partial consumes no number, which is why the rep table shows a dash.
class RepAbandoned {
  const RepAbandoned({required this.nextIndex, required this.peakAngleDeg});

  final int nextIndex;
  final double peakAngleDeg;

  static const int bytes = 4;

  static RepAbandoned? tryParse(Uint8List payload) {
    if (payload.length < bytes) return null;
    final d = ByteData.sublistView(payload);
    return RepAbandoned(
      nextIndex: d.getUint16(0, Endian.little),
      peakAngleDeg: d.getInt16(2, Endian.little) / 10.0,
    );
  }

  Map<String, dynamic> toJson() => {
        'next_index': nextIndex,
        'peak_angle_deg': peakAngleDeg,
      };
}

/// The sleeve's own fatigue thresholds, from `params.h`.
///
/// Here rather than in the UI layer because they are firmware constants, and
/// because the fatigue chart draws its dashed lines from them: a chart with
/// thresholds of its own invention would disagree with the device about when a
/// sign had been counted, which is the one thing it must never do.
///
/// Settable on the sleeve at build time only, so a copy is safe — but if they
/// ever become runtime-configurable this is the single place to change.
abstract final class FatigueThresholds {
  /// A range sign below this percentage of the session's first reps.
  static const double range = 85;

  /// An effort sign above this. Effort is per degree, so a rep that costs the
  /// same muscle for less range counts.
  static const double effort = 125;

  /// A time sign above this.
  static const double time = 140;
}

/// `EVT_FATIGUE_WARN` — performance dropping across the set.
///
/// Payload is `<hH`: the number of fatigue signs and the total reps so far.
/// One sign is a note, two or more ends the set early with a longer rest, and
/// a second stop in a session ends the session.
///
/// The sentinel matters: **9 signs means three partial reps in a row**, which
/// is a different observation from the range/effort/time comparison and is
/// reported through the same event rather than a new one. Treating it as "nine
/// signs" would read as catastrophic.
///
/// *Which* signs fired is not in the payload. That arrives only as the printed
/// `[FT1]` line on the Messages characteristic — see [SleeveMessage].
class FatigueWarn {
  const FatigueWarn({required this.signs, required this.totalReps});

  final int signs;
  final int totalReps;

  static const int threePartialsSentinel = 9;

  bool get isThreePartials => signs == threePartialsSentinel;

  /// 0 for the sentinel, because it is not a count of signs at all.
  int get signCount => isThreePartials ? 0 : signs;

  bool get endsSet => !isThreePartials && signs >= 2;

  String get label => isThreePartials
      ? 'Three reps in a row fell short — a sign of fatigue'
      : signs >= 2
          ? 'Signs of fatigue ($signs) — ending the set early'
          : 'A sign of fatigue — take your time';

  static const int bytes = 4;

  static FatigueWarn? tryParse(Uint8List payload) {
    if (payload.length < bytes) return null;
    final d = ByteData.sublistView(payload);
    return FatigueWarn(
      signs: d.getInt16(0, Endian.little),
      totalReps: d.getUint16(2, Endian.little),
    );
  }

  Map<String, dynamic> toJson() => {
        'signs': signs,
        'three_partials': isThreePartials,
        'total_reps': totalReps,
      };
}

/// `EVT_CALIB_PHASE_DONE` — calibration progress, `[phase, percent]`.
///
/// Sent twice per step: `percent` 0 when the step starts and 100 when it
/// finishes. A wizard that treats every one of these as a completion marks
/// each step done the moment it begins, which is how a progress display ends
/// up a step ahead of the patient.
class CalibProgress {
  const CalibProgress({required this.phase, required this.percent});

  final CalibPhase? phase;
  final int percent;

  bool get started => percent == 0;
  bool get finished => percent >= 100;

  static CalibProgress? tryParse(Uint8List payload) {
    if (payload.isEmpty) return null;
    return CalibProgress(
      phase: CalibPhase.fromWire(payload[0]),
      percent: payload.length > 1 ? payload[1] : 100,
    );
  }
}

/// `EVT_SET_COMPLETE` — u16 reps in the set that just ended.
///
/// Sent with **no payload** when the set ended because the host sent STOP,
/// which is why the count is nullable rather than defaulted to zero: "the set
/// ended and we are not told how many" is not the same as "the set ended with
/// no reps".
class SetComplete {
  const SetComplete(this.repsInSet);

  final int? repsInSet;

  bool get wasStopped => repsInSet == null;

  static SetComplete parse(Uint8List payload) => SetComplete(
      payload.length >= 2
          ? ByteData.sublistView(payload).getUint16(0, Endian.little)
          : null);
}

/// The 16-byte `EVT_REP_COMPLETE` payload.
///
/// PROPOSED, not yet emitted by `main.c`. `rep_cycle.c` produces a
/// `rep_result_t` and the event path can carry 16 payload bytes, but nothing
/// in the firmware wires it up yet, so no layout exists on the C side to
/// mirror. `rep_result_t` itself is 56 bytes and will not fit.
///
/// This is the proposal from `rehab_protocol.py`, and the simulator emits it,
/// so this path is exercised either way. Adopt, amend or replace it when
/// main.c grows its event wiring — but change both sides together.
class RepComplete {
  const RepComplete({
    required this.index,
    required this.score,
    required this.romFraction,
    required this.cocontraction,
    required this.smoothness,
    required this.holdSteadiness,
    required this.peakAngleDeg,
    required this.compFlags,
    required this.durationMs,
  });

  /// 1-based within the set.
  final int index;

  /// 0..100, as the device graded it. The device is authoritative: the app
  /// displays this rather than re-deriving anything from the raw stream.
  final int score;

  final double romFraction;
  final double cocontraction;
  final double smoothness;
  final double holdSteadiness;
  final double peakAngleDeg;
  final int compFlags;
  final int durationMs;

  List<String> get compensations => compNames(compFlags);
  bool get flagged => compFlags != 0;
  double get tempoS => durationMs / 1000.0;

  static const int bytes = 16;

  static RepComplete parse(Uint8List payload) {
    if (payload.length < bytes) {
      throw ProtocolError(
          'REP_COMPLETE payload is ${payload.length} B, need $bytes');
    }
    final d = ByteData.sublistView(payload);
    return RepComplete(
      index: d.getUint16(0, Endian.little),
      score: d.getUint8(2),
      romFraction: d.getUint8(3) / 100.0,
      cocontraction: d.getUint8(4) / 100.0,
      smoothness: d.getUint8(5) / 100.0,
      holdSteadiness: d.getUint8(6) / 100.0,
      // byte 7 is pad
      peakAngleDeg: d.getInt16(8, Endian.little) / 10.0,
      compFlags: d.getUint16(10, Endian.little),
      durationMs: d.getUint32(12, Endian.little),
    );
  }

  Uint8List pack() {
    int pct(double v) => (v * 100).round().clamp(0, 255);
    final b = ByteData(bytes);
    b.setUint16(0, index, Endian.little);
    b.setUint8(2, score);
    b.setUint8(3, pct(romFraction));
    b.setUint8(4, pct(cocontraction));
    b.setUint8(5, pct(smoothness));
    b.setUint8(6, pct(holdSteadiness));
    b.setInt16(8, (peakAngleDeg * 10).round(), Endian.little);
    b.setUint16(10, compFlags, Endian.little);
    b.setUint32(12, durationMs, Endian.little);
    return b.buffer.asUint8List();
  }

  Map<String, dynamic> toJson() => {
        'index': index,
        'score': score,
        'rom_fraction': romFraction,
        'cocontraction': cocontraction,
        'smoothness': smoothness,
        'hold_steadiness': holdSteadiness,
        'peak_angle_deg': peakAngleDeg,
        'comp_flags': compFlags,
        'compensations': compensations,
        'duration_ms': durationMs,
      };
}
