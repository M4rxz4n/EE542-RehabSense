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
UUID_CONFIG = BASE.format(0x0008)   # serialised TLV, read + notify
UUID_XFER = BASE.format(0x0009)     # bulk-transfer credentials, read + notify

DEVICE_NAME = "RehabSense"

#: Phase 1 prototype: ONE MyoWare on the biceps — two electrodes on the muscle
#: belly plus one reference on the bony elbow landmark, three electrodes in
#: all. Phase 2's custom PCB adds the triceps, and with it the co-contraction
#: component of the score.
#:
#: Every layout in this file is derived from this number, and rehab_config.h
#: carries the same constant. If the two disagree, every multi-channel frame
#: is misread.
EMG_N_CHANNELS = 1

#: Alias, so the raw-frame code reads naturally.
EMG_CHANNELS = EMG_N_CHANNELS
EMG_SAMPLE_RATE_HZ = 2000
IMU_SAMPLE_RATE_HZ = 100
FEATURE_RATE_HZ = 50

# Batch sizes and the frame budget, mirroring rehab_config.h.
FRAME_MAX_BYTES = 180
# Samples per EMG frame. Derived from the channel count so the frame is the
# same size whichever front end is fitted: 80 samples of one channel and 40 of
# two both come to 14 + 160 = 174 B. rehab_config.h derives it the same way.
BLE_EMG_BATCH = 80 // EMG_N_CHANNELS
BLE_IMU_BATCH = 6         #  6 x 24 B + 14 = 158 B, 16.7 frames/s
EMG_FRAME_BYTES = 14 + BLE_EMG_BATCH * EMG_N_CHANNELS * 2


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
    # Bulk transfer over Wi-Fi [firmware/main/net/session_xfer.h]. START
    # brings up the sleeve's SoftAP and answers on UUID_XFER with the SSID,
    # password and address; the session itself is fetched by rehab_fetch.py
    # over HTTP, not over BLE.
    START_TRANSFER = 0x0D
    STOP_TRANSFER = 0x0E


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
    PASSIVE_SWING = 0x11     # angle rose with the agonist quiet; not counted


class FwState(IntEnum):
    OFF = 0
    BOOT = 1
    STANDBY = 2
    DONNING_CHECK = 3
    CALIBRATION = 4
    OPERATIONAL = 5
    FAULT = 6


class RepState(IntEnum):
    """rep_cycle.h — PRD §5.4.

    READY -> CONCENTRIC -> PEAK -> ECCENTRIC -> EXTENDED_HOLD -> (counted)

    The count happens on the RETURN, after a confirming hold at the extended
    position, so the score covers the eccentric phase and the haptic lands at
    a moment the patient is already stationary.
    """
    READY = 0
    CONCENTRIC = 1
    PEAK = 2
    ECCENTRIC = 3
    EXTENDED_HOLD = 4


class CalibPhase(IntEnum):
    """calibration.h — the step protocol of PRD §5.3.

    Carried as the uint8 argument of START_CALIBRATION, so a failed step can
    be repeated on its own without restarting.

    On the single-channel prototype there is no TRICEPS step: one MyoWare on
    the biceps has no antagonist to measure.
    """
    IDLE = 0
    CONTACT = 1       # step 0 — donning and contact check
    REST = 2          # EMG mean and sigma, gyroscope bias
    STRAIGHT = 3      # comfortable-straight reference pose
    BICEPS = 4        # agonist maximum, best of three
    TRICEPS = 5       # antagonist maximum — Phase 2 only
    SWEEP = 6         # flexion axis, angle_min, angle_max
    ALL = 7           # run the whole protocol
    DONE = 8
    FAILED = 9


