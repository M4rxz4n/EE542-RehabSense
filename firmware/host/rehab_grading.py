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

Mirrors PRD v1.4 §5.5: four components of equal weight — range, tempo,
smoothness, co-contraction — then deductions, clamped to 0..100. Hold
steadiness is computed and REPORTED but carries zero weight by default.

On the single-channel prototype there is no antagonist envelope, so
co-contraction is unmeasurable and its weight is zero; the score normalises by
the weights actually in force, so the three remaining components take a third
each rather than the best achievable score being capped at 75.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

import rehab_protocol as p

# ── rehab_config.h ─────────────────────────────────────────────────────

#: Phase 1 prototype: one MyoWare on the biceps. Phase 2's custom PCB adds the
#: triceps and with it the co-contraction component.
EMG_N_CHANNELS = 1

GRADE_W_RANGE = 0.25
GRADE_W_TEMPO = 0.25
GRADE_W_SMOOTHNESS = 0.25
GRADE_W_COCONTRACTION = 0.25 if EMG_N_CHANNELS > 1 else 0.0
GRADE_W_HOLD_STEADY = 0.0

PENALTY_SHOULDER_HIKE = 20.0
PENALTY_TRUNK_LEAN = 15.0
PENALTY_ARM_SWING = 15.0

#: Velocity peaks above this fraction of the repetition's own peak velocity
#: count as separate pushes.
SMOOTH_PEAK_FRAC = 0.10

#: Each push beyond the first costs this much of the smoothness component.
SMOOTH_PEAK_COST = 0.25

#: Co-contraction scores zero at or above this antagonist/agonist ratio.
COCON_ZERO_SCORE_RATIO = 0.50

#: Tempo window, start threshold to finish threshold, excluding the hold.
TEMPO_MIN_S = 1.5
TEMPO_MAX_S = 3.5

#: 5 degrees of wobble over a 1-second hold scores zero.
STEADINESS_SD_REFERENCE = 5.0


@dataclass
class Weights:
    """The scored part of rehab_runtime_cfg_t [PRD §5.9.1]."""

    w_range: float = GRADE_W_RANGE
    w_tempo: float = GRADE_W_TEMPO
    w_smoothness: float = GRADE_W_SMOOTHNESS
    w_cocontraction: float = GRADE_W_COCONTRACTION
    w_hold_steady: float = GRADE_W_HOLD_STEADY
    p_shoulder: float = PENALTY_SHOULDER_HIKE
    p_trunk: float = PENALTY_TRUNK_LEAN
    p_swing: float = PENALTY_ARM_SWING
    tempo_min_s: float = TEMPO_MIN_S
    tempo_max_s: float = TEMPO_MAX_S


DEFAULT_WEIGHTS = Weights()


@dataclass
class GradingInput:
    """grading_input_t. Accumulated over one repetition at FEATURE_RATE_HZ."""

    peak_angle: float = 0.0
    angle_min: float = 0.0           # calibrated extension, the angle origin
    target_angle: float = 110.0      # therapist-set [PRD §5.9.1]
    tempo_s: float = 0.0             # start threshold to finish threshold

    activation_sum: float = 0.0      # summed agonist %MVC
    antagonist_sum: float = 0.0
    overlap_sum: float = 0.0         # antagonist WHILE the agonist was active
    activation_n: int = 0
    overlap_n: int = 0

    velocity_peaks: int = 0          # above 10 % of this rep's peak speed

    hold_sum: float = 0.0            # angle during the confirming hold
    hold_sum_sq: float = 0.0
    hold_n: int = 0

    comp_flags: int = 0
    jolt_excluded: bool = False

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
    tempo_s: float = 0.0
    activation: float = 0.0
    cocontraction: float = 0.0
    smoothness: float = 0.0
    velocity_peaks: int = 0
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
                    comp_flags=inp.comp_flags, tempo_s=inp.tempo_s)

    # Range of motion: peak angle against the therapist's TARGET angle, not
    # against the patient's measured ROM. The therapist prescribes what the
    # patient should reach; measured ROM is what they currently can, and
    # scoring against the latter would hand full marks to a shrinking range.
    rng = 0.0
    if inp.target_angle > 1.0:
        rng = _clamp01((inp.peak_angle - inp.angle_min) / inp.target_angle)
    out.peak_angle_deg = inp.peak_angle
    out.rom_fraction = rng

    # Tempo: full credit inside the prescribed window, falling off linearly
    # over one window-width either side. Both directions matter — too fast is
    # momentum, too slow is usually guarding or a stall mid-range.
    tempo = 0.0
    if inp.tempo_s > 0.0 and w.tempo_max_s > w.tempo_min_s:
        if w.tempo_min_s <= inp.tempo_s <= w.tempo_max_s:
            tempo = 1.0
        else:
            width = w.tempo_max_s - w.tempo_min_s
            dist = (w.tempo_min_s - inp.tempo_s if inp.tempo_s < w.tempo_min_s
                    else inp.tempo_s - w.tempo_max_s)
            tempo = _clamp01(1.0 - dist / width)

    # Smoothness: count of velocity peaks above 10 % of the repetition's own
    # peak velocity; a single peak scores 100 [PRD §5.5]. Counting peaks is
    # scale-free, which is what keeps it from rewarding slow movement — the
    # failure mode an unnormalised jerk metric has, and one that would reward
    # exactly the guarding behaviour this device exists to discourage.
    smoothness = 0.0
    if inp.velocity_peaks > 0:
        smoothness = _clamp01(1.0 - (inp.velocity_peaks - 1) * SMOOTH_PEAK_COST)
    out.smoothness = smoothness
    out.velocity_peaks = inp.velocity_peaks

    # Co-contraction: antagonist activation as a fraction of agonist, while
    # the agonist is active. Each channel is normalised against its OWN
    # calibrated maximum, which is why calibration captures a separate triceps
    # maximum when a second channel exists.
    cocon_ratio = 0.0
    cocon_score = 1.0
    if EMG_N_CHANNELS > 1:
        if inp.overlap_n and inp.activation_n and inp.activation_sum > 1e-6:
            mean_antag = inp.overlap_sum / inp.overlap_n
            mean_agon = inp.activation_sum / inp.activation_n
            if mean_agon > 1e-6:
                cocon_ratio = mean_antag / mean_agon
        if COCON_ZERO_SCORE_RATIO > 1e-6:
            cocon_score = _clamp01(1.0 - cocon_ratio / COCON_ZERO_SCORE_RATIO)
    out.cocontraction = cocon_ratio

    # Mean agonist activation. Reported for the host plot and for offline
    # tuning; not a scored component. The activation GATE in rep_cycle is what
    # enforces that the muscle did the work.
    if inp.activation_n:
        out.activation = inp.activation_sum / inp.activation_n

    # Hold steadiness: reported always, scored only if given a weight.
    steadiness = 0.0
    if inp.hold_n > 1:
        mean = inp.hold_sum / inp.hold_n
        var = max(0.0, inp.hold_sum_sq / inp.hold_n - mean * mean)
        steadiness = _clamp01(1.0 - math.sqrt(var) / STEADINESS_SD_REFERENCE)
    out.hold_steadiness = steadiness

    # Normalise by the weights in force, so zeroing a component redistributes
    # its share rather than capping the achievable score below 100.
    wsum = (w.w_range + w.w_tempo + w.w_smoothness + w.w_cocontraction +
            w.w_hold_steady)
    score = 0.0
    if wsum > 1e-6:
        score = 100.0 * (w.w_range * rng +
                         w.w_tempo * tempo +
                         w.w_smoothness * smoothness +
                         w.w_cocontraction * cocon_score +
                         w.w_hold_steady * steadiness) / wsum

    if inp.comp_flags & p.COMP_SHOULDER:
        score -= w.p_shoulder
    if inp.comp_flags & p.COMP_TRUNK:
        score -= w.p_trunk
    if inp.comp_flags & p.COMP_SWING:
        score -= w.p_swing

    out.score = int(max(0.0, min(100.0, score)) + 0.5)
    return out


