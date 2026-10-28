/// Stream frame decoding and encoding.
///
/// The mirror image of `ble_service.c`'s publishers, and a byte-for-byte port
/// of `rehab_protocol.py`. Verified against golden vectors generated from that
/// module — see `test/protocol_golden_test.dart`.
library;

import 'dart:typed_data';

import 'constants.dart';
import 'enums.dart';

class ProtocolError implements Exception {
  ProtocolError(this.message);
  final String message;
  @override
  String toString() => 'ProtocolError: $message';
}

// ── 64-bit helpers ───────────────────────────────────────────────────────
//
// ByteData.getUint64 is unsupported when compiled to JavaScript, and the
// clinician bridge may one day want this parser in a web build. Reading two
// 32-bit halves works everywhere, and every timestamp the device produces is
// well inside the 2^53 a double represents exactly.

int readU64(ByteData d, int offset) {
  final lo = d.getUint32(offset, Endian.little);
  final hi = d.getUint32(offset + 4, Endian.little);
  return hi * 0x100000000 + lo;
}

/// Writes a 64-bit value, signed or unsigned.
///
/// Uses an arithmetic shift rather than integer division for the high half:
/// `~/` truncates toward zero, so a negative value such as a backwards
/// `host_time_offset_us` would get a high word of 0 instead of 0xFFFFFFFF and
/// come back as a large positive number.
void writeU64(ByteData d, int offset, int value) {
  d.setUint32(offset, value & 0xFFFFFFFF, Endian.little);
  d.setUint32(offset + 4, (value >> 32) & 0xFFFFFFFF, Endian.little);
}

int readI64(ByteData d, int offset) {
  final lo = d.getUint32(offset, Endian.little);
  final hi = d.getInt32(offset + 4, Endian.little);
  return hi * 0x100000000 + lo;
}

/// `frame_header_t` — type u8, seq u32, t_us u64, n u8. 14 bytes, packed.
class FrameHeader {
  const FrameHeader(this.type, this.seq, this.tUs, this.n);

  final int type;
  final int seq;
  final int tUs;
  final int n;

  static FrameHeader parse(ByteData d) => FrameHeader(
        d.getUint8(0),
        d.getUint32(1, Endian.little),
        readU64(d, 5),
        d.getUint8(13),
      );

  static Uint8List build(int type, int seq, int tUs, int n) {
    final b = ByteData(kFrameHeaderBytes);
    b.setUint8(0, type);
    b.setUint32(1, seq & 0xFFFFFFFF, Endian.little);
    writeU64(b, 5, tUs);
    b.setUint8(13, n & 0xFF);
    return b.buffer.asUint8List();
  }
}

/// Base class so a single stream can carry every frame type.
sealed class RehabFrame {
  const RehabFrame(this.seq, this.tUs);
  final int seq;
  final int tUs;
}

class EmgFrame extends RehabFrame {
  const EmgFrame(super.seq, super.tUs, this.samples, {this.isBackfill = false});

  /// Outer list is instants, inner is channels. Driver-normalised, signed,
  /// zero-centred counts.
  final List<List<int>> samples;

  /// True when the frame arrived on the backfill characteristic rather than
  /// the live raw stream. Same layout; different meaning for the UI.
  final bool isBackfill;
}

class ImuFrame extends RehabFrame {
  const ImuFrame(super.seq, super.tUs, this.samples);

  /// One entry per instant, each holding both devices in order
  /// [upper arm, forearm].
  final List<List<ImuSample>> samples;
}

class ImuSample {
  const ImuSample(this.accel, this.gyro);

  /// g
  final List<double> accel;

  /// deg/s
  final List<double> gyro;
}

/// `features_t` — the frame the patient view is driven by.
class FeatureFrame extends RehabFrame {
  const FeatureFrame(
    super.seq,
    super.tUs, {
    required this.envelope,
    required this.mdf,
    required this.elbowAngleDeg,
    required this.upperArmDevDeg,
    required this.repState,
    required this.repCount,
    required this.compFlags,
    required this.sigFlags,
    required this.activationOn,
  });

  /// %MVC, 0..1+. Index 0 is the agonist unless `agonist_channel` says
  /// otherwise.
  final List<double> envelope;

  /// Median frequency in Hz, 0 when below activation. The fatigue signal is
  /// this falling across a set.
  final List<double> mdf;

  final double elbowAngleDeg;

  /// Upper-arm deviation from the calibrated neutral. Shoulder hike shows up
  /// here.
  final double upperArmDevDeg;

  final RepState repState;
  final int repCount;
  final int compFlags;
  final int sigFlags;

  /// Agonist above threshold. A rep cannot start without it, which is what
  /// rejects a passively swung arm.
  final bool activationOn;

  List<String> get compensations => compNames(compFlags);
  bool get signalDegraded => sigFlags & (sigDegradedA | sigDegradedB) != 0;
  bool get mvcUnreliable => sigFlags & sigMvcUnreliable != 0;
}