class HapticPattern(IntEnum):
    """patterns.h — one ERM, seven messages, distinguished by RHYTHM.

    An ERM's vibration frequency is coupled to its amplitude, so "stronger"
    also means "faster" and cannot carry independent meaning. Every cue plays
    at one consistent amplitude; the rest ramp and the soft click are the
    exceptions, and both are a change in CHARACTER rather than a level that
    carries meaning.
    """
    NONE = 0
    TICK = 1                 # 40 ms — button acknowledged
    REP_CLEAN = 2            # one 100 ms click
    REP_FLAGGED = 3          # three 80 ms pulses, 80 ms gaps
    SET_COMPLETE = 4         # two 70 ms pulses, then one 500 ms
    REST = 5                 # 1000 ms ramp up and down
    FAULT = 6                # two 300 ms pulses, 300 ms apart
    SOFT_CLICK = 7           # 30 ms, reduced level — 80 % of target angle
    REP_CLEAN_THEN_SET = 8   # the compound cues for the repetition that
    REP_FLAGGED_THEN_SET = 9 #   completes the set, with a 300 ms gap


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
#: Version 2 adds emg_rest_sd[] and gyro_bias[][], which the activation
#: detector and the joint angle respectively depend on.
CALIB_RECORD_VERSION = 2


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
# features_t is NOT packed, and ble_notify_features() memcpy's the whole
# struct, so this layout must reproduce the compiler's padding exactly.
#
#   uint64 t_us | float envelope[N] | float mdf[N] | float angle | float dev
#   uint8 rep_state | <pad> | uint16 rep_count, comp_flags, sig_flags
#   uint8 activation_on | <pad to the struct's 8-byte alignment>
_FEAT_BODY = ("<Q" + "f" * (2 * EMG_N_CHANNELS) + "2f" + "Bx" + "HHH" + "B")
_FEAT_UNPADDED = struct.calcsize(_FEAT_BODY)
_FEAT_TAIL = (-_FEAT_UNPADDED) % 8          # trailing pad to alignment 8

FEATURES_PADDED = struct.Struct(_FEAT_BODY + ("x" * _FEAT_TAIL))
FEATURES_PACKED = struct.Struct(
    "<Q" + "f" * (2 * EMG_N_CHANNELS) + "2f" + "B" + "HHH" + "B")


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
    activation_on: bool = False   # agonist above threshold [PRD §5.4]


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
        v = fmt.unpack_from(body, 0)
        n = EMG_N_CHANNELS
        env = v[1:1 + n]
        mdf = v[1 + n:1 + 2 * n]
        ang, dev = v[1 + 2 * n], v[2 + 2 * n]
        rstate, rcount = v[3 + 2 * n], v[4 + 2 * n]
        comp, sig = v[5 + 2 * n], v[6 + 2 * n]
        act = bool(v[7 + 2 * n]) if len(v) > 7 + 2 * n else False
        return FeatureFrame(seq, t_us, env, mdf, ang, dev,
                            rstate, rcount, comp, sig, act)

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
# device_status_t is __attribute__((packed)) in ble_service.h — no padding at
# all. The format below therefore has no pad bytes either, and "<" keeps
# struct in standard-size, unaligned mode to match.
#
# This used to carry explicit padding ("<BBBxH2BIIIIBxH4xq", 40 bytes) that
# the packed C struct does not have, so every field after battery_mv was read
# from the wrong offset. Nothing caught it because the host tests parse what
# the host builds; only a real device would have shown it.
STATUS = struct.Struct("<BBBH" + f"{EMG_N_CHANNELS}B" + "II"
                       + f"{EMG_N_CHANNELS}I" + "BHq")
assert STATUS.size == 24 + 5 * EMG_N_CHANNELS, (
    f"device_status_t is {24 + 5 * EMG_N_CHANNELS} B packed, "
    f"not {STATUS.size}")


# ── Bulk-transfer credentials, characteristic 0x0009 ────────────────────
#
# xfer_info_t in ble_service.h, packed, 63 bytes. Notified in answer to
# START_TRANSFER and again once a second while a transfer is live, and
# readable at any time so a client that reconnects mid-transfer recovers the
# credentials instead of forcing the device to tear the AP down and start over.

XFER = struct.Struct("<BBHIHI33s16s")
assert XFER.size == 63, f"xfer_info_t is 63 B packed, not {XFER.size}"


class XferState(IntEnum):
    IDLE = 0
    STARTING = 1
    READY = 2
    COMPLETE = 3
    FAILED = 4


@dataclass
class XferInfo:
    """Where to fetch the session from, once the AP is up.

    `state` READY means the access point is live and the HTTP server is
    answering. FAILED means the device refused — almost always because a set
    is still running, or because no session has been sealed yet.
    """

    state: int
    clients: int
    seconds_remaining: int
    ipv4: str
    port: int
    bytes_served: int
    ssid: str
    password: str

    @property
    def state_name(self) -> str:
        try:
            return XferState(self.state).name
        except ValueError:
            return f"UNKNOWN_{self.state}"

    @property
    def ready(self) -> bool:
        return self.state == XferState.READY

    def join_hint(self) -> str:
        """What to tell the operator, in one line."""
        if not self.ready:
            return f"transfer {self.state_name.lower()}"
        return (f"join Wi-Fi \"{self.ssid}\" (password {self.password}), "
                f"then: python rehab_fetch.py --host {self.ipv4}")


