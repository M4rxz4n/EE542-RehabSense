/// Runtime configuration, PRD §5.9.1.
///
/// TLV rather than a packed struct, so a newer host can talk to older
/// firmware. The firmware SKIPS an unrecognised tag but REJECTS a recognised
/// tag with the wrong length, because a length mismatch means the two sides
/// disagree about what the tag means.
///
/// Every parameter here may be changed during a session, takes effect from
/// the next repetition, and is stored in NVS. After a write, always
/// [Cmd.getConfig] and compare: the device reading it back is the only
/// confirmation that a change took effect.
library;

import 'dart:typed_data';

/// `config.h` tags.
enum CfgTag {
  holdMs(0x01, 'Hold duration', 'ms'),
  holdVel(0x02, 'Hold velocity limit', 'deg/s'),
  repTarget(0x03, 'Reps per set', ''),
  setCount(0x04, 'Sets', ''),
  restSeconds(0x05, 'Rest', 's'),
  targetAngle(0x06, 'Target angle', '°'),
  startAngle(0x07, 'Start angle', '°'),
  finishAngle(0x08, 'Finish angle', '°'),
  tempo(0x09, 'Tempo window', 's'),
  compThresh(0x0A, 'Compensation thresholds', ''),
  weights(0x0B, 'Grading weights', ''),
  deductions(0x0C, 'Compensation deductions', ''),
  rawStream(0x0D, 'Raw stream', ''),
  channelRoles(0x0E, 'Channel roles', '');

  const CfgTag(this.wire, this.label, this.unit);
  final int wire;
  final String label;
  final String unit;

  static CfgTag? fromWire(int v) {
    for (final t in values) {
      if (t.wire == v) return t;
    }
    return null;
  }
}

/// Firmware defaults, from `rehab_config.h`. Shown as the reset target and
/// used to seed the editor before the first GET_CONFIG lands.
abstract final class CfgDefaults {
  static const int holdMs = 1000;
  static const int holdMsMin = 300;
  static const int holdMsMax = 3000;
  static const int repTarget = 20;
  static const int repTargetMin = 1;
  static const int repTargetMax = 50;
  static const int setCount = 3;
  static const int restSeconds = 60;
  static const double targetAngleDeg = 110.0;
  static const double startAngleDeg = 15.0;
  static const double finishAngleDeg = 10.0;
  static const double tempoMinS = 1.5;
  static const double tempoMaxS = 3.5;
  static const double compShoulderDeg = 20.0;
  static const double compTrunkDeg = 10.0;
  static const double compSwingDps = 30.0;

  /// The peak criterion is 80% of the target angle, not the target itself.
  /// The waypoint soft click fires there too.
  static const double peakFraction = 0.8;
}

Uint8List tlv(int tag, List<int> value) =>
    Uint8List.fromList([tag & 0xFF, value.length & 0xFF, ...value]);

Uint8List cfgU8(CfgTag tag, int v) => tlv(tag.wire, [v & 0xFF]);

Uint8List cfgU16(CfgTag tag, int v) {
  final b = ByteData(2)..setUint16(0, v & 0xFFFF, Endian.little);
  return tlv(tag.wire, b.buffer.asUint8List());
}

Uint8List cfgF32(CfgTag tag, List<double> vals) {
  final b = ByteData(4 * vals.length);
  for (var i = 0; i < vals.length; i++) {
    b.setFloat32(i * 4, vals[i], Endian.little);
  }
  return tlv(tag.wire, b.buffer.asUint8List());
}

Uint8List concatTlv(List<Uint8List> blocks) {
  final out = <int>[];
  for (final b in blocks) {
    out.addAll(b);
  }
  return Uint8List.fromList(out);
}

/// Split a serialised configuration into {tag: raw value}.
///
/// Throws on a truncated block: a short tail means the notification was cut,
/// and guessing at it would silently drop a parameter.
Map<int, Uint8List> parseConfigTlv(Uint8List block) {
  final out = <int, Uint8List>{};
  var i = 0;
  while (i + 2 <= block.length) {
    final tag = block[i];
    final length = block[i + 1];
    if (i + 2 + length > block.length) {
      throw FormatException(
          'truncated TLV at tag 0x${tag.toRadixString(16).toUpperCase()}');
    }
    out[tag] = Uint8List.fromList(block.sublist(i + 2, i + 2 + length));
    i += 2 + length;
  }
  return out;
}

/// The §5.9.1 parameter set, as the device holds it.
class RuntimeConfig {
  RuntimeConfig({
    this.holdMs = CfgDefaults.holdMs,
    this.holdVelocityThresh = 0.0,
    this.repTarget = CfgDefaults.repTarget,
    this.setCount = CfgDefaults.setCount,
    this.restSeconds = CfgDefaults.restSeconds,
    this.targetAngleDeg = CfgDefaults.targetAngleDeg,
    this.startAngleDeg = CfgDefaults.startAngleDeg,
    this.finishAngleDeg = CfgDefaults.finishAngleDeg,
    this.tempoMinS = CfgDefaults.tempoMinS,
    this.tempoMaxS = CfgDefaults.tempoMaxS,
    this.compShoulderDeg = CfgDefaults.compShoulderDeg,
    this.compTrunkDeg = CfgDefaults.compTrunkDeg,
    this.compSwingDps = CfgDefaults.compSwingDps,
    this.weights = const [0.2, 0.2, 0.2, 0.2, 0.2],
    this.deductions = const [0.0, 0.0, 0.0],
    this.rawStreamEnable = true,
    this.exerciseId = 0,
    this.agonistChannel = 0,
  });

