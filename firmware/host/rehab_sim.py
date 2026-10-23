"""
rehab_sim.py — a simulated RehabSense device.

The host client has to be finished before the board is, and after it is built
there is still no way to rehearse a dropped link, a fatiguing set or a staged
compensation on demand. This is a device-shaped thing on the other end of a
loopback that speaks the real wire format: the same 14-byte header, the same
four frame types, the same control opcodes, the same 180-byte budget, the same
hold-gated repetition cycle from rep_cycle.h, and grading.c's scoring through
rehab_grading.

    python3 rehab_client.py --sim --duration 60

What it is faithful about: the protocol, the state machine, the event
vocabulary, the frame rates and the byte budgets.

What it is not: a model of an arm, of electrode physics, or of BLE timing. The
numbers are plausible, not measured. Do not tune thresholds against it — tune
them against recorded volunteer data. Its job is to prove the host works and to
keep both sides honest about the contract.
"""

from __future__ import annotations

import asyncio
import math
import random
import struct
import time
from dataclasses import dataclass, field, replace

import rehab_protocol as p
from rehab_grading import Accumulator, DEFAULT_WEIGHTS, RepResult, haptic_for

# ── rehab_config.h ─────────────────────────────────────────────────────
TICK_HZ = p.FEATURE_RATE_HZ              # 50 Hz analysis tick
TICK_MS = 1000 // TICK_HZ                # 20 ms
EMG_PER_TICK = p.EMG_SAMPLE_RATE_HZ // TICK_HZ      # 40 — one frame per tick
IMU_PER_TICK = p.IMU_SAMPLE_RATE_HZ // TICK_HZ      # 2

# Repetition geometry [PRD §5.4]. Thresholds are angles against the
# therapist's target, not fractions of measured ROM: the therapist prescribes
# what the patient SHOULD reach, which is not what they currently can.
REP_TARGET_ANGLE_DEG = 110.0
REP_PEAK_FRAC = 0.80            # "target reached" at 80 % of target
REP_START_ANGLE_DEG = 15.0
REP_FINISH_ANGLE_DEG = 10.0
REP_TARGET_DEFAULT = 20
SET_COUNT_DEFAULT = 3
REST_SECONDS_DEFAULT = 60

# Activation detector [PRD §5.4].
ACT_ON_SIGMA = 3.0
ACT_OFF_SIGMA = 2.0
ACT_ON_CONFIRM_MS = 50
ACT_OFF_CONFIRM_MS = 100
ACT_MIN_THRESH = 0.02
EMG_NOISE_FLOOR_MULT = 1.5

REP_HOLD_MS = 1000
REP_PHASE_TIMEOUT_MS = 10000
REP_HOLD_MAX_VEL_DPS = 15.0
START_POS_UPPER_ARM_TOL_DEG = 15.0

COMP_SHOULDER_HIKE_DEG = 20.0   # [PRD §5.5]
COMP_TRUNK_LEAN_DEG = 10.0
COMP_ARM_SWING_DPS = 30.0
COMP_ARM_SWING_SUSTAIN_MS = 200
COMP_CONFIRM_MS = 30

FATIGUE_MDF_SLOPE_THRESH = -0.5          # Hz per repetition
FATIGUE_CONSEC_REPS = 3
MDF_MIN_ACTIVATION = 0.15

# Calibration [PRD §5.3]: five steps on the single-channel prototype
# (the triceps maximum needs a second channel), ~16 s of capture.
CALIB_REST_MS = 5000
CALIB_STRAIGHT_MS = 2000
CALIB_MVC_MS = 3000
CALIB_MVC_ATTEMPTS = 3
CALIB_SWEEP_MS = 6000