class EventFrame extends RehabFrame {
  /// Events carry no sequence number of their own; the header's is always 0.
  const EventFrame(int tUs, this.event, this.payload) : super(0, tUs);

  final int event;
  final Uint8List payload;

  RehabEvent? get kind => RehabEvent.fromWire(event);
  String get label => RehabEvent.nameOf(event);
}

// ── features_t offsets ───────────────────────────────────────────────────
//
// features_t is NOT declared packed in rehab_types.h — only the structs that
// file calls wire-format structs are — and ble_notify_features() memcpy's the
// whole struct into the frame. Because it leads with a uint64_t its alignment
// is 8, so the compiler inserts one pad byte after the uint8_t rep_state and
// sizeof() is 40, not 33.
//
// Reading it without that pad does not fail. It silently shifts rep_count,
// comp_flags and sig_flags one byte left, which means wrong repetition counts
// and wrong compensation flags on screen. The Python host documents having hit
// exactly this. Both layouts are accepted here and chosen by body length, so
// the app keeps working if features_t is later marked packed.

const int _featBase = 8 + 8 * kEmgChannels;
const int _featUnpaddedEnd = 25 + 8 * kEmgChannels;
const int kFeaturesPackedBytes = 24 + 8 * kEmgChannels;
const int kFeaturesPaddedBytes = (_featUnpaddedEnd + 7) ~/ 8 * 8;

/// Decode one notification from the events, raw or backfill characteristic.
///
/// Throws [ProtocolError] on a malformed frame. Callers should log and drop
/// rather than tear the link down: a corrupt frame must not end a session.
RehabFrame parseFrame(Uint8List data, {bool isBackfill = false}) {
  if (data.length < kFrameHeaderBytes) {
    throw ProtocolError('frame shorter than header: ${data.length} bytes');
  }
  final d = ByteData.sublistView(data);
  final h = FrameHeader.parse(d);
  final bodyOffset = kFrameHeaderBytes;
  final bodyLen = data.length - bodyOffset;

  switch (h.type) {
    case FrameType.emg:
      final need = h.n * kEmgChannels * 2;
      if (bodyLen < need) {
        throw ProtocolError(
            'EMG frame claims ${h.n} samples ($need B), got $bodyLen B');
      }
      final samples = <List<int>>[];
      for (var i = 0; i < h.n; i++) {
        final row = <int>[];
        for (var c = 0; c < kEmgChannels; c++) {
          row.add(d.getInt16(
              bodyOffset + (i * kEmgChannels + c) * 2, Endian.little));
        }
        samples.add(row);
      }
      return EmgFrame(h.seq, h.tUs, samples, isBackfill: isBackfill);

    case FrameType.imu:
      // Per sample: 2 devices x (3 accel + 3 gyro) int16 = 24 bytes.
      final need = h.n * 24;
      if (bodyLen < need) {
        throw ProtocolError(
            'IMU frame claims ${h.n} samples ($need B), got $bodyLen B');
      }
      final samples = <List<ImuSample>>[];
      for (var i = 0; i < h.n; i++) {
        final base = bodyOffset + i * 24;
        final devices = <ImuSample>[];
        for (var dev = 0; dev < 2; dev++) {
          final o = base + dev * 12;
          devices.add(ImuSample(
            [
              for (var k = 0; k < 3; k++)
                d.getInt16(o + k * 2, Endian.little) / kAccelLsbPerG,
            ],
            [
              for (var k = 0; k < 3; k++)
                d.getInt16(o + 6 + k * 2, Endian.little) / kGyroLsbPerDps,
            ],
          ));
        }
        samples.add(devices);
      }
      return ImuFrame(h.seq, h.tUs, samples);

    case FrameType.features:
      final bool padded;
      if (bodyLen >= kFeaturesPaddedBytes) {
        padded = true;
      } else if (bodyLen >= kFeaturesPackedBytes) {
        padded = false;
      } else {
        throw ProtocolError(
            'feature frame is $bodyLen B, need $kFeaturesPackedBytes');
      }
      final o = bodyOffset;
      final envelope = [
        for (var c = 0; c < kEmgChannels; c++)
          d.getFloat32(o + 8 + c * 4, Endian.little),
      ];
      final mdf = [
        for (var c = 0; c < kEmgChannels; c++)
          d.getFloat32(o + 8 + kEmgChannels * 4 + c * 4, Endian.little),
      ];
      final elbow = d.getFloat32(o + _featBase, Endian.little);
      final dev = d.getFloat32(o + _featBase + 4, Endian.little);
      final repState = d.getUint8(o + _featBase + 8);
      // The one byte everything after it depends on.
      final tail = o + _featBase + 8 + (padded ? 2 : 1);
      // The body repeats t_us; the header's copy is the one the Python host
      // reports, and they are written from the same value. Use the header's
      // so both hosts agree even if that ever stops being true.
      return FeatureFrame(
        h.seq,
        h.tUs,
        envelope: envelope,
        mdf: mdf,
        elbowAngleDeg: elbow,
        upperArmDevDeg: dev,
        repState: RepState.fromWire(repState),
        repCount: d.getUint16(tail, Endian.little),
        compFlags: d.getUint16(tail + 2, Endian.little),
        sigFlags: d.getUint16(tail + 4, Endian.little),
        activationOn: d.getUint8(tail + 6) != 0,
      );

    case FrameType.event:
      if (bodyLen < 2) throw ProtocolError('event frame too short');
      final evt = data[bodyOffset];
      final plen = data[bodyOffset + 1];
      final end = (bodyOffset + 2 + plen).clamp(0, data.length);
      return EventFrame(
        h.tUs,
        evt,
        Uint8List.fromList(data.sublist(bodyOffset + 2, end)),
      );

    default:
      throw ProtocolError(
          'unknown frame type 0x${h.type.toRadixString(16).toUpperCase()}');
  }
}

