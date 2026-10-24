"""
rehab_session.py — parse a downloaded RehabSense session.

This is the host half of firmware/main/storage/session_format.h. The struct
formats below must agree byte for byte with the _Static_asserts there; the
record sizes are checked against the manifest the device serves, so a
mismatched pair fails loudly on the first file rather than producing plausible
nonsense.

A session is six files fetched over the sleeve's SoftAP:

    manifest.json   counts, record sizes, scale factors, format version
    emg.bin         raw EMG, full rate, both channels interleaved
    imu.bin         raw accelerometer and gyroscope, both sensors
    features.bin    the device's own 50 Hz calculations
    events.bin      the async event log
    reps.bin        one record per completed repetition

Why the derived streams are downloaded rather than recomputed
------------------------------------------------------------
The device is authoritative for rep boundaries, counts, scores and
compensation flags: those are what fired the haptics the patient actually
felt. Recomputing them here would produce a second opinion that can disagree
with what happened on the arm, and a physician view showing a rep count the
patient never felt is worse than no rep count. If the two ever disagree that
is a firmware bug to find, not a discrepancy to resolve in the viewer.
"""

from __future__ import annotations

import json
import struct
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterator

SESSION_FORMAT_VERSION = 1

# ── Record layouts ──────────────────────────────────────────────────────
# Little-endian, no padding. The '<' matters: the device is little-endian and
# these are raw memory images, not a serialisation.

EMG_N_CHANNELS = 2

# Each format is written out field by field rather than built with a loop or
# a repeat count, because getting one wrong is silent: every field after the
# mistake still unpacks, as a plausible number. The asserts below are the only
# thing that catches it.

EMG_REC = struct.Struct("<hh")                 # ch[0], ch[1]                4 B
IMU_REC = struct.Struct("<12h")                # accel[2][3], gyro[2][3]    24 B
FEATURE_REC = struct.Struct(
    "<I"      # t_ms
    "hh"      # envelope[2]
    "hh"      # mdf[2]
    "h"       # elbow_angle
    "h"       # upper_arm_dev
    "H"       # rep_count
    "BBBB"    # rep_state, comp_flags, sig_flags, activation_on
)                                              #                            22 B
EVENT_REC = struct.Struct("<IBB16s")           # t_ms, id, payload_len, payload
REP_REC = struct.Struct(
    "<II"     # t_start_ms, t_end_ms
    "H"       # index
    "hhhhhhh" # peak, rom, tempo, activation, cocontraction, smooth, steady
    "H"       # comp_flags
    "BB"      # velocity_peaks, score
)                                              #                            28 B

_EXPECTED_SIZES = {
    "emg": 2 * EMG_N_CHANNELS,
    "imu": 24,
    "features": 14 + 4 * EMG_N_CHANNELS,
    "events": 22,
    "reps": 28,
}

for _name, _struct in (
    ("emg", EMG_REC), ("imu", IMU_REC), ("features", FEATURE_REC),
    ("events", EVENT_REC), ("reps", REP_REC),
):
    assert _struct.size == _EXPECTED_SIZES[_name], (
        f"{_name} record is {_struct.size} B here but "
        f"{_EXPECTED_SIZES[_name]} B in session_format.h"
    )


# ── Event ids, mirroring rehab_types.h ──────────────────────────────────

EVENT_NAMES = {
    0x01: "REP_START",
    0x02: "REP_COMPLETE",
    0x03: "REP_ABANDONED",
    0x04: "HOLD_START",
    0x05: "HOLD_COMPLETE",
    0x06: "COMPENSATION_SHOULDER",
    0x07: "COMPENSATION_TRUNK",
    0x08: "COMPENSATION_SWING",
    0x09: "START_POS_OK",
    0x0A: "START_POS_BAD",
    0x0B: "FATIGUE_WARN",
    0x0C: "SIGNAL_DEGRADED",
    0x0D: "CALIB_PHASE_DONE",
    0x0E: "SET_COMPLETE",
    0x0F: "FAULT",
    0x10: "STATE_CHANGE",
    0x11: "PASSIVE_SWING",
}

REP_STATE_NAMES = {
    0: "READY", 1: "CONCENTRIC", 2: "PEAK", 3: "ECCENTRIC", 4: "EXTENDED_HOLD",
}

COMP_FLAG_NAMES = {0x01: "SHOULDER", 0x02: "TRUNK", 0x04: "SWING"}


def comp_flags_to_names(flags: int) -> list[str]:
    return [name for bit, name in COMP_FLAG_NAMES.items() if flags & bit]


# ── Decoded records ─────────────────────────────────────────────────────