class _Activation:
    """Mirror of activation.c — muscle-on detection with hysteresis.

    A single-threshold detector chatters at the boundary, and chatter on this
    signal means repetitions starting and abandoning at random. The asymmetric
    confirmation windows (fast on, slow off) are what make the gate usable.
    """

    def __init__(self, calib, channel: int) -> None:
        rest = calib.emg_rest_rms[channel]
        sd = calib.emg_rest_sd[channel]
        mvc = calib.emg_mvc[channel]

        # The envelope has already been normalised: zeroed below rest x MULT,
        # then scaled so the maximum reads 1.0. Raw thresholds must go through
        # the same transform or they land somewhere else entirely.
        floor_v = rest * EMG_NOISE_FLOOR_MULT
        denom = mvc - floor_v

        if denom > 1e-9 and sd > 0.0:
            self.on_thresh = (rest + ACT_ON_SIGMA * sd - floor_v) / denom
            self.off_thresh = (rest + ACT_OFF_SIGMA * sd - floor_v) / denom
            if self.on_thresh < ACT_MIN_THRESH:
                self.on_thresh = ACT_MIN_THRESH
                self.off_thresh = ACT_MIN_THRESH * 0.66
        else:
            self.on_thresh = 0.10
            self.off_thresh = 0.066

        self.off_thresh = min(self.off_thresh, self.on_thresh)
        self._on_needed = max(1, -(-ACT_ON_CONFIRM_MS * TICK_HZ // 1000))
        self._off_needed = max(1, -(-ACT_OFF_CONFIRM_MS * TICK_HZ // 1000))
        self.reset()

    def reset(self) -> None:
        self.on = False
        self._on_ticks = 0
        self._off_ticks = 0

    def update(self, envelope: float) -> bool:
        if not self.on:
            if envelope > self.on_thresh:
                self._on_ticks += 1
                if self._on_ticks >= self._on_needed:
                    self.on = True
                    self._off_ticks = 0
            else:
                self._on_ticks = 0
        else:
            if envelope < self.off_thresh:
                self._off_ticks += 1
                if self._off_ticks >= self._off_needed:
                    self.on = False
                    self._on_ticks = 0
            else:
                self._off_ticks = 0
        return self.on


# ── Scenario ───────────────────────────────────────────────────────────


@dataclass
class RepPlan:
    """One repetition the simulated patient attempts."""

    peak_deg: float = 94.0
    rise_s: float = 1.6
    fall_s: float = 1.7
    bottom_hold_s: float = 1.3          # must clear REP_HOLD_MS to arm
    top_hold_s: float = 1.3             # must clear REP_HOLD_MS to count
    tremor_deg: float = 0.5             # wobble during the holds
    jerkiness: float = 0.0              # extra velocity reversals on the way
    activation: float = 0.55            # agonist %MVC at peak effort
    cocontraction: float = 0.12
    shoulder_deg: float = 4.0
    trunk_deg: float = 2.0
    swing: bool = False
    bad_start: bool = False             # upper arm outside the start tolerance
    abandon: bool = False               # stalls mid-range past the timeout
    label: str = ""


@dataclass
class Profile:
    seed: int = 7
    speed: float = 1.0                  # wall-clock multiplier
    angle_min: float = 8.0              # from the patient's own ROM sweep
    angle_max: float = 100.0
    mvc_unreliable: bool = False
    mdf_baseline: float = 96.0
    mdf_fall_per_rep: float = 0.9
    fatigue_onset_rep: int = 6
    battery_start_pct: int = 92
    rest_envelope: float = 0.03         # %MVC at rest

    #: The therapist's prescription for THIS patient. A default of 110 deg is
    #: the PRD's starting figure for a healthy volunteer; a patient whose own
    #: maximum is 100 deg would never clear 80 % of it, which is exactly why
    #: the target is therapist-set and host-configurable [PRD §5.9.1].
    target_angle: float = 100.0
    plans: list[RepPlan] = field(default_factory=list)


def demo_scenario() -> Profile:
    """Clean repetitions, then the behaviours worth demonstrating: a staged
    shoulder hike, an arm swung rather than curled, a bad start posture, a
    repetition abandoned mid-range, heavy co-contraction, and a fatiguing
    run-out."""
    plans = [
        RepPlan(label="clean"),
        RepPlan(peak_deg=97.0, label="clean"),
        RepPlan(peak_deg=92.0, shoulder_deg=24.0, label="shoulder hike"),
        RepPlan(peak_deg=95.0, activation=0.07, swing=True,
                label="swung, not curled"),
        RepPlan(peak_deg=93.0, bad_start=True, label="bad start posture"),
        RepPlan(peak_deg=60.0, abandon=True, label="abandoned mid-range"),
        RepPlan(peak_deg=94.0, cocontraction=0.55, label="co-contraction"),
        RepPlan(peak_deg=96.0, trunk_deg=16.0, label="trunk lean"),
    ]
    for i in range(10):
        plans.append(RepPlan(peak_deg=max(84.0, 96.0 - 1.4 * i),
                             rise_s=1.6 + 0.09 * i, fall_s=1.7 + 0.1 * i,
                             tremor_deg=0.5 + 0.08 * i,
                             jerkiness=0.6 if i > 5 else 0.0,
                             activation=max(0.22, 0.55 - 0.025 * i),
                             cocontraction=0.12 + 0.02 * i,
                             shoulder_deg=4.0 + 1.3 * i,
                             label="fatiguing"))
    return Profile(plans=plans)


# ── Synthetic EMG ──────────────────────────────────────────────────────


class _Biquad:
    """RBJ band-pass. Gives the synthetic EMG a centre frequency that can be
    made to fall with fatigue, which is what makes the raw stream worth
    streaming at all."""

    def __init__(self, fs: float, f0: float, q: float = 0.7) -> None:
        self.fs = fs
        self._z1 = self._z2 = 0.0
        self.retune(f0, q)

    def retune(self, f0: float, q: float = 0.7) -> None:
        w0 = 2 * math.pi * max(5.0, min(self.fs / 2 - 10, f0)) / self.fs
        alpha = math.sin(w0) / (2 * q)
        a0 = 1 + alpha
        self.b0, self.b1, self.b2 = alpha / a0, 0.0, -alpha / a0
        self.a1, self.a2 = (-2 * math.cos(w0)) / a0, (1 - alpha) / a0

    def step(self, x: float) -> float:
        y = self.b0 * x + self._z1
        self._z1 = self.b1 * x - self.a1 * y + self._z2
        self._z2 = self.b2 * x - self.a2 * y
        return y


def _min_jerk(f: float) -> float:
    f = max(0.0, min(1.0, f))
    return 10 * f ** 3 - 15 * f ** 4 + 6 * f ** 5


# ── Loopback transport ─────────────────────────────────────────────────


class LoopbackClient:
    """The subset of the BleakClient surface rehab_client uses, wired to a
    SimulatedDevice instead of a radio. Notifications are delivered through
    call_soon so they land on the event loop the way a real one does, rather
    than inside the device's own call stack."""

    def __init__(self, device: "SimulatedDevice") -> None:
        self._dev = device
        self._subs: dict[str, object] = {}
        self.is_connected = True
        self.mtu_size = 185              # what CoreBluetooth would give
        #: Set while a dropout is being simulated.
        self.link_down = False
        self.dropped = 0
        device.attach(self)

    async def __aenter__(self) -> "LoopbackClient":
        return self

    async def __aexit__(self, *exc) -> None:
        self.is_connected = False

    async def connect(self) -> None:
        self.is_connected = True

    async def disconnect(self) -> None:
        self.is_connected = False

    async def start_notify(self, uuid: str, cb) -> None:
        self._subs[uuid] = cb

    async def stop_notify(self, uuid: str) -> None:
        self._subs.pop(uuid, None)

    async def write_gatt_char(self, uuid: str, data: bytes,
                              response: bool = False) -> None:
        if self.link_down:
            raise RuntimeError("link down")
        if uuid == p.UUID_CONTROL:
            self._dev.on_command(data[0], data[1:])
        elif uuid == p.UUID_CALIB:
            self._dev.on_calib_write(bytes(data))

    async def read_gatt_char(self, uuid: str) -> bytes:
        if uuid == p.UUID_STATUS:
            return self._dev.status_bytes()
        if uuid == p.UUID_CALIB:
            return self._dev.calib.pack()
        raise RuntimeError(f"cannot read {uuid}")

    def notify(self, uuid: str, data: bytes) -> None:
        """Called by the device to push one notification."""
        if self.link_down or not self.is_connected:
            self.dropped += 1
            return
        cb = self._subs.get(uuid)
        if cb is None:
            return
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            return
        loop.call_soon(cb, uuid, bytearray(data))


# ── The device ─────────────────────────────────────────────────────────


class SimulatedDevice:
    def __init__(self, profile: Profile | None = None) -> None:
        self.profile = profile or demo_scenario()
        self.rng = random.Random(self.profile.seed)
        self.client: LoopbackClient | None = None

        n = p.EMG_N_CHANNELS
        self.calib = p.CalibRecord(
            version=p.CALIB_RECORD_VERSION, timestamp=int(time.time()),
            emg_rest_rms=(0.004,) * n,
            emg_rest_sd=(0.0008,) * n,
            emg_mvc=(1.0,) * n,
            mdf_baseline=(self.profile.mdf_baseline,) * n,
            angle_min=self.profile.angle_min, angle_max=self.profile.angle_max,
            flags=p.CALIB_FLAG_MVC_UNRELIABLE if self.profile.mvc_unreliable else 0)

        self.fw_state = p.FwState.STANDBY
        self.fault = p.Fault.NONE
        self.t_us = 0
        self.running = False
        self.host_time_offset_us = 0

        self.rep_state = p.RepState.READY
        self.rep_count = 0
        self.total_reps = 0
        self._hold_ms = 0
        self._phase_ms = 0
        self._acc: Accumulator | None = None
        self._comp_latched = 0
        self._comp_confirm = {p.COMP_SHOULDER: 0, p.COMP_TRUNK: 0, p.COMP_SWING: 0}
        self._swing_ms = 0
        self._start_pos_ok: bool | None = None
        self._start_pos_bad = False
        self._passive_last_ms = -10_000
        self._rep_start_us = 0
        self._set_complete_fired = False

        # Runtime configuration [PRD §5.9.1]. Defaults here, overridable by
        # SET_CONFIG exactly as on the device.
        self.weights = DEFAULT_WEIGHTS
        self.cfg_hold_ms = REP_HOLD_MS
        self.cfg_hold_velocity = REP_HOLD_MAX_VEL_DPS
        self.cfg_rep_target = REP_TARGET_DEFAULT
        self.cfg_set_count = SET_COUNT_DEFAULT
        self.cfg_rest_seconds = REST_SECONDS_DEFAULT
        self.cfg_target_angle = self.profile.target_angle
        self.cfg_start_angle = REP_START_ANGLE_DEG
        self.cfg_finish_angle = REP_FINISH_ANGLE_DEG
        self.cfg_raw_stream = 1
        self._activation = _Activation(self.calib, 0)

        self.angle = self.profile.angle_min + 2.0
        self.velocity = 0.0
        self.envelope = [self.profile.rest_envelope] * p.EMG_CHANNELS
        self.mdf = [0.0] * p.EMG_CHANNELS
        self.upper_arm_dev = 0.0
        self.trunk_dev = 0.0
        self.sig_flags = (p.SIG_MVC_UNRELIABLE if self.profile.mvc_unreliable else 0)
        self.battery_pct = float(self.profile.battery_start_pct)
        self.clip_count = [0] * p.EMG_N_CHANNELS
        self._emg_pending: list[tuple[float, ...]] = []

        self._plan_i = 0
        self._plan: RepPlan | None = None
        self._traj: list[tuple[float, float, float]] = []
        self._traj_i = 0

        self._emg_seq = 0
        self._imu_seq = 0
        self._feat_seq = 0
        self._imu_pending: list = []
        #: EMG frames kept for backfill, keyed by sequence. Tier 2 in the
        #: firmware; a dict here.
        self._store: dict[int, bytes] = {}
        self._acked_seq = 0
        self.gap_occurred = False

        self._bp = [_Biquad(p.EMG_SAMPLE_RATE_HZ, self.profile.mdf_baseline)
                    for _ in range(p.EMG_CHANNELS)]
        self._mdf_history: list[tuple[int, float]] = []
        self._fatigue_streak = 0
        self.fatigue_flagged = False

        #: Everything the actuator was asked to do, for the bench checks.
        self.haptic_log: list[tuple[int, int]] = []
        self.results: list[RepResult] = []
        self._calib_task: asyncio.Task | None = None

    # ── plumbing ──────────────────────────────────────────────────────

    def attach(self, client: LoopbackClient) -> None:
        self.client = client

    def _notify(self, uuid: str, data: bytes) -> None:
        if self.client is not None:
            self.client.notify(uuid, data)

    def _event(self, event: int, payload: bytes = b"") -> None:
        self._notify(p.UUID_EVENTS, p.build_event(self.t_us, event, payload))

    def _haptic(self, pattern: int) -> None:
        """The haptic branch does not depend on BLE: a dropped link must not
        change anything about the exercise."""
        self.haptic_log.append((self.t_us, int(pattern)))

    def status_bytes(self) -> bytes:
        flags = p.STATUS_FLAG_PSRAM_BACKED
        if self.gap_occurred:
            flags |= p.STATUS_FLAG_GAP_OCCURRED
        return p.build_status(
            fw_state=int(self.fw_state), fault_code=int(self.fault),
            battery_pct=int(self.battery_pct),
            battery_mv=int(3300 + 9 * self.battery_pct),
            signal_quality=(self.sig_flags & 1, (self.sig_flags >> 1) & 1),
            seq_oldest=self._acked_seq,
            seq_newest=self._emg_seq, clip_count=tuple(self.clip_count),
            flags=flags, rep_count=self.rep_count,
            host_time_offset_us=self.host_time_offset_us)

    # ── commands ──────────────────────────────────────────────────────

    def on_command(self, op: int, payload: bytes) -> None:
        if op == p.Cmd.START_SESSION:
            self.begin_set()
        elif op == p.Cmd.STOP_SESSION:
            self.end_set()
        elif op == p.Cmd.START_CALIBRATION:
            phase = payload[0] if payload else 0
            self._calib_task = asyncio.ensure_future(self._run_calibration(phase))
        elif op == p.Cmd.ABORT_CALIBRATION:
            if self._calib_task and not self._calib_task.done():
                self._calib_task.cancel()
            self._set_state(p.FwState.STANDBY)
        elif op == p.Cmd.REQUEST_RECALIBRATION:
            self._calib_task = asyncio.ensure_future(
                self._run_calibration(int(p.CalibPhase.ALL)))
        elif op == p.Cmd.ACK_SEQ:
            if len(payload) >= 4:
                seq = struct.unpack("<I", payload[:4])[0]
                self._acked_seq = max(self._acked_seq, seq)
                # Release tier-2 storage below the mark, as the firmware does.
                for s in [k for k in self._store if k < self._acked_seq]:
                    del self._store[s]
        elif op == p.Cmd.REQUEST_BACKFILL:
            if len(payload) >= 8:
                start, end = struct.unpack("<II", payload[:8])
                self._backfill(start, end)
        elif op == p.Cmd.HAPTIC_TEST:
            if payload:
                self._haptic(payload[0])
        elif op == p.Cmd.SET_TIME:
            if len(payload) >= 8:
                host_us = struct.unpack("<Q", payload[:8])[0]
                # Recorded and reported; the sampling clock is never retimed,
                # because that would corrupt the spectral estimate.
                self.host_time_offset_us = self.t_us - host_us
        elif op == p.Cmd.SET_CONFIG:
            self._apply_config(payload)
        elif op == p.Cmd.GET_CONFIG:
            self._notify(p.UUID_CONFIG, self.config_bytes())
        elif op == p.Cmd.POWER_OFF:
            self.end_set()
            self._set_state(p.FwState.OFF)
            self.running = False

    # ── runtime configuration [PRD §5.9.1] ────────────────────────────

    def config_bytes(self) -> bytes:
        """config_serialise(). What GET_CONFIG returns, and how the host
        confirms a SET_CONFIG took effect."""
        w = self.weights
        return (p.cfg_u16(p.CfgTag.HOLD_MS, self.cfg_hold_ms) +
                p.cfg_f32(p.CfgTag.HOLD_VEL, self.cfg_hold_velocity) +
                p.cfg_u8(p.CfgTag.REP_TARGET, self.cfg_rep_target) +
                p.cfg_u8(p.CfgTag.SET_COUNT, self.cfg_set_count) +
                p.cfg_u16(p.CfgTag.REST_SECONDS, self.cfg_rest_seconds) +
                p.cfg_f32(p.CfgTag.TARGET_ANGLE, self.cfg_target_angle) +
                p.cfg_f32(p.CfgTag.START_ANGLE, self.cfg_start_angle) +
                p.cfg_f32(p.CfgTag.FINISH_ANGLE, self.cfg_finish_angle) +
                p.cfg_f32(p.CfgTag.TEMPO, w.tempo_min_s, w.tempo_max_s) +
                p.cfg_f32(p.CfgTag.COMP_THRESH, COMP_SHOULDER_HIKE_DEG,
                          COMP_TRUNK_LEAN_DEG, COMP_ARM_SWING_DPS) +
                p.cfg_f32(p.CfgTag.WEIGHTS, w.w_range, w.w_tempo,
                          w.w_smoothness, w.w_cocontraction, w.w_hold_steady) +
                p.cfg_f32(p.CfgTag.DEDUCTIONS, w.p_shoulder, w.p_trunk,
                          w.p_swing) +
                p.cfg_u8(p.CfgTag.RAW_STREAM, self.cfg_raw_stream) +
                p.cfg_u8(p.CfgTag.CHANNEL_ROLES, 0) + bytes([0]))

    def _apply_config(self, payload: bytes) -> None:
        """config_apply_tlv(). Values are clamped to the ranges the device can
        honour: a configuration that cannot produce a countable repetition is
        worse than a rejected write, because it shows up as a device that has
        stopped counting rather than as an error."""
        try:
            tags = p.parse_config_tlv(payload)
        except p.ProtocolError:
            return

        def f32(tag, n=1):
            raw = tags.get(tag)
            if raw is None or len(raw) != 4 * n:
                return None
            return struct.unpack("<" + "f" * n, raw)

        if (v := tags.get(p.CfgTag.HOLD_MS)) and len(v) == 2:
            self.cfg_hold_ms = min(3000, max(300, struct.unpack("<H", v)[0]))
        if (v := f32(p.CfgTag.HOLD_VEL)):
            self.cfg_hold_velocity = min(90.0, max(1.0, v[0]))
        if (v := tags.get(p.CfgTag.REP_TARGET)) and len(v) == 1:
            self.cfg_rep_target = min(50, max(1, v[0]))
        if (v := tags.get(p.CfgTag.SET_COUNT)) and len(v) == 1:
            self.cfg_set_count = min(20, max(1, v[0]))
        if (v := tags.get(p.CfgTag.REST_SECONDS)) and len(v) == 2:
            self.cfg_rest_seconds = min(600, struct.unpack("<H", v)[0])
        if (v := f32(p.CfgTag.TARGET_ANGLE)):
            self.cfg_target_angle = min(160.0, max(20.0, v[0]))
        if (v := f32(p.CfgTag.START_ANGLE)):
            self.cfg_start_angle = min(90.0, max(0.0, v[0]))
        if (v := f32(p.CfgTag.FINISH_ANGLE)):
            self.cfg_finish_angle = min(90.0, max(0.0, v[0]))
        if (v := tags.get(p.CfgTag.RAW_STREAM)) and len(v) == 1:
            self.cfg_raw_stream = 1 if v[0] else 0

        w = replace(self.weights)
        if (v := f32(p.CfgTag.TEMPO, 2)):
            w = replace(w, tempo_min_s=v[0], tempo_max_s=max(v[0] + 0.5, v[1]))
        if (v := f32(p.CfgTag.WEIGHTS, 5)):
            w = replace(w, w_range=v[0], w_tempo=v[1], w_smoothness=v[2],
                        w_cocontraction=v[3], w_hold_steady=v[4])
        if (v := f32(p.CfgTag.DEDUCTIONS, 3)):
            w = replace(w, p_shoulder=v[0], p_trunk=v[1], p_swing=v[2])
        self.weights = w

        # The finish threshold must sit below the start threshold, or the
        # cycle has no hysteresis and chatters between READY and CONCENTRIC.
        if self.cfg_finish_angle >= self.cfg_start_angle:
            self.cfg_finish_angle = max(0.0, self.cfg_start_angle - 5.0)

        # Read back, exactly as the device does.
        self._notify(p.UUID_CONFIG, self.config_bytes())

    def on_calib_write(self, data: bytes) -> None:
        """A clinician-supplied record supersedes the measured one."""
        try:
            self.calib = p.parse_calib(data)
        except p.ProtocolError:
            return

    def _backfill(self, start: int, end: int) -> None:
        sent = 0
        for seq in sorted(k for k in self._store if start <= k <= end):
            # Served on its own characteristic so catching up never stalls the
            # live stream.
            self._notify(p.UUID_BACKFILL, self._store[seq])
            sent += 1
        if sent < (end - start) // p.BLE_EMG_BATCH:
            self.gap_occurred = True

    def _set_state(self, state) -> None:
        if self.fw_state != state:
            self.fw_state = state
            self._event(p.Event.STATE_CHANGE, bytes([int(state)]))
            self._notify(p.UUID_STATUS, self.status_bytes())

    # ── calibration ───────────────────────────────────────────────────

    #: Capture time per step [PRD §5.3]. The triceps maximum only exists when
    #: a second channel does.
    _STEP_MS = {
        p.CalibPhase.CONTACT: 4000,
        p.CalibPhase.REST: CALIB_REST_MS,
        p.CalibPhase.STRAIGHT: CALIB_STRAIGHT_MS,
        p.CalibPhase.BICEPS: CALIB_MVC_MS * CALIB_MVC_ATTEMPTS,
        p.CalibPhase.TRICEPS: CALIB_MVC_MS * CALIB_MVC_ATTEMPTS,
        p.CalibPhase.SWEEP: CALIB_SWEEP_MS,
    }

    async def _run_calibration(self, step: int) -> None:
        """One step, or the whole protocol.

        Steps are individually commanded so a failed one can be repeated on
        its own: the step most likely to fail is a maximum contraction on a
        paretic limb, which is also the one a patient least wants to repeat
        four others to get back to."""
        self._set_state(p.FwState.CALIBRATION)

        if step == int(p.CalibPhase.ALL):
            order = [p.CalibPhase.REST, p.CalibPhase.STRAIGHT,
                     p.CalibPhase.BICEPS]
            if p.EMG_N_CHANNELS > 1:
                order.append(p.CalibPhase.TRICEPS)
            order.append(p.CalibPhase.SWEEP)
            steps = [(ph, self._STEP_MS[ph]) for ph in order]
        elif step in self._STEP_MS:
            steps = [(p.CalibPhase(step), self._STEP_MS[p.CalibPhase(step)])]
        else:
            self._set_state(p.FwState.STANDBY)
            return
        try:
            for ph, ms in steps:
                for pct in (0, 25, 50, 75, 100):
                    self._event(p.Event.CALIB_PHASE_DONE
                                if pct == 100 else p.Event.STATE_CHANGE,
                                bytes([int(ph), pct]))
                    await asyncio.sleep(ms / 5000.0 / max(0.01, self.profile.speed))
        except asyncio.CancelledError:
            self._set_state(p.FwState.STANDBY)
            raise
        self.calib.timestamp = int(time.time())
        self._set_state(p.FwState.STANDBY)

    # ── set control ───────────────────────────────────────────────────

    def begin_set(self) -> None:
        self.rep_count = 0
        self.rep_state = p.RepState.READY
        self._plan_i = 0
        self._plan = None
        self._fatigue_streak = 0
        self.fatigue_flagged = False
        self._mdf_history.clear()
        self._set_state(p.FwState.OPERATIONAL)

    def end_set(self) -> None:
        if self.fw_state == p.FwState.OPERATIONAL:
            self._event(p.Event.SET_COMPLETE,
                        struct.pack("<H", self.rep_count))
            self._set_state(p.FwState.STANDBY)

    # ── movement generation ───────────────────────────────────────────

    def _next_plan(self) -> RepPlan:
        if self._plan_i < len(self.profile.plans):
            plan = self.profile.plans[self._plan_i]
        else:
            plan = RepPlan(peak_deg=self.rng.uniform(88.0, 97.0),
                           rise_s=self.rng.uniform(1.4, 1.9),
                           fall_s=self.rng.uniform(1.5, 2.0))
        self._plan_i += 1
        return plan

    def _build_trajectory(self, plan: RepPlan):
        """Angle, upper-arm deviation and trunk deviation, one entry per tick.
        The repetition cycle then observes this the way it would observe a real
        arm — it is not told what the plan was."""
        dt = TICK_MS / 1000.0
        bottom = self.profile.angle_min + 2.0
        peak = plan.peak_deg
        out: list[tuple[float, float, float]] = []

        # Tremor has to be a slow wobble, not per-tick white noise. White noise
        # of a few tenths of a degree between 20 ms ticks is tens of deg/s of
        # apparent velocity, which trips REP_HOLD_MAX_VEL_DPS and stops any
        # hold ever being satisfied — the arm looks like it is vibrating, not
        # resting. A 1.5 Hz wobble of the same amplitude is ~9 deg/s per degree,
        # which is what an unsteady limb actually looks like to the gate.
        tick = [0]

        def tremor() -> float:
            tick[0] += 1
            return plan.tremor_deg * math.sin(2 * math.pi * 1.5 * tick[0] * dt)

        # Bottom hold — this is what arms the repetition.
        for _ in range(max(2, int(plan.bottom_hold_s / dt))):
            out.append((bottom + tremor(), 0.0, 0.0))

        if plan.abandon:
            # Rises part way, then stalls past the phase timeout.
            n = max(2, int(plan.rise_s / dt))
            for i in range(n):
                f = _min_jerk(i / n)
                out.append((bottom + (peak - bottom) * f,
                            plan.shoulder_deg * f, plan.trunk_deg * f))
            for _ in range(int((REP_PHASE_TIMEOUT_MS / 1000.0 + 1.5) / dt)):
                out.append((peak + tremor(), plan.shoulder_deg, plan.trunk_deg))
            for i in range(max(2, int(plan.fall_s / dt))):
                f = _min_jerk(i / max(2, int(plan.fall_s / dt)))
                out.append((peak - (peak - bottom) * f, 0.0, 0.0))
            return out

        n = max(2, int(plan.rise_s / dt))
        for i in range(n):
            f = _min_jerk(i / n)
            a = bottom + (peak - bottom) * f
            if plan.jerkiness:
                a += 3.0 * plan.jerkiness * math.sin(2 * math.pi * 2.1 * i * dt)
            out.append((a, plan.shoulder_deg * f, plan.trunk_deg * f))

        for _ in range(max(2, int(plan.top_hold_s / dt))):
            out.append((peak + tremor(), plan.shoulder_deg, plan.trunk_deg))

        n = max(2, int(plan.fall_s / dt))
        for i in range(n):
            f = _min_jerk(i / n)
            a = peak - (peak - bottom) * f
            if plan.jerkiness:
                a += 2.0 * plan.jerkiness * math.sin(2 * math.pi * 1.8 * i * dt)
            out.append((a, plan.shoulder_deg * (1 - f), plan.trunk_deg * (1 - f)))
        return out

    def _fatigue(self) -> float:
        if self.total_reps < self.profile.fatigue_onset_rep:
            return 0.0
        return min(1.0, (self.total_reps - self.profile.fatigue_onset_rep) / 8.0)

    def _tick_signals(self) -> None:
        prev = self.angle
        plan = self._plan
        bottom = self.profile.angle_min + 2.0

        if self.fw_state != p.FwState.OPERATIONAL:
            self.angle += (bottom - self.angle) * 0.2
            self.envelope = [self.profile.rest_envelope + abs(self.rng.gauss(0, 0.004))
                             for _ in range(p.EMG_CHANNELS)]
            self.mdf = [0.0, 0.0]
            self.upper_arm_dev = self.trunk_dev = 0.0
            self.velocity = 0.0
            return

        if plan is None:
            plan = self._plan = self._next_plan()
            self._traj = self._build_trajectory(plan)
            self._traj_i = 0

        angle, shoulder, trunk = self._traj[self._traj_i]
        self._traj_i += 1
        if self._traj_i >= len(self._traj):
            self._plan = None

        self.angle = angle
        self.upper_arm_dev = shoulder + (START_POS_UPPER_ARM_TOL_DEG + 6.0
                                         if plan.bad_start else 0.0)
        self.trunk_dev = trunk
        self.velocity = (angle - prev) / (TICK_MS / 1000.0)

        fatigue = self._fatigue()
        drive = max(0.0, (angle - bottom) / max(1.0, plan.peak_deg - bottom))
        eccentric = self.velocity < -2.0
        agonist = plan.activation * (0.35 + 0.75 * drive)
        agonist *= (0.6 if eccentric else 1.0) * (1.0 + 0.25 * fatigue)
        agonist = max(self.profile.rest_envelope, agonist + self.rng.gauss(0, 0.012))
        antagonist = max(self.profile.rest_envelope,
                         plan.cocontraction * agonist * (1.0 + 0.3 * fatigue)
                         + self.rng.gauss(0, 0.008))
        self.envelope = [min(1.5, agonist), min(1.5, antagonist)]

        # MDF is meaningless below the activation floor, and the firmware
        # reports zero there rather than a number nobody should trust.
        mdf = (self.profile.mdf_baseline
               - self.profile.mdf_fall_per_rep
               * max(0, self.total_reps - self.profile.fatigue_onset_rep)
               + self.rng.gauss(0, 0.3))
        self.mdf = [mdf if e >= MDF_MIN_ACTIVATION else 0.0 for e in self.envelope]

    # ── repetition cycle (rep_cycle.h) ────────────────────────────────

    def _bands(self) -> tuple[float, float]:
        """The extended and peak thresholds, as angles against the therapist's
        target rather than fractions of measured ROM [PRD §5.4]."""
        return (self.calib.angle_min + self.cfg_finish_angle,
                self.calib.angle_min + self.cfg_target_angle * REP_PEAK_FRAC)

    def _detect_compensation(self) -> int:
        """Evaluated during the moving phases only, and latched for the
        repetition: feedback arrives at the confirming hold, not
        mid-movement."""
        flags = 0
        confirm_ticks = max(1, COMP_CONFIRM_MS // TICK_MS)

        for flag, over in ((p.COMP_SHOULDER,
                            self.upper_arm_dev > COMP_SHOULDER_HIKE_DEG),
                           (p.COMP_TRUNK, self.trunk_dev > COMP_TRUNK_LEAN_DEG)):
            self._comp_confirm[flag] = self._comp_confirm[flag] + 1 if over else 0
            if self._comp_confirm[flag] >= confirm_ticks:
                flags |= flag

        plan = self._plan
        swinging = bool(plan and plan.swing) and abs(self.velocity) > COMP_ARM_SWING_DPS
        self._swing_ms = self._swing_ms + TICK_MS if swinging else 0
        if self._swing_ms >= COMP_ARM_SWING_SUSTAIN_MS:
            flags |= p.COMP_SWING
        return flags

    def _tick_rep_cycle(self) -> None:
        if self.fw_state != p.FwState.OPERATIONAL:
            return

        ext_top, flex_bottom = self._bands()
        in_extended = self.angle <= ext_top
        in_flexed = self.angle >= flex_bottom
        still = abs(self.velocity) <= REP_HOLD_MAX_VEL_DPS
        self._phase_ms += TICK_MS

        # Thresholds are angles against the therapist's target, not fractions
        # of measured ROM [PRD §5.4].
        start_th = self.calib.angle_min + self.cfg_start_angle
        finish_th = self.calib.angle_min + self.cfg_finish_angle
        peak_th = self.calib.angle_min + self.cfg_target_angle * REP_PEAK_FRAC

        # The activation gate. Posture alone is satisfied by an arm somebody
        # else is moving, which is the case this device exists to catch.
        act = self._activation.update(self.envelope[0])

        if self.rep_state == p.RepState.READY:
            if self.angle <= start_th:
                if self._start_pos_ok is not True:
                    self._start_pos_ok = True
                    self._start_pos_bad = False
                    self._event(p.Event.START_POS_OK,
                                bytes([int(min(255, self.upper_arm_dev))]))
            elif self.angle > start_th:
                if not act:
                    # Rising with the agonist quiet: a passive swing. Reported,
                    # never counted, and it does not arm anything.
                    if self._phase_ms - self._passive_last_ms > 2500:
                        self._passive_last_ms = self._phase_ms
                        self._event(p.Event.PASSIVE_SWING)
                elif self.upper_arm_dev > START_POS_UPPER_ARM_TOL_DEG:
                    if not self._start_pos_bad:
                        self._start_pos_bad = True
                        self._start_pos_ok = False
                        self._event(p.Event.START_POS_BAD,
                                    bytes([int(min(255, self.upper_arm_dev))]))
                else:
                    self._start_pos_bad = False
                    self.rep_state = p.RepState.CONCENTRIC
                    self._phase_ms = 0
                    self._acc = Accumulator(self.calib.angle_min,
                                            self.cfg_target_angle)
                    self._acc.inp.t_start_us = self.t_us
                    self._rep_start_us = self.t_us
                    self._comp_latched = 0
                    self._swing_ms = 0
                    self._event(p.Event.REP_START)

        elif self.rep_state == p.RepState.CONCENTRIC:
            self._acc.movement(self.angle, self.velocity, self.envelope[0],
                               self.envelope[-1], agonist_active=act)
            self._comp_latched |= self._detect_compensation()
            if self.angle >= peak_th:
                self.rep_state = p.RepState.PEAK
                self._phase_ms = 0
                # Soft click at 80 % of target: "you may begin the return."
                self._haptic(p.HapticPattern.SOFT_CLICK)
            elif self.angle < finish_th or self._phase_ms >= REP_PHASE_TIMEOUT_MS:
                self._abandon()

        elif self.rep_state == p.RepState.PEAK:
            self._acc.movement(self.angle, self.velocity, self.envelope[0],
                               self.envelope[-1], agonist_active=act)
            self._comp_latched |= self._detect_compensation()
            if self.velocity < 0.0:
                self.rep_state = p.RepState.ECCENTRIC
                self._phase_ms = 0
            elif self._phase_ms >= REP_PHASE_TIMEOUT_MS:
                self._abandon()

        elif self.rep_state == p.RepState.ECCENTRIC:
            self._acc.movement(self.angle, self.velocity, self.envelope[0],
                               self.envelope[-1], agonist_active=act)
            self._comp_latched |= self._detect_compensation()
            if self.angle <= finish_th:
                # Tempo runs start threshold to finish threshold and excludes
                # the confirming hold.
                self._acc.tempo((self.t_us - self._rep_start_us) / 1e6)
                self.rep_state = p.RepState.EXTENDED_HOLD
                self._hold_ms = 0
                self._phase_ms = 0
                self._event(p.Event.HOLD_START, bytes([int(self.rep_state)]))
            elif self._phase_ms >= REP_PHASE_TIMEOUT_MS:
                self._abandon()

        elif self.rep_state == p.RepState.EXTENDED_HOLD:
            if self.angle > start_th:
                # Started the next curl before the hold completed.
                self._abandon()
            elif abs(self.velocity) <= self.cfg_hold_velocity:
                self._hold_ms += TICK_MS
                if self._acc is not None:
                    self._acc.hold(self.angle)
                if self._hold_ms >= self.cfg_hold_ms:
                    self._complete_rep()
            else:
                # Inside the band but still moving: the hold has not begun.
                self._hold_ms = 0
                if self._phase_ms >= REP_PHASE_TIMEOUT_MS:
                    self._abandon()

    def _abandon(self) -> None:
        self._event(p.Event.REP_ABANDONED,
                    struct.pack("<Hh", self.rep_count + 1,
                                int(self.angle * 10)))
        self.rep_state = p.RepState.READY
        self._acc = None
        self._hold_ms = 0
        self._phase_ms = 0

    def _complete_rep(self) -> None:
        """Counted at the end of the confirming hold at the EXTENDED position
        [PRD §5.4] — a moment the patient is already stationary and expecting
        it, which is what lets the haptic be scheduled rather than reactive."""
        self.rep_count += 1
        self.total_reps += 1
        self._acc.compensation(self._comp_latched)
        self._acc.inp.t_end_us = self.t_us
        result = self._acc.result(self.rep_count, self.weights)
        self.results.append(result)

        self._event(p.Event.REP_COMPLETE, result.to_event_payload())
        for flag, evt in ((p.COMP_SHOULDER, p.Event.COMPENSATION_SHOULDER),
                          (p.COMP_TRUNK, p.Event.COMPENSATION_TRUNK),
                          (p.COMP_SWING, p.Event.COMPENSATION_SWING)):
            if result.comp_flags & flag:
                self._event(evt, struct.pack("<H", self.rep_count))
        self._event(p.Event.HOLD_COMPLETE,
                    bytes([int(p.RepState.EXTENDED_HOLD)]))

        # Reaching rep_target ends the set [PRD §5.6]. The compound cue plays
        # the per-repetition result, a 300 ms gap, then set-complete — one
        # request, because a single-slot scheduler would drop a second one.
        set_done = (self.cfg_rep_target > 0
                    and self.rep_count >= self.cfg_rep_target
                    and not self._set_complete_fired)

        if set_done:
            self._set_complete_fired = True
            self._haptic(p.HapticPattern.REP_FLAGGED_THEN_SET
                         if result.comp_flags
                         else p.HapticPattern.REP_CLEAN_THEN_SET)
        else:
            self._haptic(haptic_for(result))

        self._check_fatigue()

        if set_done:
            self._event(p.Event.SET_COMPLETE,
                        struct.pack("<H", self.rep_count))
            self.end_set()
            return

        self.rep_state = p.RepState.READY
        self._phase_ms = 0
        self._hold_ms = 0

    def _check_fatigue(self) -> None:
        """Median frequency tracked as a regression across the set.

        Fatigue ADVISES; it does not end the set. The rest cue fires and the
        event is reported, and what to do about it is the patient's and the
        therapist's decision, not the device's."""
        mdf = max(self.mdf)
        if mdf <= 0.0:
            return
        self._mdf_history.append((self.total_reps, mdf))
        hist = self._mdf_history[-5:]
        if len(hist) < 3:
            return
        n = len(hist)
        mx = sum(x for x, _ in hist) / n
        my = sum(y for _, y in hist) / n
        den = sum((x - mx) ** 2 for x, _ in hist)
        if not den:
            return
        slope = sum((x - mx) * (y - my) for x, y in hist) / den
        self._fatigue_streak = (self._fatigue_streak + 1
                                if slope < FATIGUE_MDF_SLOPE_THRESH else 0)
        if self._fatigue_streak == FATIGUE_CONSEC_REPS:
            self.fatigue_flagged = True
            self._event(p.Event.FATIGUE_WARN,
                        struct.pack("<hH", int(slope * 100), self.rep_count))
            self._haptic(p.HapticPattern.REST)

    # ── raw synthesis and transmit ────────────────────────────────────

    def _emit_raw(self) -> None:
        centre = max(self.mdf) or self.profile.mdf_baseline
        samples = []
        for c in range(p.EMG_CHANNELS):
            self._bp[c].retune(centre * (1.0 + 0.02 * c))
        for i in range(EMG_PER_TICK):
            t = self.t_us / 1e6 + i / p.EMG_SAMPLE_RATE_HZ
            hum = 15 * math.sin(2 * math.pi * 60 * t)   # battery operation limits it
            vals = []
            for c in range(p.EMG_CHANNELS):
                v = self._bp[c].step(self.rng.gauss(0, 1)) * self.envelope[c] * 2600 + hum
                if v > 32767 or v < -32768:
                    self.clip_count[c] += 1
                vals.append(v)
            samples.append(tuple(vals))

        # A tick produces EMG_PER_TICK samples; a frame carries
        # BLE_EMG_BATCH of them, and the two need not be equal — on one
        # channel a frame holds two ticks' worth, because each sample is half
        # the size and the 180 B budget is the thing being filled. The
        # firmware does the same: the ADC lands fixed-size DMA buffers and
        # ble_tx packs frames from them.
        self._emg_pending.extend(samples)
        while len(self._emg_pending) >= p.BLE_EMG_BATCH:
            batch = self._emg_pending[:p.BLE_EMG_BATCH]
            del self._emg_pending[:p.BLE_EMG_BATCH]
            frame = p.build_emg(self._emg_seq, self.t_us, batch)
            self._store[self._emg_seq] = frame
            self._notify(p.UUID_RAW, frame)
            self._emg_seq += p.BLE_EMG_BATCH

        for _ in range(IMU_PER_TICK):
            ang = math.radians(self.angle)
            upper = ((0.0, math.cos(math.radians(self.trunk_dev)),
                      math.sin(math.radians(self.trunk_dev))),
                     (0.0, 0.0, self.upper_arm_dev * 0.5))
            fore = ((math.sin(ang), math.cos(ang), 0.0),
                    (0.0, 0.0, self.velocity))
            self._imu_pending.append((upper, fore))
        while len(self._imu_pending) >= p.BLE_IMU_BATCH:
            batch = self._imu_pending[:p.BLE_IMU_BATCH]
            del self._imu_pending[:p.BLE_IMU_BATCH]
            self._notify(p.UUID_RAW, p.build_imu(self._imu_seq, self.t_us, batch))
            self._imu_seq += p.BLE_IMU_BATCH

    def _emit_features(self) -> None:
        self._notify(p.UUID_EVENTS, p.build_features(
            self._feat_seq, self.t_us, self.envelope, self.mdf,
            self.angle, self.upper_arm_dev, int(self.rep_state),
            self.rep_count, self._comp_latched, self.sig_flags))
        self._feat_seq += 1

    # ── main loop ─────────────────────────────────────────────────────

    async def run(self, duration_s: float | None = None) -> None:
        self.running = True
        wall0 = time.monotonic()
        end_us = None if duration_s is None else int(duration_s * 1e6)
        self._notify(p.UUID_STATUS, self.status_bytes())
        while self.running:
            self.t_us += TICK_MS * 1000
            self.battery_pct = max(0.0, self.battery_pct - 0.0002)

            self._tick_signals()
            self._tick_rep_cycle()
            self._emit_features()
            self._emit_raw()

            if (self.t_us // 1000) % 1000 < TICK_MS:
                self._notify(p.UUID_STATUS, self.status_bytes())

            if end_us is not None and self.t_us >= end_us:
                break
            target = wall0 + (self.t_us / 1e6) / max(0.01, self.profile.speed)
            delay = target - time.monotonic()
            await asyncio.sleep(delay if delay > 0.0005 else 0)
        self.running = False

    def stop(self) -> None:
        self.running = False
