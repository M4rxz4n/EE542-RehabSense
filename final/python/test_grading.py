"""
Check rehab_grading against the behaviour grading.c specifies.

The device is authoritative for scores, so this file is not checking the
host's opinion of a repetition — it is checking that the Python mirror of
grading.c still behaves the way grading.c does. If grading.c changes and this
file does not, these checks are what should fail.

Scoring model: PRD v1.4 §5.5 — range, tempo, smoothness and co-contraction at
equal weight, then deductions, clamped to 0..100. Hold steadiness is reported
but weighted zero. On the single-channel prototype co-contraction is also
weighted zero, because there is no antagonist envelope to measure it from.

    python3 test_grading.py
"""

import sys

import rehab_grading as g
import rehab_protocol as p

failures = 0


def check(cond, label):
    global failures
    if cond:
        print(f"  ok:   {label}")
    else:
        print(f"  FAIL: {label}")
        failures += 1


def clean(**kw) -> g.GradingInput:
    """A clean repetition: reaches the target angle, inside the tempo window,
    one smooth push, steady hold, quiet antagonist."""
    n = 80
    inp = g.GradingInput(
        peak_angle=118.0, angle_min=8.0, target_angle=110.0,
        tempo_s=2.4,
        activation_sum=0.45 * n, antagonist_sum=0.05 * n,
        overlap_sum=0.05 * n, activation_n=n, overlap_n=n,
        velocity_peaks=1,
        hold_sum=8.0 * 50, hold_sum_sq=8.0 * 8.0 * 50, hold_n=50,
        t_start_us=0, t_end_us=2_700_000)
    for k, v in kw.items():
        setattr(inp, k, v)
    return inp


print("[1] weights and penalties match rehab_config.h")
check(abs(g.GRADE_W_RANGE - 0.25) < 1e-9, "w_range 0.25")
check(abs(g.GRADE_W_TEMPO - 0.25) < 1e-9, "w_tempo 0.25")
check(abs(g.GRADE_W_SMOOTHNESS - 0.25) < 1e-9, "w_smoothness 0.25")
check(abs(g.GRADE_W_HOLD_STEADY) < 1e-9,
      "hold steadiness is reported, not scored")
if g.EMG_N_CHANNELS > 1:
    check(abs(g.GRADE_W_COCONTRACTION - 0.25) < 1e-9, "w_cocontraction 0.25")
else:
    check(abs(g.GRADE_W_COCONTRACTION) < 1e-9,
          "co-contraction unweighted on the single-channel prototype")
check(g.PENALTY_SHOULDER_HIKE == 20.0 and g.PENALTY_TRUNK_LEAN == 15.0
      and g.PENALTY_ARM_SWING == 15.0, "deductions 20 / 15 / 15")

print("\n[2] a clean repetition scores near the top")
r = g.evaluate(clean())
check(r.score >= 98, f"clean repetition scores {r.score}")
check(abs(r.tempo_s - 2.4) < 1e-6, "tempo is reported")

print("\n[3] range is measured against the THERAPIST'S target, not measured ROM")
# A patient whose range is shrinking must not keep scoring 100 because their
# own maximum shrank with it.
full = g.evaluate(clean(peak_angle=118.0))
check(abs(full.rom_fraction - 1.0) < 1e-6, "reaching the target is 1.0")
half = g.evaluate(clean(peak_angle=63.0))
check(abs(half.rom_fraction - 0.5) < 0.01,
      f"half the target is {half.rom_fraction:.2f}")
check(half.score < full.score, f"and scores lower: {half.score} < {full.score}")

lower_target = g.evaluate(clean(peak_angle=63.0, target_angle=55.0))
check(abs(lower_target.rom_fraction - 1.0) < 1e-6,
      "the same curl is full range against a lower target")

print("\n[4] tempo scores against the prescribed window")
inside = g.evaluate(clean(tempo_s=2.4))
fast = g.evaluate(clean(tempo_s=0.6))
slow = g.evaluate(clean(tempo_s=9.0))
check(inside.score > fast.score, f"too fast scores lower ({fast.score})")
check(inside.score > slow.score, f"too slow scores lower ({slow.score})")
edge = g.evaluate(clean(tempo_s=g.TEMPO_MAX_S))
check(edge.score == inside.score, "the window edge still gets full credit")
just_outside = g.evaluate(clean(tempo_s=g.TEMPO_MAX_S + 0.3))
check(just_outside.score < inside.score and just_outside.score > slow.score,
      "just outside is marked down, not zeroed")