def haptic_for(result: RepResult) -> int:
    """Every completed repetition is counted and then graded; the patient hears
    only whether the form was clean. Nothing is silently discarded."""
    return (p.HapticPattern.REP_FLAGGED if result.comp_flags
            else p.HapticPattern.REP_CLEAN)


class Accumulator:
    """Builds a GradingInput tick by tick at FEATURE_RATE_HZ, the way
    rep_cycle.c does while a repetition is underway."""

    #: One-pole low pass on velocity, matching REP_VEL_LPF_HZ. Peaks are
    #: detected on the filtered signal so that sensor noise does not read as a
    #: correction the patient made.
    VEL_LPF_HZ = 5.0

    def __init__(self, angle_min: float, target_angle: float = 110.0,
                 feature_rate_hz: int = 50) -> None:
        self.inp = GradingInput(angle_min=angle_min, target_angle=target_angle)
        self._rate = feature_rate_hz
        self._vel_lp = 0.0
        self._prev_vel_lp = 0.0
        self._peak_speed = 0.0
        self._peaks: list[float] = []
        self._rising = False

    def movement(self, angle: float, velocity: float, agonist: float,
                 antagonist: float = 0.0, agonist_active: bool = True) -> None:
        i = self.inp
        i.peak_angle = max(i.peak_angle, angle)

        dt = 1.0 / self._rate
        rc = 1.0 / (2.0 * math.pi * self.VEL_LPF_HZ)
        alpha = dt / (rc + dt)
        self._vel_lp += alpha * (velocity - self._vel_lp)

        speed = abs(self._vel_lp)
        self._peak_speed = max(self._peak_speed, speed)

        prev = abs(self._prev_vel_lp)
        if speed > prev:
            self._rising = True
        elif self._rising and speed < prev:
            self._peaks.append(prev)
            self._rising = False
        self._prev_vel_lp = self._vel_lp

        i.activation_sum += agonist
        i.activation_n += 1

        if EMG_N_CHANNELS > 1:
            i.antagonist_sum += antagonist
            # Evaluated only while the agonist is active: antagonist activity
            # during a rest phase is not the patient braking themselves.
            if agonist_active:
                i.overlap_sum += antagonist
                i.overlap_n += 1

    def hold(self, angle: float) -> None:
        i = self.inp
        i.hold_sum += angle
        i.hold_sum_sq += angle * angle
        i.hold_n += 1

    def compensation(self, flags: int) -> None:
        """Latched during the repetition, reported at the confirming hold."""
        self.inp.comp_flags |= flags

    def tempo(self, seconds: float) -> None:
        """Start threshold to finish threshold, excluding the hold."""
        self.inp.tempo_s = seconds

    def _significant_peaks(self) -> int:
        """Peaks clearing 10 % of this repetition's peak speed. Counted at the
        end, because the reference is not known until then."""
        if self._peak_speed <= 0.0:
            return 0
        floor_v = self._peak_speed * SMOOTH_PEAK_FRAC
        return sum(1 for m in self._peaks if m >= floor_v)

    def result(self, index: int, w: Weights = DEFAULT_WEIGHTS) -> RepResult:
        self.inp.velocity_peaks = self._significant_peaks()
        out = evaluate(self.inp, w)
        out.index = index
        return out
