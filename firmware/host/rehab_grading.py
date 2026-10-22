"""
rehab_grading.py — Python mirror of main/rep/grading.c.

The device is authoritative for scores; the host displays what it is sent and
never re-derives it. This module exists for two other reasons:

  * the simulator needs to produce believable scores, and producing them any
    other way would make the simulator a worse rehearsal than it should be;
  * it is a cross-check on grading.c. Same inputs, same score, in C and in
    Python — test_grading.py pins the cases that matter, so a change to one
    side that forgets the other shows up as a failing test rather than as a
    plausible-looking number in a volunteer session.

If the two ever disagree, grading.c wins and this file is the bug.

Mirrors the version where hold steadiness replaced the tempo term: the
hold-based protocol fixes tempo by construction, and steadiness under an
isometric hold is a direct motor-control measure.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

import rehab_protocol as p

# ── rehab_config.h ─────────────────────────────────────────────────────
GRADE_W_RANGE = 0.40
GRADE_W_ACTIVATION = 0.25
GRADE_W_SMOOTHNESS = 0.20
GRADE_W_HOLD_STEADY = 0.15

PENALTY_SHOULDER_HIKE = 20.0
PENALTY_TRUNK_LEAN = 15.0
PENALTY_ARM_SWING = 15.0
PENALTY_COCONTRACTION = 15.0
COCONTRACTION_THRESHOLD = 0.35

#: A home rehab repetition is not meant to be a maximal effort, so activation
#: saturates here rather than at 100 % MVC — scaling to 100 would make every
#: honest repetition look weak.
ACTIVATION_SATURATION = 0.60

#: "Velocity changing by half the mean speed every sample scores zero."
JERK_REFERENCE = 0.5

#: Below this the limb barely moved and smoothness is not meaningful.
MIN_MEAN_SPEED_DPS = 1.0

#: 5 degrees of wobble over a 1-second hold scores zero.
STEADINESS_SD_REFERENCE = 5.0


@dataclass
class Weights:
    w_range: float = GRADE_W_RANGE
    w_activation: float = GRADE_W_ACTIVATION
    w_smoothness: float = GRADE_W_SMOOTHNESS
    w_hold_steady: float = GRADE_W_HOLD_STEADY
    p_shoulder: float = PENALTY_SHOULDER_HIKE
    p_trunk: float = PENALTY_TRUNK_LEAN
    p_swing: float = PENALTY_ARM_SWING
    p_cocontraction: float = PENALTY_COCONTRACTION
    cocontraction_threshold: float = COCONTRACTION_THRESHOLD


DEFAULT_WEIGHTS = Weights()


@dataclass
class GradingInput:
    """grading_input_t. Accumulated over one repetition at FEATURE_RATE_HZ."""

    peak_angle: float = 0.0
    angle_min: float = 0.0
    angle_max: float = 0.0
    activation_sum: float = 0.0      # summed agonist %MVC
    antagonist_sum: float = 0.0
    activation_n: int = 0
    jerk_sum: float = 0.0            # summed |d(velocity)|
    speed_sum: float = 0.0           # summed |velocity|
    jerk_n: int = 0
    hold_sum: float = 0.0            # angle during the holds
    hold_sum_sq: float = 0.0
    hold_n: int = 0
    comp_flags: int = 0

    # Not part of grading_input_t; carried so the simulator can report them.
    t_start_us: int = 0
    t_end_us: int = 0


@dataclass
class RepResult:
    """rep_result_t."""

    index: int = 0
    t_start_us: int = 0
    t_end_us: int = 0
    peak_angle_deg: float = 0.0
    rom_fraction: float = 0.0
    activation: float = 0.0
    cocontraction: float = 0.0
    smoothness: float = 0.0
    hold_steadiness: float = 0.0
    comp_flags: int = 0
    score: int = 0

    @property
    def duration_ms(self) -> int:
        return max(0, (self.t_end_us - self.t_start_us) // 1000)

    def to_event_payload(self) -> bytes:
        """The proposed 16-byte EVT_REP_COMPLETE payload (see
        rehab_protocol.RepComplete — not yet implemented in firmware)."""
        return p.RepComplete(
            index=self.index, score=self.score, rom_fraction=self.rom_fraction,
            cocontraction=self.cocontraction, smoothness=self.smoothness,
            hold_steadiness=self.hold_steadiness,
            peak_angle_deg=self.peak_angle_deg, comp_flags=self.comp_flags,
            duration_ms=self.duration_ms).pack()


def _clamp01(v: float) -> float:
    return 0.0 if v < 0.0 else (1.0 if v > 1.0 else v)


def evaluate(inp: GradingInput, w: Weights = DEFAULT_WEIGHTS) -> RepResult:
    """grading_evaluate()."""
    out = RepResult(t_start_us=inp.t_start_us, t_end_us=inp.t_end_us,
                    comp_flags=inp.comp_flags)

    rom = inp.angle_max - inp.angle_min

    # Range achieved, as a fraction of this patient's calibrated ROM — never
    # an absolute angle.
    rng = 0.0
    if rom > 1.0:
        rng = _clamp01((inp.peak_angle - inp.angle_min) / rom)
    out.peak_angle_deg = inp.peak_angle
    out.rom_fraction = rng

    # Target-muscle activation. A full-range curl driven by momentum rather
    # than muscle scores badly here even though its range looks perfect, which
    # is the whole point of fusing EMG with motion.
    activation = inp.activation_sum / inp.activation_n if inp.activation_n else 0.0
    out.activation = activation
    activation_score = _clamp01(activation / ACTIVATION_SATURATION)

    # Co-contraction: antagonist fighting the movement.
    cocon = 0.0
    if inp.activation_sum > 1e-6:
        cocon = inp.antagonist_sum / inp.activation_sum
    out.cocontraction = cocon

    # Smoothness as dimensionless jerk. Normalising by the movement's own mean
    # speed is the point: raw mean |d(velocity)| scales with how fast the limb
    # moves, so an unnormalised metric hands a better score to anyone who
    # simply moves slower — rewarding exactly the guarding behaviour this
    # device exists to discourage.
    smoothness = 0.0
    if inp.jerk_n > 0:
        mean_jerk = inp.jerk_sum / inp.jerk_n
        mean_speed = inp.speed_sum / inp.jerk_n
        if mean_speed > MIN_MEAN_SPEED_DPS:
            smoothness = _clamp01(1.0 - (mean_jerk / mean_speed) / JERK_REFERENCE)
    out.smoothness = smoothness

    # Hold steadiness: inverse standard deviation of the angle during the holds.
    steadiness = 0.0
    if inp.hold_n > 1:
        mean = inp.hold_sum / inp.hold_n
        var = inp.hold_sum_sq / inp.hold_n - mean * mean
        if var < 0.0:
            var = 0.0
        steadiness = _clamp01(1.0 - (math.sqrt(var) / STEADINESS_SD_REFERENCE))
    out.hold_steadiness = steadiness

    score = 100.0 * (w.w_range * rng +
                     w.w_activation * activation_score +
                     w.w_smoothness * smoothness +
                     w.w_hold_steady * steadiness)

    if inp.comp_flags & p.COMP_SHOULDER:
        score -= w.p_shoulder
    if inp.comp_flags & p.COMP_TRUNK:
        score -= w.p_trunk
    if inp.comp_flags & p.COMP_SWING:
        score -= w.p_swing

    if cocon > w.cocontraction_threshold:
        # Scaled: twice the threshold costs the full penalty.
        over = (cocon - w.cocontraction_threshold) / w.cocontraction_threshold
        score -= w.p_cocontraction * _clamp01(over)

    out.score = int(max(0.0, min(100.0, score)) + 0.5)
    return out


def haptic_for(result: RepResult) -> int:
    """Every completed repetition is counted and then graded; the patient hears
    only whether the form was clean. Nothing is silently discarded."""
    return (p.HapticPattern.REP_COMPENSATED if result.comp_flags
            else p.HapticPattern.REP_COMPLETE)


class Accumulator:
    """Builds a GradingInput tick by tick at FEATURE_RATE_HZ, the way
    rep_cycle.c does while a repetition is underway."""

    def __init__(self, angle_min: float, angle_max: float) -> None:
        self.inp = GradingInput(angle_min=angle_min, angle_max=angle_max)
        self._last_velocity: float | None = None

    def movement(self, angle: float, velocity: float, agonist: float,
                 antagonist: float) -> None:
        i = self.inp
        i.peak_angle = max(i.peak_angle, angle)
        i.activation_sum += agonist
        i.antagonist_sum += antagonist
        i.activation_n += 1
        if self._last_velocity is not None:
            i.jerk_sum += abs(velocity - self._last_velocity)
            i.speed_sum += abs(velocity)
            i.jerk_n += 1
        self._last_velocity = velocity

    def hold(self, angle: float) -> None:
        i = self.inp
        i.hold_sum += angle
        i.hold_sum_sq += angle * angle
        i.hold_n += 1

    def compensation(self, flags: int) -> None:
        """Latched during the repetition, reported at the top hold."""
        self.inp.comp_flags |= flags

    def result(self, index: int, w: Weights = DEFAULT_WEIGHTS) -> RepResult:
        out = evaluate(self.inp, w)
        out.index = index
        return out
