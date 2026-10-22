"""
rehab_protocol.py — RehabSense BLE wire format.

Mirrors main/ble/ble_service.h. If you change one, change the other: this is
the interface contract between the firmware and the host.

Everything is little-endian. Frames fit 180 bytes rather than the 244 a
247-byte MTU allows, because macOS caps ATT MTU at 185 and bleak exposes no
portable MTU request.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass, field
from enum import IntEnum

# ── UUIDs ──────────────────────────────────────────────────────────────
BASE = "a5b1{:04x}-7c4e-4d9a-9e3f-1d2c3b4a5968"

UUID_SERVICE = BASE.format(0x0001)
UUID_CONTROL = BASE.format(0x0002)
UUID_RAW = BASE.format(0x0003)
UUID_EVENTS = BASE.format(0x0004)
UUID_STATUS = BASE.format(0x0005)
UUID_BACKFILL = BASE.format(0x0006)
UUID_CALIB = BASE.format(0x0007)

DEVICE_NAME = "RehabSense"

EMG_CHANNELS = 2
EMG_SAMPLE_RATE_HZ = 2000
IMU_SAMPLE_RATE_HZ = 100
FEATURE_RATE_HZ = 50

# Batch sizes and the frame budget, mirroring rehab_config.h.
FRAME_MAX_BYTES = 180
BLE_EMG_BATCH = 40        # 40 x 4 B + 14 = 174 B, 50 frames/s
BLE_IMU_BATCH = 6         #  6 x 24 B + 14 = 158 B, 16.7 frames/s


class FrameType(IntEnum):
    EMG = 0x01
    IMU = 0x02
    FEATURES = 0x03
    EVENT = 0x04


class Cmd(IntEnum):
    START_SESSION = 0x01
    STOP_SESSION = 0x02
    START_CALIBRATION = 0x03
    ABORT_CALIBRATION = 0x04
    REQUEST_RECALIBRATION = 0x05
    ACK_SEQ = 0x06
    REQUEST_BACKFILL = 0x07
    SET_CONFIG = 0x08
    GET_CONFIG = 0x09
    HAPTIC_TEST = 0x0A
    SET_TIME = 0x0B
    POWER_OFF = 0x0C


class Event(IntEnum):
    REP_START = 0x01
    REP_COMPLETE = 0x02
    REP_ABANDONED = 0x03
    HOLD_START = 0x04
    HOLD_COMPLETE = 0x05
    COMPENSATION_SHOULDER = 0x06
    COMPENSATION_TRUNK = 0x07
    COMPENSATION_SWING = 0x08
    START_POS_OK = 0x09
    START_POS_BAD = 0x0A
    FATIGUE_WARN = 0x0B
    SIGNAL_DEGRADED = 0x0C
    CALIB_PHASE_DONE = 0x0D
    SET_COMPLETE = 0x0E
    FAULT = 0x0F
    STATE_CHANGE = 0x10


class FwState(IntEnum):
    OFF = 0
    BOOT = 1
    STANDBY = 2
    DONNING_CHECK = 3
    CALIBRATION = 4
    OPERATIONAL = 5
    FAULT = 6


class RepState(IntEnum):
    WAIT_START = 0
    EXTENDED_HOLD = 1
    CONCENTRIC = 2
    FLEXED_HOLD = 3
    ECCENTRIC = 4


class CalibPhase(IntEnum):
    """calibration.h — the four-phase protocol."""
    IDLE = 0
    REST = 1          # 10 s, noise floor per channel
    MVC = 2           # 3 x 5 s, best of three, for %MVC scaling
    NEUTRAL = 3       # 5 s, q_upper0 and q_fore0
    ROM_SWEEP = 4     # 2 slow reps: flexion axis, angle_min, angle_max
    DONE = 5
    FAILED = 6


class HapticPattern(IntEnum):
    """patterns.h — one motor, five messages, distinguished by rhythm."""
    NONE = 0
    REP_COMPLETE = 1       # one 100 ms pulse
    REP_COMPENSATED = 2    # three 80 ms pulses
    WRONG_START = 3        # one 300 ms pulse at 50 %
    REST_CUE = 4           # 1000 ms ramp up then down
    BOOT_OK = 5            # two 100 ms pulses


class Fault(IntEnum):
    """fault_code_t in rehab_types.h."""
    NONE = 0
    WATCHDOG = 1
    IMU_UNRESPONSIVE = 2
    EMG_UNRESPONSIVE = 3
    I2C_UNRECOVERABLE = 4
    HAPTIC_CALIB_FAILED = 5
    PSRAM_MISSING = 6
    SELFTEST = 7


COMP_SHOULDER = 1 << 0
COMP_TRUNK = 1 << 1
COMP_SWING = 1 << 2

SIG_DEGRADED_A = 1 << 0
SIG_DEGRADED_B = 1 << 1
SIG_MVC_UNRELIABLE = 1 << 2

STATUS_FLAG_PSRAM_BACKED = 1 << 0
STATUS_FLAG_GAP_OCCURRED = 1 << 1

CALIB_FLAG_MVC_UNRELIABLE = 1 << 0
CALIB_FLAG_CLINICIAN_OVERRIDE = 1 << 1
CALIB_RECORD_VERSION = 1


def comp_names(flags: int) -> list[str]:
    out = []
    if flags & COMP_SHOULDER:
        out.append("shoulder hike")
    if flags & COMP_TRUNK:
        out.append("trunk lean")
    if flags & COMP_SWING:
        out.append("arm swing")
    return out


# ── Frame header: type u8, seq u32, t_us u64, n u8 = 14 bytes ─────────
HEADER = struct.Struct("<BIQB")
assert HEADER.size == 14, "header must be 14 bytes to match the firmware"

# ── features_t on the wire ─────────────────────────────────────────────
#
# ble_notify_features() memcpy's features_t straight into the frame, and
# features_t in rehab_types.h is NOT declared packed — only the structs the
# file calls wire-format structs are. Because it leads with a uint64_t its
# alignment is 8, so the compiler inserts one pad byte after the uint8_t
# rep_state, and sizeof(features_t) is 40, not 39:
#
#   t_us u64 @0 | envelope[2] f @8 | mdf[2] f @16 | elbow f @24
#   upper_arm_dev f @28 | rep_state u8 @32 | PAD @33
#   rep_count u16 @34 | comp_flags u16 @36 | sig_flags u16 @38
#
# Reading it without that pad shifts rep_count, comp_flags and sig_flags one
# byte left, which does not fail — it silently returns wrong repetition counts
# and wrong compensation flags. Both layouts are accepted here and chosen by
# body length, so the host keeps working if features_t is later marked packed
# (which would be the tidier fix, and matches the file's own convention).
FEATURES_PADDED = struct.Struct("<Q4f2fBxHHH")   # 40 B, what the firmware sends
FEATURES_PACKED = struct.Struct("<Q4f2fBHHH")    # 39 B, if the struct is packed
assert FEATURES_PADDED.size == 40 and FEATURES_PACKED.size == 39


@dataclass
class EmgFrame:
    seq: int
    t_us: int
    samples: list[tuple[int, ...]] = field(default_factory=list)


@dataclass
class ImuFrame:
    seq: int
    t_us: int
    # per sample: ((ax,ay,az),(gx,gy,gz)) per device, in g and deg/s
    samples: list[tuple[tuple[float, ...], ...]] = field(default_factory=list)


@dataclass
class FeatureFrame:
    seq: int
    t_us: int
    envelope: tuple[float, ...]
    mdf: tuple[float, ...]
    elbow_angle_deg: float
    upper_arm_dev_deg: float
    rep_state: int
    rep_count: int
    comp_flags: int
    sig_flags: int


@dataclass
class EventFrame:
    t_us: int
    event: int
    payload: bytes

    @property
    def name(self) -> str:
        try:
            return Event(self.event).name
        except ValueError:
            return f"UNKNOWN_0x{self.event:02X}"


class ProtocolError(ValueError):
    pass


def parse(data: bytes):
    """Decode one notification. Raises ProtocolError on a malformed frame."""
    if len(data) < HEADER.size:
        raise ProtocolError(f"frame shorter than header: {len(data)} bytes")

    ftype, seq, t_us, n = HEADER.unpack_from(data, 0)
    body = data[HEADER.size:]

    if ftype == FrameType.EMG:
        need = n * EMG_CHANNELS * 2
        if len(body) < need:
            raise ProtocolError(
                f"EMG frame claims {n} samples ({need} B), got {len(body)} B")
        vals = struct.unpack_from(f"<{n * EMG_CHANNELS}h", body, 0)
        samples = [tuple(vals[i * EMG_CHANNELS:(i + 1) * EMG_CHANNELS])
                   for i in range(n)]
        return EmgFrame(seq, t_us, samples)

    if ftype == FrameType.IMU:
        # per sample: 2 devices x (3 accel + 3 gyro) int16 = 24 bytes
        need = n * 24
        if len(body) < need:
            raise ProtocolError(
                f"IMU frame claims {n} samples ({need} B), got {len(body)} B")
        raw = struct.unpack_from(f"<{n * 12}h", body, 0)
        samples = []
        for i in range(n):
            base = i * 12
            dev = []
            for d in range(2):
                o = base + d * 6
                accel = tuple(v / 1000.0 for v in raw[o:o + 3])
                gyro = tuple(v / 10.0 for v in raw[o + 3:o + 6])
                dev.append((accel, gyro))
            samples.append(tuple(dev))
        return ImuFrame(seq, t_us, samples)

    if ftype == FrameType.FEATURES:
        # See the FEATURES_PADDED comment above: the firmware emits the
        # compiler's 40-byte layout, with a pad byte after rep_state.
        if len(body) >= FEATURES_PADDED.size:
            fmt = FEATURES_PADDED
        elif len(body) >= FEATURES_PACKED.size:
            fmt = FEATURES_PACKED
        else:
            raise ProtocolError(
                f"feature frame is {len(body)} B, need {FEATURES_PACKED.size}")
        (_t, e0, e1, m0, m1, ang, dev,
         rstate, rcount, comp, sig) = fmt.unpack_from(body, 0)
        return FeatureFrame(seq, t_us, (e0, e1), (m0, m1), ang, dev,
                            rstate, rcount, comp, sig)

    if ftype == FrameType.EVENT:
        if len(body) < 2:
            raise ProtocolError("event frame too short")
        evt, plen = body[0], body[1]
        return EventFrame(t_us, evt, bytes(body[2:2 + plen]))

    raise ProtocolError(f"unknown frame type 0x{ftype:02X}")


# ── Device status ──────────────────────────────────────────────────────
#
# The status characteristic carries device_status_t raw — it is read and
# notified, not framed, so it has no 14-byte header. Like features_t it is not
# packed, and it leads with uint8_ts before a uint16_t and ends with an
# int64_t, so the compiler pads it to 40 bytes:
#
#   fw_state u8 @0 | fault u8 @1 | battery_pct u8 @2 | PAD @3
#   battery_mv u16 @4 | signal_quality[2] u8 @6 | seq_oldest u32 @8
#   seq_newest u32 @12 | clip_count[2] u32 @16 | flags u8 @24 | PAD @25
#   rep_count u16 @26 | PAD @28..31 | host_time_offset_us i64 @32
STATUS = struct.Struct("<BBBxH2BIIIIBxH4xq")
assert STATUS.size == 40


@dataclass
class StatusFrame:
    fw_state: int
    fault_code: int
    battery_pct: int
    battery_mv: int
    signal_quality: tuple[int, ...]
    seq_oldest: int
    seq_newest: int
    clip_count: tuple[int, ...]
    flags: int
    rep_count: int
    host_time_offset_us: int

    @property
    def state_name(self) -> str:
        try:
            return FwState(self.fw_state).name
        except ValueError:
            return f"UNKNOWN_{self.fw_state}"

    @property
    def fault_name(self) -> str:
        try:
            return Fault(self.fault_code).name
        except ValueError:
            return f"UNKNOWN_{self.fault_code}"

    @property
    def gap_occurred(self) -> bool:
        """Data genuinely lost, as opposed to merely not yet acknowledged."""
        return bool(self.flags & STATUS_FLAG_GAP_OCCURRED)


def parse_status(data: bytes) -> StatusFrame:
    if len(data) < STATUS.size:
        raise ProtocolError(f"status is {len(data)} B, need {STATUS.size}")
    (fw, fault, bpct, bmv, sq0, sq1, oldest, newest,
     clip0, clip1, flags, reps, offset) = STATUS.unpack_from(data, 0)
    return StatusFrame(fw, fault, bpct, bmv, (sq0, sq1), oldest, newest,
                       (clip0, clip1), flags, reps, offset)


def build_status(fw_state=0, fault_code=0, battery_pct=100, battery_mv=4100,
                 signal_quality=(0, 0), seq_oldest=0, seq_newest=0,
                 clip_count=(0, 0), flags=0, rep_count=0,
                 host_time_offset_us=0) -> bytes:
    return STATUS.pack(fw_state, fault_code, battery_pct, battery_mv,
                       signal_quality[0], signal_quality[1],
                       seq_oldest, seq_newest, clip_count[0], clip_count[1],
                       flags, rep_count, host_time_offset_us)


# ── Calibration record ─────────────────────────────────────────────────
#
# calib_record_t, carried whole on the calibration characteristic (read and
# write). Alignment 4, so it pads to 88 bytes. Writing it is how a clinician
# -supplied normalisation value supersedes a measured one.
CALIB = struct.Struct("<II2f2f2f4f4f3fffB3x")
assert CALIB.size == 88


@dataclass
class CalibRecord:
    version: int = CALIB_RECORD_VERSION
    timestamp: int = 0
    emg_rest_rms: tuple[float, ...] = (0.0, 0.0)
    emg_mvc: tuple[float, ...] = (1.0, 1.0)
    mdf_baseline: tuple[float, ...] = (0.0, 0.0)
    q_upper0: tuple[float, ...] = (1.0, 0.0, 0.0, 0.0)
    q_fore0: tuple[float, ...] = (1.0, 0.0, 0.0, 0.0)
    flexion_axis: tuple[float, ...] = (0.0, 0.0, 1.0)
    angle_min: float = 0.0
    angle_max: float = 0.0
    flags: int = 0

    @property
    def rom(self) -> float:
        """Mirrors calib_rom(). Every repetition band is a fraction of this,
        never an absolute angle."""
        return self.angle_max - self.angle_min

    @property
    def mvc_unreliable(self) -> bool:
        return bool(self.flags & CALIB_FLAG_MVC_UNRELIABLE)

    def pack(self) -> bytes:
        return CALIB.pack(self.version, self.timestamp, *self.emg_rest_rms,
                          *self.emg_mvc, *self.mdf_baseline, *self.q_upper0,
                          *self.q_fore0, *self.flexion_axis,
                          self.angle_min, self.angle_max, self.flags)


def parse_calib(data: bytes) -> CalibRecord:
    if len(data) < CALIB.size:
        raise ProtocolError(f"calibration record is {len(data)} B, need {CALIB.size}")
    v = CALIB.unpack_from(data, 0)
    return CalibRecord(version=v[0], timestamp=v[1], emg_rest_rms=v[2:4],
                       emg_mvc=v[4:6], mdf_baseline=v[6:8], q_upper0=v[8:12],
                       q_fore0=v[12:16], flexion_axis=v[16:19],
                       angle_min=v[19], angle_max=v[20], flags=v[21])


# ── Frame builders ─────────────────────────────────────────────────────
#
# The mirror image of ble_service.c's publishers. The simulator uses these, and
# they let test_protocol.py build frames the way the firmware builds them
# rather than by hand.

def build_header(ftype: int, seq: int, t_us: int, n: int) -> bytes:
    return HEADER.pack(int(ftype), seq & 0xFFFFFFFF, t_us & 0xFFFFFFFFFFFFFFFF,
                       n & 0xFF)


def _check_budget(frame: bytes, what: str) -> bytes:
    if len(frame) > FRAME_MAX_BYTES:
        raise ProtocolError(
            f"{what} is {len(frame)} B, over the {FRAME_MAX_BYTES} B budget")
    return frame


def build_emg(seq: int, t_us: int, samples, ftype: int = FrameType.EMG) -> bytes:
    """``samples``: a list of per-instant tuples of int16 counts, one per
    channel. Saturating, as ble_notify_emg does."""
    n = min(len(samples), BLE_EMG_BATCH)
    body = b"".join(
        struct.pack(f"<{EMG_CHANNELS}h",
                    *[max(-32768, min(32767, int(v))) for v in s[:EMG_CHANNELS]])
        for s in samples[:n])
    return _check_budget(build_header(ftype, seq, t_us, n) + body, "EMG frame")


def build_imu(seq: int, t_us: int, samples) -> bytes:
    """``samples``: per instant, ((accel_g x3, gyro_dps x3) upper,
    (accel, gyro) forearm). Scaled 1000 LSB/g and 10 LSB/(deg/s)."""
    n = min(len(samples), BLE_IMU_BATCH)
    vals: list[int] = []
    for s in samples[:n]:
        for accel, gyro in s:
            vals += [int(a * 1000.0) for a in accel]
            vals += [int(g * 10.0) for g in gyro]
    body = struct.pack(f"<{len(vals)}h", *vals)
    return _check_budget(build_header(FrameType.IMU, seq, t_us, n) + body,
                         "IMU frame")


def build_features(seq: int, t_us: int, envelope, mdf, elbow_angle_deg: float,
                   upper_arm_dev_deg: float, rep_state: int, rep_count: int,
                   comp_flags: int = 0, sig_flags: int = 0,
                   padded: bool = True) -> bytes:
    """``padded`` reproduces what the firmware emits today; False is the
    layout a packed features_t would give."""
    fmt = FEATURES_PADDED if padded else FEATURES_PACKED
    body = fmt.pack(t_us, envelope[0], envelope[1], mdf[0], mdf[1],
                    elbow_angle_deg, upper_arm_dev_deg, int(rep_state),
                    rep_count, comp_flags, sig_flags)
    return _check_budget(build_header(FrameType.FEATURES, seq, t_us, 1) + body,
                         "feature frame")


def build_event(t_us: int, event: int, payload: bytes = b"") -> bytes:
    if len(payload) > 16:
        raise ProtocolError("event payload is 16 bytes at most")
    body = bytes([int(event), len(payload)]) + payload
    return _check_budget(build_header(FrameType.EVENT, 0, t_us, 1) + body,
                         "event frame")


# ── Repetition result, as EVT_REP_COMPLETE would carry it ──────────────
#
# PROPOSED — NOT YET IN THE FIRMWARE. rep_cycle.c produces a rep_result_t and
# ble_notify_event() can carry 16 payload bytes, but nothing in main.c yet
# emits the event, so no layout exists on the C side to mirror. rep_result_t
# itself is 56 bytes and will not fit, so the fields the host needs have to
# travel in a compact form, and someone has to choose it.
#
# This is that proposal, exactly 16 bytes:
#
#   uint16_t index;          1-based within the set
#   uint8_t  score;          0..100
#   uint8_t  rom_fraction;   percent of calibrated ROM
#   uint8_t  cocontraction;  percent, antagonist/agonist
#   uint8_t  smoothness;     percent
#   uint8_t  hold_steadiness;percent
#   uint8_t  _pad;
#   int16_t  peak_angle;     decidegrees
#   uint16_t comp_flags;
#   uint32_t duration_ms;
#
# The simulator emits this, so the host path is exercised either way. Adopt,
# amend or replace it when main.c grows its event wiring — but change both
# sides together, which is the whole point of ble_service.h's header comment.
REP_COMPLETE_PAYLOAD = struct.Struct("<HBBBBBxhHI")
assert REP_COMPLETE_PAYLOAD.size == 16


@dataclass
class RepComplete:
    index: int
    score: int
    rom_fraction: float
    cocontraction: float
    smoothness: float
    hold_steadiness: float
    peak_angle_deg: float
    comp_flags: int
    duration_ms: int

    @property
    def comp(self) -> list[str]:
        return comp_names(self.comp_flags)

    def pack(self) -> bytes:
        def pct(v: float) -> int:
            return max(0, min(255, int(round(v * 100))))
        return REP_COMPLETE_PAYLOAD.pack(
            self.index, self.score, pct(self.rom_fraction),
            pct(self.cocontraction), pct(self.smoothness),
            pct(self.hold_steadiness), int(round(self.peak_angle_deg * 10)),
            self.comp_flags, self.duration_ms)


def parse_rep_complete(payload: bytes) -> RepComplete:
    if len(payload) < REP_COMPLETE_PAYLOAD.size:
        raise ProtocolError(
            f"REP_COMPLETE payload is {len(payload)} B, "
            f"need {REP_COMPLETE_PAYLOAD.size}")
    (idx, score, rom, cocon, smooth, steady,
     peak_dd, comp, dur) = REP_COMPLETE_PAYLOAD.unpack_from(payload, 0)
    return RepComplete(idx, score, rom / 100.0, cocon / 100.0, smooth / 100.0,
                       steady / 100.0, peak_dd / 10.0, comp, dur)


# ── Command builders ───────────────────────────────────────────────────

def cmd_start(exercise_id: int = 0) -> bytes:
    return bytes([Cmd.START_SESSION, exercise_id & 0xFF])


def cmd_stop() -> bytes:
    return bytes([Cmd.STOP_SESSION])


def cmd_calibrate(phase: int = 0) -> bytes:
    """Phase 0 runs the full protocol. Naming a phase re-runs just that one,
    so a rejected step does not cost the whole 90 seconds — a returning
    patient with a stored profile needs only CalibPhase.NEUTRAL."""
    return bytes([Cmd.START_CALIBRATION, int(phase) & 0xFF])


def cmd_abort_calibration() -> bytes:
    return bytes([Cmd.ABORT_CALIBRATION])


def cmd_get_config() -> bytes:
    return bytes([Cmd.GET_CONFIG])


def cmd_set_config(tlv: bytes) -> bytes:
    """CMD_SET_CONFIG carries TLV. The firmware also accepts a whole
    calib_record_t written to the calibration characteristic, which is how a
    clinician-supplied normalisation value supersedes a measured one."""
    return bytes([Cmd.SET_CONFIG]) + tlv


def tlv(tag: int, value: bytes) -> bytes:
    return bytes([tag & 0xFF, len(value) & 0xFF]) + value


def cmd_recalibrate() -> bytes:
    return bytes([Cmd.REQUEST_RECALIBRATION])


def cmd_ack(seq: int) -> bytes:
    return bytes([Cmd.ACK_SEQ]) + struct.pack("<I", seq)


def cmd_backfill(start: int, end: int) -> bytes:
    return bytes([Cmd.REQUEST_BACKFILL]) + struct.pack("<II", start, end)


def cmd_haptic_test(pattern: int) -> bytes:
    return bytes([Cmd.HAPTIC_TEST, pattern & 0xFF])


def cmd_set_time(epoch_us: int) -> bytes:
    return bytes([Cmd.SET_TIME]) + struct.pack("<Q", epoch_us)


def cmd_power_off() -> bytes:
    return bytes([Cmd.POWER_OFF])