  int holdMs;
  double holdVelocityThresh;
  int repTarget;
  int setCount;
  int restSeconds;
  double targetAngleDeg;
  double startAngleDeg;
  double finishAngleDeg;
  double tempoMinS;
  double tempoMaxS;
  double compShoulderDeg;
  double compTrunkDeg;
  double compSwingDps;

  /// range, tempo, smoothness, cocontraction, hold steadiness
  List<double> weights;

  /// shoulder, trunk, swing
  List<double> deductions;

  /// Switches the full-rate raw stream without affecting results or events.
  /// Worth leaving OFF on a phone: ~10.4 kB/s is near the practical ceiling
  /// of a phone BLE link and the live view does not need it.
  bool rawStreamEnable;

  int exerciseId;
  int agonistChannel;

  /// The angle a rep must pass to count, which is 80% of the target rather
  /// than the target itself.
  double get peakAngleDeg => targetAngleDeg * CfgDefaults.peakFraction;

  /// Apply a decoded GET_CONFIG block. Unknown tags are ignored, matching the
  /// firmware's own rule, so an older app against newer firmware degrades
  /// instead of failing.
  void applyTlv(Map<int, Uint8List> tags) {
    double f32(Uint8List v, [int i = 0]) =>
        ByteData.sublistView(v).getFloat32(i * 4, Endian.little);

    tags.forEach((tag, v) {
      switch (CfgTag.fromWire(tag)) {
        case CfgTag.holdMs:
          if (v.length >= 2) {
            holdMs = ByteData.sublistView(v).getUint16(0, Endian.little);
          }
        case CfgTag.holdVel:
          if (v.length >= 4) holdVelocityThresh = f32(v);
        case CfgTag.repTarget:
          if (v.isNotEmpty) repTarget = v[0];
        case CfgTag.setCount:
          if (v.isNotEmpty) setCount = v[0];
        case CfgTag.restSeconds:
          if (v.length >= 2) {
            restSeconds = ByteData.sublistView(v).getUint16(0, Endian.little);
          }
        case CfgTag.targetAngle:
          if (v.length >= 4) targetAngleDeg = f32(v);
        case CfgTag.startAngle:
          if (v.length >= 4) startAngleDeg = f32(v);
        case CfgTag.finishAngle:
          if (v.length >= 4) finishAngleDeg = f32(v);
        case CfgTag.tempo:
          if (v.length >= 8) {
            tempoMinS = f32(v, 0);
            tempoMaxS = f32(v, 1);
          }
        case CfgTag.compThresh:
          if (v.length >= 12) {
            compShoulderDeg = f32(v, 0);
            compTrunkDeg = f32(v, 1);
            compSwingDps = f32(v, 2);
          }
        case CfgTag.weights:
          if (v.length >= 20) {
            weights = [for (var i = 0; i < 5; i++) f32(v, i)];
          }
        case CfgTag.deductions:
          if (v.length >= 12) {
            deductions = [for (var i = 0; i < 3; i++) f32(v, i)];
          }
        case CfgTag.rawStream:
          if (v.isNotEmpty) rawStreamEnable = v[0] != 0;
        case CfgTag.channelRoles:
          if (v.length >= 2) {
            exerciseId = v[0];
            agonistChannel = v[1];
          }
        case null:
          break; // unrecognised tag — skipped, as the firmware does
      }
    });
  }

  /// Serialise everything. Used for a full push; prefer sending only the tags
  /// that changed during a session, since each write is a round trip.
  Uint8List toTlv() => concatTlv([
        cfgU16(CfgTag.holdMs, holdMs),
        cfgF32(CfgTag.holdVel, [holdVelocityThresh]),
        cfgU8(CfgTag.repTarget, repTarget),
        cfgU8(CfgTag.setCount, setCount),
        cfgU16(CfgTag.restSeconds, restSeconds),
        cfgF32(CfgTag.targetAngle, [targetAngleDeg]),
        cfgF32(CfgTag.startAngle, [startAngleDeg]),
        cfgF32(CfgTag.finishAngle, [finishAngleDeg]),
        cfgF32(CfgTag.tempo, [tempoMinS, tempoMaxS]),
        cfgF32(CfgTag.compThresh, [compShoulderDeg, compTrunkDeg, compSwingDps]),
        cfgF32(CfgTag.weights, weights),
        cfgF32(CfgTag.deductions, deductions),
        cfgU8(CfgTag.rawStream, rawStreamEnable ? 1 : 0),
        tlv(CfgTag.channelRoles.wire, [exerciseId, agonistChannel]),
      ]);

  Map<String, dynamic> toJson() => {
        'hold_ms': holdMs,
        'rep_target': repTarget,
        'set_count': setCount,
        'rest_seconds': restSeconds,
        'target_angle_deg': targetAngleDeg,
        'peak_angle_deg': peakAngleDeg,
        'start_angle_deg': startAngleDeg,
        'finish_angle_deg': finishAngleDeg,
        'tempo_min_s': tempoMinS,
        'tempo_max_s': tempoMaxS,
        'comp_shoulder_deg': compShoulderDeg,
        'comp_trunk_deg': compTrunkDeg,
        'comp_swing_dps': compSwingDps,
        'raw_stream': rawStreamEnable,
      };
}
