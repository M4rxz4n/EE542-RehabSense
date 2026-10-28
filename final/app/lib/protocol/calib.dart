/// `calib_record_t`, characteristic 0x0007. Read and write.
///
/// NOT packed on the C side, so it pads to a 4-byte boundary: the trailing
/// `uint8_t flags` is followed by three pad bytes. 104 bytes with one EMG
/// channel.
///
/// Writing it is how a clinician-supplied normalisation value supersedes a
/// measured one (PRD §5.3) — which is the escape hatch for a paretic limb
/// whose true maximum contraction cannot be elicited on the day.
///
/// A write goes to the calibration characteristic, never to SET_CONFIG. The
/// two shared opcode 0x08 at one point, which would have delivered a
/// `calib_record_t` straight into the TLV parser.
library;

import 'dart:typed_data';

import 'constants.dart';
import 'enums.dart';
import 'frames.dart';

/// 2 u32 + (4*N + 6 + 8 + 3 + 2) f32 + u8 + 3 pad.
const int kCalibFloats = 4 * kEmgChannels + 6 + 8 + 3 + 2;
const int kCalibBytes = 8 + 4 * kCalibFloats + 4;

class CalibRecord {
  const CalibRecord({
    this.version = calibRecordVersion,
    this.timestamp = 0,
    required this.emgRestRms,
    required this.emgRestSd,
    required this.emgMvc,
    required this.mdfBaseline,
    required this.gyroBias,
    required this.qUpper0,
    required this.qFore0,
    required this.flexionAxis,
    required this.angleMin,
    required this.angleMax,
    this.flags = 0,
  });

  /// A sensible empty record, for a device that has not been calibrated yet.
  factory CalibRecord.empty() => CalibRecord(
        emgRestRms: List.filled(kEmgChannels, 0.0),
        emgRestSd: List.filled(kEmgChannels, 0.0),
        emgMvc: List.filled(kEmgChannels, 1.0),
        mdfBaseline: List.filled(kEmgChannels, 0.0),
        gyroBias: List.filled(6, 0.0),
        qUpper0: const [1.0, 0.0, 0.0, 0.0],
        qFore0: const [1.0, 0.0, 0.0, 0.0],
        flexionAxis: const [0.0, 0.0, 1.0],
        angleMin: 0.0,
        angleMax: 0.0,
      );

  final int version;

  /// Host epoch seconds at capture. Set from [Cmd.setTime]'s offset, since
  /// the device has no clock of its own.
  final int timestamp;

  final List<double> emgRestRms;

  /// σ at rest. The activation detector thresholds off this, which is why a
  /// v1 record is rejected rather than reinterpreted.
  final List<double> emgRestSd;

  /// Per channel, its own maximum. Every envelope on screen is a fraction of
  /// this.
  final List<double> emgMvc;

  final List<double> mdfBaseline;

  /// [upper x,y,z, forearm x,y,z] in deg/s. The joint angle depends on it.
  final List<double> gyroBias;

  /// Reference poses from the straight-arm step.
  final List<double> qUpper0;
  final List<double> qFore0;

  /// Principal axis from the ROM sweep.
  final List<double> flexionAxis;

  /// This patient's real extension and flexion limits. Every repetition band
  /// is a fraction of [rom], never an absolute angle.
  final double angleMin;
  final double angleMax;

  final int flags;

  double get rom => angleMax - angleMin;

  /// The maximum could not be trusted. Scores normalised against it should be
  /// shown with that caveat, not silently.
  bool get mvcUnreliable => flags & calibFlagMvcUnreliable != 0;
  bool get clinicianOverride => flags & calibFlagClinicianOverride != 0;

  /// Whether this looks like a device that has actually been through the
  /// protocol, as opposed to one reporting zeroes.
  bool get isCalibrated => version == calibRecordVersion && rom > 1.0;

  static CalibRecord parse(Uint8List data) {
    if (data.length < kCalibBytes) {
      throw ProtocolError(
          'calibration record is ${data.length} B, need $kCalibBytes');
    }
    final d = ByteData.sublistView(data);
    final version = d.getUint32(0, Endian.little);
    final timestamp = d.getUint32(4, Endian.little);

    var o = 8;
    List<double> take(int n) {
      final out = [
        for (var i = 0; i < n; i++) d.getFloat32(o + i * 4, Endian.little),
      ];
      o += n * 4;
      return out;
    }

    final restRms = take(kEmgChannels);
    final restSd = take(kEmgChannels);
    final mvc = take(kEmgChannels);
    final mdf = take(kEmgChannels);
    final bias = take(6);
    final qUp = take(4);
    final qFo = take(4);
    final axis = take(3);
    final aMin = take(1)[0];
    final aMax = take(1)[0];
    final flags = d.getUint8(o);

    return CalibRecord(
      version: version,
      timestamp: timestamp,
      emgRestRms: restRms,
      emgRestSd: restSd,
      emgMvc: mvc,
      mdfBaseline: mdf,
      gyroBias: bias,
      qUpper0: qUp,
      qFore0: qFo,
      flexionAxis: axis,
      angleMin: aMin,
      angleMax: aMax,
      flags: flags,
    );
  }

  Uint8List pack() {
    final b = ByteData(kCalibBytes);
    b.setUint32(0, version, Endian.little);
    b.setUint32(4, timestamp, Endian.little);
    var o = 8;
    void put(List<double> vals) {
      for (final v in vals) {
        b.setFloat32(o, v, Endian.little);
        o += 4;
      }
    }

    put(emgRestRms);
    put(emgRestSd);
    put(emgMvc);
    put(mdfBaseline);
    put(gyroBias);
    put(qUpper0);
    put(qFore0);
    put(flexionAxis);
    put([angleMin, angleMax]);
    b.setUint8(o, flags);
    // The three trailing pad bytes are already zero.
    return b.buffer.asUint8List();
  }

  /// For the clinician-override path: replace the measured maximum without
  /// disturbing anything else the protocol measured.
  CalibRecord withMvcOverride(List<double> mvc) => CalibRecord(
        version: version,
        timestamp: timestamp,
        emgRestRms: emgRestRms,
        emgRestSd: emgRestSd,
        emgMvc: mvc,
        mdfBaseline: mdfBaseline,
        gyroBias: gyroBias,
        qUpper0: qUpper0,
        qFore0: qFore0,
        flexionAxis: flexionAxis,
        angleMin: angleMin,
        angleMax: angleMax,
        flags: (flags | calibFlagClinicianOverride) & ~calibFlagMvcUnreliable,
      );

  Map<String, dynamic> toJson() => {
        'version': version,
        'timestamp': timestamp,
        'emg_rest_rms': emgRestRms,
        'emg_rest_sd': emgRestSd,
        'emg_mvc': emgMvc,
        'mdf_baseline': mdfBaseline,
        'gyro_bias': gyroBias,
        'q_upper0': qUpper0,
        'q_fore0': qFore0,
        'flexion_axis': flexionAxis,
        'angle_min': angleMin,
        'angle_max': angleMax,
        'rom': rom,
        'mvc_unreliable': mvcUnreliable,
        'clinician_override': clinicianOverride,
      };
}