def parse_xfer(data: bytes) -> XferInfo:
    (state, clients, secs, ipv4, port,
     served, ssid, password) = XFER.unpack(data[:XFER.size])
    # The device stores the AP address in network byte order, as the lwIP
    # netif reports it; rendering it here keeps the dotted form in one place.
    octets = ".".join(str((ipv4 >> (8 * i)) & 0xFF) for i in range(4))
    return XferInfo(
        state=state,
        clients=clients,
        seconds_remaining=secs,
        ipv4=octets,
        port=port,
        bytes_served=served,
        ssid=ssid.split(b"\0")[0].decode("ascii", "replace"),
        password=password.split(b"\0")[0].decode("ascii", "replace"),
    )


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
    v = STATUS.unpack_from(data, 0)
    n = EMG_N_CHANNELS
    fw, fault, bpct, bmv = v[0], v[1], v[2], v[3]
    sq = v[4:4 + n]
    oldest, newest = v[4 + n], v[5 + n]
    clip = v[6 + n:6 + 2 * n]
    flags, reps, offset = v[6 + 2 * n], v[7 + 2 * n], v[8 + 2 * n]
    return StatusFrame(fw, fault, bpct, bmv, sq, oldest, newest,
                       clip, flags, reps, offset)


def build_status(fw_state=0, fault_code=0, battery_pct=100, battery_mv=4100,
                 signal_quality=None, seq_oldest=0, seq_newest=0,
                 clip_count=None, flags=0, rep_count=0,
                 host_time_offset_us=0) -> bytes:
    n = EMG_N_CHANNELS
    sq = tuple(signal_quality or (0,) * n)[:n]
    cc = tuple(clip_count or (0,) * n)[:n]
    sq += (0,) * (n - len(sq))
    cc += (0,) * (n - len(cc))
    return STATUS.pack(fw_state, fault_code, battery_pct, battery_mv, *sq,
                       seq_oldest, seq_newest, *cc,
                       flags, rep_count, host_time_offset_us)


# ── Calibration record ─────────────────────────────────────────────────
#
# calib_record_t, carried whole on the calibration characteristic (read and
# write). NOT packed on the C side, so it pads to a 4-byte boundary; the
# matching _Static_assert in rehab_types.h pins the same arithmetic. Writing
# it is how a clinician-supplied normalisation value supersedes a measured
# one [PRD §5.3].
CALIB = struct.Struct("<II" + "f" * (4 * EMG_N_CHANNELS + 6 + 8 + 3 + 2)
                      + "B3x")


@dataclass
class CalibRecord:
    version: int = CALIB_RECORD_VERSION
    timestamp: int = 0
    emg_rest_rms: tuple[float, ...] = (0.0,) * EMG_N_CHANNELS
    emg_rest_sd: tuple[float, ...] = (0.0,) * EMG_N_CHANNELS
    emg_mvc: tuple[float, ...] = (1.0,) * EMG_N_CHANNELS
    mdf_baseline: tuple[float, ...] = (0.0,) * EMG_N_CHANNELS
    gyro_bias: tuple[float, ...] = (0.0,) * 6   # [upper xyz][fore xyz]
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
        return CALIB.pack(self.version, self.timestamp,
                          *self.emg_rest_rms, *self.emg_rest_sd,
                          *self.emg_mvc, *self.mdf_baseline, *self.gyro_bias,
                          *self.q_upper0, *self.q_fore0, *self.flexion_axis,
                          self.angle_min, self.angle_max, self.flags)


def parse_calib(data: bytes) -> CalibRecord:
    if len(data) < CALIB.size:
        raise ProtocolError(f"calibration record is {len(data)} B, need {CALIB.size}")
    v = CALIB.unpack_from(data, 0)
    n = EMG_N_CHANNELS
    i = 2
    rest_rms = v[i:i + n];      i += n
    rest_sd  = v[i:i + n];      i += n
    mvc      = v[i:i + n];      i += n
    mdf      = v[i:i + n];      i += n
    bias     = v[i:i + 6];      i += 6
    q_up     = v[i:i + 4];      i += 4
    q_fo     = v[i:i + 4];      i += 4
    axis     = v[i:i + 3];      i += 3
    return CalibRecord(version=v[0], timestamp=v[1],
                       emg_rest_rms=rest_rms, emg_rest_sd=rest_sd,
                       emg_mvc=mvc, mdf_baseline=mdf, gyro_bias=bias,
                       q_upper0=q_up, q_fore0=q_fo, flexion_axis=axis,
                       angle_min=v[i], angle_max=v[i + 1], flags=v[i + 2])


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
                   activation_on: bool = False,
                   padded: bool = True) -> bytes:
    """``padded`` reproduces what the firmware emits today; False is the
    layout a packed features_t would give."""
    fmt = FEATURES_PADDED if padded else FEATURES_PACKED
    n = EMG_N_CHANNELS
    body = fmt.pack(t_us, *tuple(envelope)[:n], *tuple(mdf)[:n],
                    elbow_angle_deg, upper_arm_dev_deg, int(rep_state),
                    rep_count, comp_flags, sig_flags, int(activation_on))
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


