import 'dart:typed_data';
import 'device_link.dart';
import 'models.dart';

/// PROPOSED wire layout for the "Live features" channel (PRD 12.3).
/// Little-endian, 15 bytes. Agree it with the firmware owner before use.
///   0..3  u32 timestamp ms     8..9  u16 triceps x1000   12 u8 set
///   4..5  i16 angle x10 deg    10 u8 state                13 u8 reps in set
///   6..7  u16 biceps x1000     11 u8 phase                14 u8 flags
/// flags: bit0 biceps on, bit1 shoulder, bit2 trunk, bit3 swing
class FrameCodec {
  static const length = 15;

  static Uint8List encode(Frame f, int ms) {
    final d = ByteData(length);
    d.setUint32(0, ms, Endian.little);
    d.setInt16(4, (f.angle * 10).round(), Endian.little);
    d.setUint16(6, (f.bic * 1000).round().clamp(0, 65535), Endian.little);
    d.setUint16(8, (f.tri * 1000).round().clamp(0, 65535), Endian.little);
    d.setUint8(10, f.state.index);
    d.setUint8(11, f.phase.index);
    d.setUint8(12, f.set);
    d.setUint8(13, f.repsInSet);
    d.setUint8(14, (f.bicepsOn ? 1 : 0) | (f.shoulderLive ? 2 : 0) | (f.trunkLive ? 4 : 0) | (f.swingLive ? 8 : 0));
    return d.buffer.asUint8List();
  }

  /// Returns null for a short or malformed packet instead of throwing,
  /// so one bad packet never kills the stream.
  static Frame? decode(Uint8List b) {
    if (b.length < length) return null;
    final d = ByteData.sublistView(b);
    final s = d.getUint8(10), p = d.getUint8(11);
    if (s >= DeviceState.values.length || p >= Phase.values.length) return null;
    final fl = d.getUint8(14);
    return Frame(
      state: DeviceState.values[s],
      phase: Phase.values[p],
      angle: d.getInt16(4, Endian.little) / 10,
      bic: d.getUint16(6, Endian.little) / 1000,
      tri: d.getUint16(8, Endian.little) / 1000,
      set: d.getUint8(12),
      repsInSet: d.getUint8(13),
      bicepsOn: fl & 1 != 0,
      shoulderLive: fl & 2 != 0,
      trunkLive: fl & 4 != 0,
      swingLive: fl & 8 != 0,
    );
  }
}

/// Real sleeve. Left as a stub on purpose: it needs the shared UUID header
/// and a BLE package (for example flutter_blue_plus) added to pubspec.
class BleLink extends DeviceLink {
  Never _todo() => throw UnimplementedError('Add a BLE package and the shared UUID header, then implement.');
  @override
  Stream<Frame> get frames => _todo();
  @override
  Stream<RepResult> get reps => _todo();
  @override
  Stream<String> get events => _todo();
  @override
  Params get params => _todo();
  @override
  List<bool> get calibration => _todo();
  @override
  Future<void> connect() async => _todo();
  @override
  Future<void> runCalibrationStep(int index) async => _todo();
  @override
  Future<void> startSession() async => _todo();
  @override
  Future<void> stopSession() async => _todo();
  @override
  void setParams(Params p) => _todo();
  @override
  Future<void> firePattern(HapticPattern pattern) async => _todo();
  @override
  void dispose() {}
}