// ── Builders ─────────────────────────────────────────────────────────────
//
// Only the simulator and the tests need these, but they are what makes the
// golden-vector test meaningful in both directions.

Uint8List _checkBudget(Uint8List frame, String what) {
  if (frame.length > kFrameMaxBytes) {
    throw ProtocolError(
        '$what is ${frame.length} B, over the $kFrameMaxBytes B budget');
  }
  return frame;
}

Uint8List buildEmgFrame(int seq, int tUs, List<List<int>> samples,
    {int type = FrameType.emg}) {
  final n = samples.length < kBleEmgBatch ? samples.length : kBleEmgBatch;
  final body = ByteData(n * kEmgChannels * 2);
  for (var i = 0; i < n; i++) {
    for (var c = 0; c < kEmgChannels; c++) {
      final v = samples[i][c].clamp(-32768, 32767);
      body.setInt16((i * kEmgChannels + c) * 2, v, Endian.little);
    }
  }
  return _checkBudget(
    Uint8List.fromList(
        FrameHeader.build(type, seq, tUs, n) + body.buffer.asUint8List()),
    'EMG frame',
  );
}

Uint8List buildImuFrame(int seq, int tUs, List<List<ImuSample>> samples) {
  final n = samples.length < kBleImuBatch ? samples.length : kBleImuBatch;
  final body = ByteData(n * 24);
  var off = 0;
  for (var i = 0; i < n; i++) {
    for (final s in samples[i]) {
      for (final a in s.accel) {
        body.setInt16(off, (a * kAccelLsbPerG).truncate(), Endian.little);
        off += 2;
      }
      for (final g in s.gyro) {
        body.setInt16(off, (g * kGyroLsbPerDps).truncate(), Endian.little);
        off += 2;
      }
    }
  }
  return _checkBudget(
    Uint8List.fromList(FrameHeader.build(FrameType.imu, seq, tUs, n) +
        body.buffer.asUint8List()),
    'IMU frame',
  );
}

/// [padded] reproduces what the firmware emits today. False is the layout a
/// packed `features_t` would give.
Uint8List buildFeatureFrame(
  int seq,
  int tUs, {
  required List<double> envelope,
  required List<double> mdf,
  required double elbowAngleDeg,
  required double upperArmDevDeg,
  required int repState,
  required int repCount,
  int compFlags = 0,
  int sigFlags = 0,
  bool activationOn = false,
  bool padded = true,
}) {
  final size = padded ? kFeaturesPaddedBytes : kFeaturesPackedBytes;
  final b = ByteData(size);
  writeU64(b, 0, tUs);
  for (var c = 0; c < kEmgChannels; c++) {
    b.setFloat32(8 + c * 4, envelope[c], Endian.little);
    b.setFloat32(8 + kEmgChannels * 4 + c * 4, mdf[c], Endian.little);
  }
  b.setFloat32(_featBase, elbowAngleDeg, Endian.little);
  b.setFloat32(_featBase + 4, upperArmDevDeg, Endian.little);
  b.setUint8(_featBase + 8, repState);
  final tail = _featBase + 8 + (padded ? 2 : 1);
  b.setUint16(tail, repCount, Endian.little);
  b.setUint16(tail + 2, compFlags, Endian.little);
  b.setUint16(tail + 4, sigFlags, Endian.little);
  b.setUint8(tail + 6, activationOn ? 1 : 0);
  return _checkBudget(
    Uint8List.fromList(FrameHeader.build(FrameType.features, seq, tUs, 1) +
        b.buffer.asUint8List()),
    'feature frame',
  );
}

Uint8List buildEventFrame(int tUs, int event, [List<int> payload = const []]) {
  if (payload.length > 16) {
    throw ProtocolError('event payload is 16 bytes at most');
  }
  return _checkBudget(
    Uint8List.fromList(FrameHeader.build(FrameType.event, 0, tUs, 1) +
        [event, payload.length] +
        payload),
    'event frame',
  );
}
