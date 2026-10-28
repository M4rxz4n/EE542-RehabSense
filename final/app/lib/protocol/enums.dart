/// Enumerations and flag bits shared with the firmware.
///
/// Mirrors `rehab_types.h`, `patterns.h`, `calibration.h` and
/// `rehab_protocol.py`. Values are wire values: do not renumber.
library;

import 'constants.dart';

/// Stream frame types, in the first header byte.
abstract final class FrameType {
  static const int emg = 0x01;
  static const int imu = 0x02;
  static const int features = 0x03;
  static const int event = 0x04;
}

/// Control opcodes, host to device.
abstract final class Cmd {
  static const int startSession = 0x01; // u8 exercise id
  static const int stopSession = 0x02;
  static const int startCalibration = 0x03; // u8 phase
  static const int abortCalibration = 0x04;
  static const int requestRecalibration = 0x05;
  static const int ackSeq = 0x06; // u32 highest contiguous
  static const int requestBackfill = 0x07; // u32 start, u32 end
  static const int setConfig = 0x08; // TLV
  static const int getConfig = 0x09;
  static const int hapticTest = 0x0A; // u8 pattern id
  static const int setTime = 0x0B; // u64 host epoch us
  static const int powerOff = 0x0C;

  /// Brings up the sleeve's SoftAP and answers on the transfer
  /// characteristic. Refused while a set is running: the radio is shared and
  /// the live stream wins.
  static const int startTransfer = 0x0D;
  static const int stopTransfer = 0x0E;
}

enum RehabEvent {
  repStart(0x01, 'Rep started'),
  repComplete(0x02, 'Rep complete'),
  repAbandoned(0x03, 'Rep abandoned'),
  holdStart(0x04, 'Hold started'),
  holdComplete(0x05, 'Hold complete'),
  compensationShoulder(0x06, 'Shoulder hike'),
  compensationTrunk(0x07, 'Trunk lean'),
  compensationSwing(0x08, 'Arm swing'),
  startPosOk(0x09, 'Start position OK'),
  startPosBad(0x0A, 'Start position off'),
  fatigueWarn(0x0B, 'Fatigue — rest advised'),
  signalDegraded(0x0C, 'Signal degraded'),
  calibPhaseDone(0x0D, 'Calibration step done'),
  setComplete(0x0E, 'Set complete'),
  fault(0x0F, 'Fault'),
  stateChange(0x10, 'State change'),

  /// Angle rose with the agonist quiet. Deliberately not counted: a passively
  /// swung arm must not earn a repetition.
  passiveSwing(0x11, 'Passive swing — not counted');

  const RehabEvent(this.wire, this.label);
  final int wire;
  final String label;

  static RehabEvent? fromWire(int v) {
    for (final e in values) {
      if (e.wire == v) return e;
    }
    return null;
  }

  static String nameOf(int v) =>
      fromWire(v)?.label ??
      'UNKNOWN_0x${v.toRadixString(16).toUpperCase().padLeft(2, '0')}';
}

enum FwState {
  off(0, 'Off'),
  boot(1, 'Booting'),
  standby(2, 'Standby'),
  donningCheck(3, 'Contact check'),
  calibration(4, 'Calibrating'),
  operational(5, 'Session running'),
  fault(6, 'Fault');

  const FwState(this.wire, this.label);
  final int wire;
  final String label;

  static FwState? fromWire(int v) {
    for (final e in values) {
      if (e.wire == v) return e;
    }
    return null;
  }

  static String nameOf(int v) => fromWire(v)?.label ?? 'UNKNOWN_$v';
}

/// `rep_cycle.h` — PRD §5.4.
///
/// ready → concentric → peak → eccentric → extendedHold → (counted)
///
/// The count happens on the RETURN, after a confirming hold at the extended
/// position, so the score covers the eccentric phase and the haptic lands at
/// a moment the patient is already stationary. The patient view must not
/// claim a rep before [extendedHold] resolves.
enum RepState {
  ready(0, 'Ready'),
  concentric(1, 'Lifting'),
  peak(2, 'At peak'),
  eccentric(3, 'Lowering'),
  extendedHold(4, 'Hold');

  const RepState(this.wire, this.label);
  final int wire;
  final String label;

  static RepState fromWire(int v) =>
      values.firstWhere((e) => e.wire == v, orElse: () => RepState.ready);
}

/// `calibration.h` — the step protocol of PRD §5.3.
///
/// Carried as the u8 argument of [Cmd.startCalibration], so a failed step can
/// be repeated on its own. That matters: the step most likely to be rejected
/// is a maximum contraction on a paretic limb, which is the one a patient
/// least wants to repeat four others to get back to.
enum CalibPhase {
  idle(0, 'Idle', ''),
  contact(1, 'Contact check', 'Sleeve on, electrodes seated. Hold still.'),
  rest(2, 'Rest', 'Arm relaxed and supported. Do not tense.'),
  straight(3, 'Straight', 'Straighten your arm to a comfortable extension.'),
  biceps(4, 'Biceps maximum', 'Curl against resistance as hard as is comfortable. Best of three.'),
  triceps(5, 'Triceps maximum', 'Push against resistance. Requires the two-channel front end.'),
  sweep(6, 'Range sweep', 'Slowly curl all the way up and back down once.'),
  all(7, 'Full protocol', 'Runs every step in order.'),
  done(8, 'Done', ''),
  failed(9, 'Failed', '');