def cmd_calibrate(step: int = CalibPhase.ALL) -> bytes:
    """CalibPhase.ALL runs the whole protocol. Naming a single step re-runs
    just that one, so a rejected step does not cost the entire protocol — and
    the step most likely to be rejected is a maximum contraction on a paretic
    limb, which is the one a patient least wants to repeat four others to get
    back to [PRD §5.3]."""
    return bytes([Cmd.START_CALIBRATION, int(step) & 0xFF])


def cmd_abort_calibration() -> bytes:
    return bytes([Cmd.ABORT_CALIBRATION])


def cmd_get_config() -> bytes:
    return bytes([Cmd.GET_CONFIG])


def cmd_set_config(tlv_block: bytes) -> bytes:
    """CMD_SET_CONFIG carries a TLV block (see CfgTag).

    A clinician-supplied normalisation value goes a different way: a whole
    calib_record_t written to the CALIBRATION characteristic. The two used to
    share this opcode, which would have delivered a calib_record_t to the TLV
    parser the moment the config path existed."""
    return bytes([Cmd.SET_CONFIG]) + tlv_block


def tlv(tag: int, value: bytes) -> bytes:
    return bytes([tag & 0xFF, len(value) & 0xFF]) + value


class CfgTag(IntEnum):
    """config.h — the runtime parameters of PRD §5.9.1.

    TLV rather than a packed struct, so a newer host can talk to older
    firmware. An unrecognised tag is SKIPPED; a recognised tag with the wrong
    length is REJECTED, because a length mismatch means the two sides disagree
    about what the tag means.
    """
    HOLD_MS = 0x01            # uint16, 300..3000
    HOLD_VEL = 0x02           # float, deg/s
    REP_TARGET = 0x03         # uint8, 1..50
    SET_COUNT = 0x04          # uint8
    REST_SECONDS = 0x05       # uint16
    TARGET_ANGLE = 0x06       # float, deg
    START_ANGLE = 0x07        # float, deg
    FINISH_ANGLE = 0x08       # float, deg
    TEMPO = 0x09              # float x2: min, max (seconds)
    COMP_THRESH = 0x0A        # float x3: shoulder, trunk, swing
    WEIGHTS = 0x0B            # float x5: range,tempo,smooth,cocon,hold
    DEDUCTIONS = 0x0C         # float x3: shoulder, trunk, swing
    RAW_STREAM = 0x0D         # uint8
    CHANNEL_ROLES = 0x0E      # uint8 x2: exercise id, agonist channel


def cfg_u8(tag: CfgTag, v: int) -> bytes:
    return tlv(tag, struct.pack("<B", v & 0xFF))


def cfg_u16(tag: CfgTag, v: int) -> bytes:
    return tlv(tag, struct.pack("<H", v & 0xFFFF))


def cfg_f32(tag: CfgTag, *vals: float) -> bytes:
    return tlv(tag, struct.pack("<" + "f" * len(vals), *vals))


def parse_config_tlv(block: bytes) -> dict[int, bytes]:
    """Split a serialised configuration into {tag: raw value}. Used by the host
    to read back what GET_CONFIG returned and confirm a write took effect."""
    out: dict[int, bytes] = {}
    i = 0
    while i + 2 <= len(block):
        tag, length = block[i], block[i + 1]
        if i + 2 + length > len(block):
            raise ProtocolError(f"truncated TLV at tag 0x{tag:02X}")
        out[tag] = bytes(block[i + 2:i + 2 + length])
        i += 2 + length
    return out


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


def cmd_start_transfer() -> bytes:
    """Bring up the Wi-Fi AP so the session can be downloaded.

    Refused by the device while a set is running: the S3 has one 2.4 GHz
    radio and the live BLE stream wins. Refused too when no session has been
    sealed, because serving a buffer whose counts are still moving produces a
    file that is internally inconsistent.

    The answer arrives on UUID_XFER as an XferInfo.
    """
    return bytes([Cmd.START_TRANSFER])


def cmd_stop_transfer() -> bytes:
    return bytes([Cmd.STOP_TRANSFER])
