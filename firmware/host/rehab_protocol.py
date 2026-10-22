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


COMP_SHOULDER = 1 << 0
COMP_TRUNK = 1 << 1
COMP_SWING = 1 << 2


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
        # Mirrors features_t: t_us u64, envelope[2] f, mdf[2] f, angle f,
        # dev f, rep_state u8, rep_count u16, comp u16, sig u16
        fmt = struct.Struct("<Q4f2fBHHH")
        if len(body) < fmt.size:
            raise ProtocolError(
                f"feature frame is {len(body)} B, need {fmt.size}")
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


# ── Command builders ───────────────────────────────────────────────────

def cmd_start(exercise_id: int = 0) -> bytes:
    return bytes([Cmd.START_SESSION, exercise_id & 0xFF])


def cmd_stop() -> bytes:
    return bytes([Cmd.STOP_SESSION])


def cmd_calibrate() -> bytes:
    return bytes([Cmd.START_CALIBRATION, 0])


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
