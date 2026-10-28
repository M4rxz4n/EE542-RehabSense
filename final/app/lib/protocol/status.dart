/// `device_status_t`, characteristic 0x0005. Read and notify.
///
/// This one is NOT framed — it carries the struct raw, with no 14-byte
/// header. It IS `__attribute__((packed))` in `ble_service.h`, so there is no
/// padding anywhere: 24 + 5 * EMG_N_CHANNELS bytes.
///
/// The Python host once carried explicit pad bytes this struct does not have,
/// and every field after `battery_mv` was read from the wrong offset. Its own
/// tests did not catch it because they parse what the host itself builds —
/// only a real device showed it. The golden-vector test here exists for that
/// reason: it checks this parser against bytes the reference produced, not
/// against bytes this file produced.
library;

import 'dart:typed_data';

import 'constants.dart';
import 'enums.dart';
import 'frames.dart';

const int kStatusBytes = 24 + 5 * kEmgChannels;

class DeviceStatus {
  const DeviceStatus({
    required this.fwState,
    required this.faultCode,
    required this.batteryPct,
    required this.batteryMv,
    required this.signalQuality,
    required this.seqOldest,
    required this.seqNewest,
    required this.clipCount,
    required this.flags,
    required this.repCount,
    required this.hostTimeOffsetUs,
  });

  final int fwState;
  final int faultCode;
  final int batteryPct;
  final int batteryMv;

  /// 0..100 per channel. Low means the electrode needs attention before the
  /// numbers mean anything.
  final List<int> signalQuality;

  /// The range the device still holds, for backfill requests after a
  /// disconnection.
  final int seqOldest;
  final int seqNewest;

  final List<int> clipCount;
  final int flags;
  final int repCount;

  /// The device records the host's wall clock offset and reports it, but
  /// never adjusts its own clock: altering the sampling clock would corrupt
  /// the spectral analysis the fatigue estimate depends on.
  final int hostTimeOffsetUs;

  FwState? get state => FwState.fromWire(fwState);
  String get stateLabel => FwState.nameOf(fwState);
  Fault? get fault => Fault.fromWire(faultCode);
  String get faultLabel => Fault.nameOf(faultCode);

  bool get psramBacked => flags & statusFlagPsramBacked != 0;

  /// Data genuinely lost, as opposed to merely not yet acknowledged. The
  /// distinction matters: the first is a hole in the clinical record, the
  /// second is normal flow control.
  bool get gapOccurred => flags & statusFlagGapOccurred != 0;

  bool get inFault => fwState == FwState.fault.wire || faultCode != 0;

  static DeviceStatus parse(Uint8List data) {
    if (data.length < kStatusBytes) {
      throw ProtocolError('status is ${data.length} B, need $kStatusBytes');
    }
    final d = ByteData.sublistView(data);
    var o = 0;
    final fw = d.getUint8(o++);
    final fault = d.getUint8(o++);
    final bpct = d.getUint8(o++);
    final bmv = d.getUint16(o, Endian.little);
    o += 2;
    final sq = [for (var c = 0; c < kEmgChannels; c++) d.getUint8(o + c)];
    o += kEmgChannels;
    final oldest = d.getUint32(o, Endian.little);
    o += 4;
    final newest = d.getUint32(o, Endian.little);
    o += 4;
    final clip = [
      for (var c = 0; c < kEmgChannels; c++)
        d.getUint32(o + c * 4, Endian.little),
    ];
    o += 4 * kEmgChannels;
    final flags = d.getUint8(o++);
    final reps = d.getUint16(o, Endian.little);
    o += 2;
    final offset = readI64(d, o);

    return DeviceStatus(
      fwState: fw,
      faultCode: fault,
      batteryPct: bpct,
      batteryMv: bmv,
      signalQuality: sq,
      seqOldest: oldest,
      seqNewest: newest,
      clipCount: clip,
      flags: flags,
      repCount: reps,
      hostTimeOffsetUs: offset,
    );
  }

  Uint8List pack() {
    final b = ByteData(kStatusBytes);
    var o = 0;
    b.setUint8(o++, fwState);
    b.setUint8(o++, faultCode);
    b.setUint8(o++, batteryPct);
    b.setUint16(o, batteryMv, Endian.little);
    o += 2;
    for (var c = 0; c < kEmgChannels; c++) {
      b.setUint8(o + c, c < signalQuality.length ? signalQuality[c] : 0);
    }
    o += kEmgChannels;
    b.setUint32(o, seqOldest, Endian.little);
    o += 4;
    b.setUint32(o, seqNewest, Endian.little);
    o += 4;
    for (var c = 0; c < kEmgChannels; c++) {
      b.setUint32(o + c * 4, c < clipCount.length ? clipCount[c] : 0,
          Endian.little);
    }
    o += 4 * kEmgChannels;
    b.setUint8(o++, flags);
    b.setUint16(o, repCount, Endian.little);
    o += 2;
    writeU64(b, o, hostTimeOffsetUs);
    return b.buffer.asUint8List();
  }

  Map<String, dynamic> toJson() => {
        'fw_state': fwState,
        'state': stateLabel,
        'fault_code': faultCode,
        'fault': faultLabel,
        'battery_pct': batteryPct,
        'battery_mv': batteryMv,
        'signal_quality': signalQuality,
        'seq_oldest': seqOldest,
        'seq_newest': seqNewest,
        'clip_count': clipCount,
        'psram_backed': psramBacked,
        'gap_occurred': gapOccurred,
        'rep_count': repCount,
        'host_time_offset_us': hostTimeOffsetUs,
      };
}