@dataclass(slots=True)
class Feature:
    t_s: float
    envelope: tuple[float, ...]      # %MVC, 1.0 == calibrated maximum
    mdf: tuple[float, ...]           # Hz, 0 when below the activation threshold
    elbow_angle_deg: float
    upper_arm_dev_deg: float         # deviation from calibrated neutral
    rep_count: int
    rep_state: int
    comp_flags: int
    sig_flags: int
    activation_on: bool

    @property
    def rep_state_name(self) -> str:
        return REP_STATE_NAMES.get(self.rep_state, f"?{self.rep_state}")


@dataclass(slots=True)
class Event:
    t_s: float
    id: int
    payload: bytes

    @property
    def name(self) -> str:
        return EVENT_NAMES.get(self.id, f"UNKNOWN_0x{self.id:02X}")


@dataclass(slots=True)
class Rep:
    index: int
    t_start_s: float
    t_end_s: float
    peak_angle_deg: float
    rom_fraction: float
    tempo_s: float
    activation: float
    cocontraction: float
    smoothness: float
    hold_steadiness: float
    comp_flags: int
    velocity_peaks: int
    score: int

    @property
    def duration_s(self) -> float:
        return self.t_end_s - self.t_start_s

    @property
    def compensations(self) -> list[str]:
        return comp_flags_to_names(self.comp_flags)


@dataclass
class Session:
    """A downloaded session, parsed.

    `raw_emg` and `raw_imu` stay as bytes until asked for: the EMG alone is
    4.5 MB and most views never touch it. Use emg_array()/imu_array() to get
    NumPy views, or iterate if NumPy is not around.
    """

    manifest: dict
    raw_emg: bytes = b""
    raw_imu: bytes = b""
    features: list[Feature] = field(default_factory=list)
    events: list[Event] = field(default_factory=list)
    reps: list[Rep] = field(default_factory=list)

    # ── Metadata ────────────────────────────────────────────────────────

    @property
    def emg_sample_rate(self) -> int:
        return self.manifest["emg_sample_rate_hz"]

    @property
    def imu_sample_rate(self) -> int:
        return self.manifest["imu_sample_rate_hz"]

    @property
    def duration_s(self) -> float:
        start, end = self.manifest["start_us"], self.manifest["end_us"]
        return (end - start) / 1e6 if end else 0.0

    @property
    def has_gap(self) -> bool:
        """True when a ring wrapped and records were genuinely lost.

        The device never serves a short stream as though it were complete, so
        this is the flag that says the reconstruction is partial. A viewer
        should say so rather than drawing an unbroken trace.
        """
        return bool(self.manifest.get("gap_occurred"))

    # ── Raw streams ─────────────────────────────────────────────────────

    def emg_array(self):
        """(n, channels) int16 view of the raw EMG. Requires NumPy."""
        import numpy as np
        return np.frombuffer(self.raw_emg, dtype="<i2").reshape(-1, EMG_N_CHANNELS)

    def emg_time(self):
        import numpy as np
        n = len(self.raw_emg) // EMG_REC.size
        return np.arange(n) / float(self.emg_sample_rate)

    def imu_array(self):
        """(n, 2, 2, 3) float array indexed [sample, sensor, kind, axis].

        Sensor 0 is the upper arm, sensor 1 the forearm, as everywhere else in
        the system. Kind 0 is acceleration in g, kind 1 angular rate in deg/s.

        Note the transpose. rec_imu_t is `int16 accel[2][3]; int16 gyro[2][3];`
        so the bytes arrive grouped by KIND first and sensor second — all the
        accelerometer data, then all the gyroscope data. Reading it as
        [sample, sensor, kind, axis] without transposing silently swaps the
        forearm's accelerometer for the upper arm's gyroscope, which still
        plots as a believable trace. The round-trip test in test_session.py
        exists mostly to pin this down.

        Scale factors come from the manifest rather than from constants here,
        so a file written by an older firmware still reads correctly.
        """
        import numpy as np
        # [sample, kind, sensor, axis] — the order the struct actually is.
        raw = np.frombuffer(self.raw_imu, dtype="<i2").reshape(-1, 2, 2, 3)
        out = raw.astype("float32")
        out[:, 0, :, :] /= self.manifest["scales"]["accel"]
        out[:, 1, :, :] /= self.manifest["scales"]["gyro"]
        # → [sample, sensor, kind, axis], which is how callers think about it.
        return out.transpose(0, 2, 1, 3)

    def imu_time(self):
        import numpy as np
        n = len(self.raw_imu) // IMU_REC.size
        return np.arange(n) / float(self.imu_sample_rate)

    # ── Convenience ─────────────────────────────────────────────────────

    def events_named(self, *names: str) -> list[Event]:
        wanted = set(names)
        return [e for e in self.events if e.name in wanted]

    def summary(self) -> str:
        counted = len(self.reps)
        flagged = sum(1 for r in self.reps if r.comp_flags)
        abandoned = len(self.events_named("REP_ABANDONED"))
        mean = sum(r.score for r in self.reps) / counted if counted else 0.0
        lines = [
            f"{self.duration_s:,.1f} s session, format v{self.manifest['format_version']}",
            f"{counted} repetitions counted, {flagged} flagged, {abandoned} abandoned",
            f"mean score {mean:.0f}",
            f"{len(self.raw_emg) // EMG_REC.size:,} EMG samples at {self.emg_sample_rate} Hz",
            f"{len(self.raw_imu) // IMU_REC.size:,} IMU samples at {self.imu_sample_rate} Hz",
            f"{len(self.features):,} feature frames, {len(self.events)} events",
        ]
        if self.has_gap:
            lines.append("WARNING: a buffer wrapped — this session is incomplete")
        return "\n".join(lines)