print("\n[5] smoothness counts pushes")
one = g.evaluate(clean(velocity_peaks=1))
three = g.evaluate(clean(velocity_peaks=3))
check(abs(one.smoothness - 1.0) < 1e-9, "one push scores 1.0")
check(abs(three.smoothness - 0.5) < 1e-9, "three pushes score 0.5")
check(three.score < one.score, f"and the score follows ({three.score} < {one.score})")
many = g.evaluate(clean(velocity_peaks=9))
check(abs(many.smoothness) < 1e-9, "nine pushes score zero, not negative")

print("\n[6] smoothness does not reward slow movement")
# This is the bug the suite caught during development: an unnormalised jerk
# metric handed a better score to anyone who simply moved slower, rewarding
# exactly the guarding behaviour the device exists to discourage. A peak count
# is scale-free, so the same shape scores the same at any speed.
fast_smooth = g.evaluate(clean(tempo_s=1.6, velocity_peaks=1))
slow_smooth = g.evaluate(clean(tempo_s=3.4, velocity_peaks=1))
check(fast_smooth.smoothness == slow_smooth.smoothness,
      "the same shape scores the same at either end of the window")
check(abs(fast_smooth.score - slow_smooth.score) <= 1,
      f"and the totals agree: {fast_smooth.score} vs {slow_smooth.score}")

print("\n[7] deductions apply after the weighted mean")
base = g.evaluate(clean())
sh = g.evaluate(clean(comp_flags=p.COMP_SHOULDER))
check(base.score - sh.score == 20, f"shoulder costs 20 ({base.score} -> {sh.score})")
tr = g.evaluate(clean(comp_flags=p.COMP_TRUNK))
check(base.score - tr.score == 15, f"trunk costs 15 ({base.score} -> {tr.score})")
both = g.evaluate(clean(comp_flags=p.COMP_SHOULDER | p.COMP_TRUNK))
check(base.score - both.score == 35, "flags are additive when both are real")
floored = g.evaluate(clean(peak_angle=20.0, tempo_s=20.0, velocity_peaks=9,
                           comp_flags=p.COMP_SHOULDER | p.COMP_TRUNK
                           | p.COMP_SWING))
check(floored.score == 0, "the result is clamped at zero, never negative")

print("\n[8] zeroing a component redistributes rather than capping the score")
# Without normalisation, a host that switched one component off would cap the
# best achievable score below 100 and every patient would look worse.
w = g.Weights(w_tempo=0.0)
r = g.evaluate(clean(), w)
check(r.score >= 98,
      f"a perfect repetition still scores {r.score} with tempo switched off")

if g.EMG_N_CHANNELS == 1:
    print("\n[9] co-contraction is not fabricated on one channel")
    r = g.evaluate(clean(overlap_sum=999.0, overlap_n=10))
    check(r.cocontraction == 0.0,
          "reported as 0, not as a ratio against a channel that does not exist")
    check(r.score >= 98, "and it cannot drag the score down")

print("\n[10] the accumulator builds the same input tick by tick")
acc = g.Accumulator(angle_min=8.0, target_angle=110.0, feature_rate_hz=50)
import math
N = 60
for i in range(N):
    # One raised-cosine push from 8 to 118 degrees.
    u = (i + 1) / N
    s = 0.5 - 0.5 * math.cos(u * math.pi)
    angle = 8.0 + 110.0 * s
    vel = 110.0 * math.pi * math.sin(u * math.pi) / 2.0 * (50.0 / N)
    acc.movement(angle, vel, agonist=0.45, antagonist=0.05)
acc.compensation(p.COMP_SHOULDER)
acc.tempo(2.4)
for _ in range(50):
    acc.hold(8.0)
res = acc.result(index=4)

check(res.index == 4, "index is carried")
check(res.comp_flags & p.COMP_SHOULDER, "compensation latched during the rep")
check(abs(res.activation - 0.45) < 1e-6, "mean activation")
check(abs(res.peak_angle_deg - 118.0) < 0.5, "peak angle")
check(res.velocity_peaks == 1,
      f"one smooth push registers as one peak ({res.velocity_peaks})")
check(abs(res.hold_steadiness - 1.0) < 1e-6, "a still hold scores 1.0")
check(abs(res.tempo_s - 2.4) < 1e-6, "tempo is carried")

print("\n[11] the patient hears pass or fail, nothing finer")
check(g.haptic_for(g.evaluate(clean())) == p.HapticPattern.REP_CLEAN,
      "a clean repetition gets the single click")
check(g.haptic_for(g.evaluate(clean(comp_flags=p.COMP_SWING)))
      == p.HapticPattern.REP_FLAGGED,
      "a flagged repetition gets the three pulses")

print(f"\n{'FAILURES' if failures else 'all checks passed'} "
      f"({failures} failure{'' if failures == 1 else 's'})")
sys.exit(1 if failures else 0)
