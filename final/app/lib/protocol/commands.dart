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