  const CalibPhase(this.wire, this.label, this.prompt);
  final int wire;
  final String label;

  /// What to put in front of the patient during this step.
  final String prompt;

  /// The steps a wizard walks, in order.
  ///
  /// [triceps] is absent on the single-channel prototype: one MyoWare on the
  /// biceps has no antagonist to measure.
  static List<CalibPhase> get wizardSteps => [
        contact,
        rest,
        straight,
        biceps,
        if (kEmgChannels > 1) triceps,
        sweep,
      ];

  static CalibPhase? fromWire(int v) {
    for (final e in values) {
      if (e.wire == v) return e;
    }
    return null;
  }
}

/// `patterns.h` — one ERM, seven messages, distinguished by RHYTHM.
///
/// An ERM's vibration frequency is coupled to its amplitude, so "stronger"
/// also means "faster" and cannot carry independent meaning. Every cue plays
/// at one consistent amplitude. The patient view mirrors these visually, so
/// the rhythm descriptions are the spec for the animation too.
enum HapticPattern {
  none(0, 'None', ''),
  tick(1, 'Tick', '40 ms — button acknowledged'),
  repClean(2, 'Rep clean', 'one 100 ms click'),
  repFlagged(3, 'Rep flagged', 'three 80 ms pulses, 80 ms gaps'),
  setComplete(4, 'Set complete', 'two 70 ms pulses, then one 500 ms'),
  rest(5, 'Rest', '1000 ms ramp up and down'),
  fault(6, 'Fault', 'two 300 ms pulses, 300 ms apart'),
  softClick(7, 'Waypoint', '30 ms, reduced level — 80% of target angle'),
  repCleanThenSet(8, 'Rep clean + set', 'compound, 300 ms gap'),
  repFlaggedThenSet(9, 'Rep flagged + set', 'compound, 300 ms gap');

  const HapticPattern(this.wire, this.label, this.rhythm);
  final int wire;
  final String label;
  final String rhythm;
}

enum Fault {
  none(0, 'None'),
  watchdog(1, 'Watchdog'),
  imuUnresponsive(2, 'IMU unresponsive'),
  emgUnresponsive(3, 'EMG unresponsive'),
  i2cUnrecoverable(4, 'I2C unrecoverable'),
  hapticCalibFailed(5, 'Haptic calibration failed'),
  psramMissing(6, 'PSRAM missing'),
  selftest(7, 'Self-test failed'),
  contactLost(8, 'Electrode contact lost'),
  batteryLow(9, 'Battery low');

  const Fault(this.wire, this.label);
  final int wire;
  final String label;

  static Fault? fromWire(int v) {
    for (final e in values) {
      if (e.wire == v) return e;
    }
    return null;
  }

  static String nameOf(int v) => fromWire(v)?.label ?? 'UNKNOWN_$v';
}

enum XferState {
  idle(0, 'Idle'),
  starting(1, 'Starting'),
  ready(2, 'Ready'),
  complete(3, 'Complete'),
  failed(4, 'Failed');

  const XferState(this.wire, this.label);
  final int wire;
  final String label;

  static XferState? fromWire(int v) {
    for (final e in values) {
      if (e.wire == v) return e;
    }
    return null;
  }

  static String nameOf(int v) => fromWire(v)?.label ?? 'UNKNOWN_$v';
}

// ── Flag bits ────────────────────────────────────────────────────────────

const int compShoulder = 1 << 0;
const int compTrunk = 1 << 1;
const int compSwing = 1 << 2;

const int sigDegradedA = 1 << 0;
const int sigDegradedB = 1 << 1;
const int sigMvcUnreliable = 1 << 2;

const int statusFlagPsramBacked = 1 << 0;
const int statusFlagGapOccurred = 1 << 1;

const int calibFlagMvcUnreliable = 1 << 0;
const int calibFlagClinicianOverride = 1 << 1;

/// Version 2 adds `emg_rest_sd[]` and `gyro_bias[][]`, which the activation
/// detector and the joint angle respectively depend on. A stored v1 profile
/// is rejected cleanly rather than reinterpreted field by field.
const int calibRecordVersion = 2;

List<String> compNames(int flags) => [
      if (flags & compShoulder != 0) 'shoulder hike',
      if (flags & compTrunk != 0) 'trunk lean',
      if (flags & compSwing != 0) 'arm swing',
    ];