# ── Parsing ─────────────────────────────────────────────────────────────


def _iter_features(blob: bytes, scales: dict) -> Iterator[Feature]:
    env_s = scales["envelope"]
    mdf_s = scales["mdf"]
    ang_s = scales["angle"]
    for (t_ms, e0, e1, m0, m1, elbow, dev, reps,
         state, comp, sig, act) in FEATURE_REC.iter_unpack(blob):
        yield Feature(
            t_s=t_ms / 1000.0,
            envelope=(e0 / env_s, e1 / env_s),
            mdf=(m0 / mdf_s, m1 / mdf_s),
            elbow_angle_deg=elbow / ang_s,
            upper_arm_dev_deg=dev / ang_s,
            rep_count=reps,
            rep_state=state,
            comp_flags=comp,
            sig_flags=sig,
            activation_on=bool(act),
        )


def _iter_events(blob: bytes) -> Iterator[Event]:
    for t_ms, eid, plen, payload in EVENT_REC.iter_unpack(blob):
        yield Event(t_s=t_ms / 1000.0, id=eid, payload=payload[:plen])


def _iter_reps(blob: bytes, scales: dict) -> Iterator[Rep]:
    ang_s = scales["angle"]
    frac_s = scales["fraction"]
    env_s = scales["envelope"]
    sec_s = scales["seconds"]
    for (t0, t1, idx, peak, rom, tempo, act, cocon,
         smooth, steady, comp, vpeaks, score) in REP_REC.iter_unpack(blob):
        yield Rep(
            index=idx,
            t_start_s=t0 / 1000.0,
            t_end_s=t1 / 1000.0,
            peak_angle_deg=peak / ang_s,
            rom_fraction=rom / frac_s,
            tempo_s=tempo / sec_s,
            activation=act / env_s,
            cocontraction=cocon / frac_s,
            smoothness=smooth / frac_s,
            hold_steadiness=steady / frac_s,
            comp_flags=comp,
            velocity_peaks=vpeaks,
            score=score,
        )


def load(directory: str | Path) -> Session:
    """Load a session from a directory written by rehab_fetch.py."""
    d = Path(directory)
    manifest = json.loads((d / "manifest.json").read_text())

    version = manifest.get("format_version")
    if version != SESSION_FORMAT_VERSION:
        raise ValueError(
            f"session format v{version}, this parser understands "
            f"v{SESSION_FORMAT_VERSION}. Update rehab_session.py alongside "
            f"session_format.h rather than guessing at the layout."
        )

    # The manifest states each record size. Checking it against what this
    # module believes turns a layout drift into one clear error instead of
    # millions of misaligned samples.
    for name, expect in _EXPECTED_SIZES.items():
        got = manifest["streams"][name]["record_bytes"]
        if got != expect:
            raise ValueError(
                f"{name} records are {got} B on the device but {expect} B "
                f"here — session_format.h and rehab_session.py disagree"
            )

    scales = manifest["scales"]

    def read(name: str) -> bytes:
        p = d / Path(manifest["streams"][name]["path"]).name
        return p.read_bytes() if p.exists() else b""

    return Session(
        manifest=manifest,
        raw_emg=read("emg"),
        raw_imu=read("imu"),
        features=list(_iter_features(read("features"), scales)),
        events=list(_iter_events(read("events"))),
        reps=list(_iter_reps(read("reps"), scales)),
    )


if __name__ == "__main__":
    import sys
    if len(sys.argv) != 2:
        print("usage: rehab_session.py <session-directory>", file=sys.stderr)
        raise SystemExit(2)
    print(load(sys.argv[1]).summary())
