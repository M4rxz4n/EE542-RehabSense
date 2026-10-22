"""
Check rehab_grading against the behaviour grading.c specifies.

The device is authoritative for scores, so this file is not checking the
host's opinion of a repetition — it is checking that the Python mirror of
grading.c still behaves the way grading.c does. If grading.c changes and this
file does not, these checks are what should fail.

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
    """A clean repetition: full range, 45 % MVC, smooth, steady, quiet
    antagonist."""
    n = 80
    inp = g.GradingInput(
        peak_angle=100.0, angle_min=8.0, angle_max=100.0,
        activation_sum=0.45 * n, antagonist_sum=0.05 * n, activation_n=n,
        jerk_sum=1.2 * n, speed_sum=40.0 * n, jerk_n=n,
        hold_sum=100.0 * 50, hold_sum_sq=100.0 * 100.0 * 50, hold_n=50,
        t_start_us=0, t_end_us=2_700_000)
    for k, v in kw.items():
        setattr(inp, k, v)
    return inp


print("[1] weights and penalties match rehab_config.h")
check(abs(g.GRADE_W_RANGE - 0.40) < 1e-9, "w_range 0.40")
check(abs(g.GRADE_W_ACTIVATION - 0.25) < 1e-9, "w_activation 0.25")
check(abs(g.GRADE_W_SMOOTHNESS - 0.20) < 1e-9, "w_smoothness 0.20")
check(abs(g.GRADE_W_HOLD_STEADY - 0.15) < 1e-9, "w_hold_steady 0.15")
total = (g.GRADE_W_RANGE + g.GRADE_W_ACTIVATION + g.GRADE_W_SMOOTHNESS
         + g.GRADE_W_HOLD_STEADY)
check(abs(total - 1.0) < 1e-9, "weights sum to 1.0")
check(g.PENALTY_SHOULDER_HIKE == 20.0 and g.PENALTY_TRUNK_LEAN == 15.0
      and g.PENALTY_ARM_SWING == 15.0 and g.PENALTY_COCONTRACTION == 15.0,
      "penalties 20 / 15 / 15 / 15")
check(abs(g.COCONTRACTION_THRESHOLD - 0.35) < 1e-9, "co-contraction threshold")

print("\n[2] range is a fraction of this patient's own calibrated ROM")
r = g.evaluate(clean())
check(abs(r.rom_fraction - 1.0) < 1e-6, "reaching angle_max is 1.0")
half = g.evaluate(clean(peak_angle=54.0))
check(abs(half.rom_fraction - 0.5) < 0.01, f"half way is {half.rom_fraction:.2f}")
over = g.evaluate(clean(peak_angle=140.0))
check(abs(over.rom_fraction - 1.0) < 1e-6, "past angle_max clamps to 1.0")
# A patient with a 30-degree ROM reaching their own limit scores the same as
# one with a 90-degree ROM reaching theirs. That is the point of calibrating.
narrow = g.evaluate(clean(angle_min=40.0, angle_max=70.0, peak_angle=70.0))
check(abs(narrow.rom_fraction - 1.0) < 1e-6,
      "a small but complete range still scores full marks")

print("\n[3] activation saturates at 60 % MVC, not 100 %")
n = 80
low = g.evaluate(clean(activation_sum=0.30 * n))
full = g.evaluate(clean(activation_sum=0.60 * n))
higher = g.evaluate(clean(activation_sum=0.95 * n))
check(full.score > low.score, "more activation scores better")
check(higher.score == full.score,
      "past 60 % MVC adds nothing — home rehab is not a maximal effort")

print("\n[4] a full-range repetition driven by momentum scores badly")
# Same range, same smoothness, almost no muscle: this is the case kinematic
# sensing alone cannot see, and the whole reason EMG is in the device.
swung = g.evaluate(clean(activation_sum=0.04 * n, antagonist_sum=0.01 * n))
check(swung.score < g.evaluate(clean()).score - 15,
      f"swung scores {swung.score} against {g.evaluate(clean()).score}")

print("\n[5] smoothness does not reward moving slowly")
# Raw mean |d(velocity)| scales with speed, so an unnormalised metric would
# hand a better score to anyone who guards. Scaling jerk and speed together
# must leave the score untouched.
fast = g.evaluate(clean(jerk_sum=1.2 * n, speed_sum=40.0 * n))
slow = g.evaluate(clean(jerk_sum=0.3 * n, speed_sum=10.0 * n))
check(fast.smoothness == slow.smoothness,
      f"same shape at a quarter speed scores the same ({fast.smoothness:.3f})")
jerky = g.evaluate(clean(jerk_sum=12.0 * n, speed_sum=40.0 * n))
check(jerky.smoothness < fast.smoothness, "a jerkier path scores worse")
barely = g.evaluate(clean(jerk_sum=0.01 * n, speed_sum=0.4 * n))
check(barely.smoothness == 0.0,
      "below 1 deg/s smoothness is zero rather than flattering")

print("\n[6] hold steadiness is the inverse SD of the angle")
steady = g.evaluate(clean(hold_sum=100.0 * 50, hold_sum_sq=100.0 ** 2 * 50,
                          hold_n=50))
check(abs(steady.hold_steadiness - 1.0) < 1e-6, "a perfectly still hold is 1.0")
# 5 degrees of wobble scores zero: SD of 5 against the 5-degree reference.
mean, sd, hn = 100.0, 5.0, 50
wobbly = g.evaluate(clean(hold_sum=mean * hn,
                          hold_sum_sq=(sd * sd + mean * mean) * hn, hold_n=hn))
check(wobbly.hold_steadiness == 0.0, "5 degrees of wobble scores zero")
check(g.evaluate(clean(hold_n=0)).hold_steadiness == 0.0,
      "no hold samples is zero, not a crash")

print("\n[7] compensation penalties")
base = g.evaluate(clean()).score
for flag, penalty, label in [(p.COMP_SHOULDER, 20, "shoulder hike"),
                             (p.COMP_TRUNK, 15, "trunk lean"),
                             (p.COMP_SWING, 15, "arm swing")]:
    got = g.evaluate(clean(comp_flags=flag))
    check(got.score == base - penalty, f"{label} costs {penalty}")
both = g.evaluate(clean(comp_flags=p.COMP_SHOULDER | p.COMP_TRUNK))
check(both.score == base - 35, "penalties stack")

print("\n[8] co-contraction is scaled, not a cliff")
under = g.evaluate(clean(antagonist_sum=0.45 * n * 0.30))   # ratio 0.30
check(under.score == base, "below the threshold costs nothing")
at_2x = g.evaluate(clean(antagonist_sum=0.45 * n * 0.70))   # ratio 0.70
check(at_2x.score == base - 15, "twice the threshold costs the full penalty")
mid = g.evaluate(clean(antagonist_sum=0.45 * n * 0.525))    # ratio 0.525
check(base - 15 < mid.score < base, f"half way over costs part of it ({mid.score})")
far = g.evaluate(clean(antagonist_sum=0.45 * n * 2.0))
check(far.score == base - 15, "well past twice the threshold does not cost more")

print("\n[9] the score is clamped, and nothing is discarded")
awful = g.evaluate(clean(peak_angle=10.0, activation_sum=0.01 * n,
                         jerk_sum=40.0 * n, hold_n=0,
                         comp_flags=p.COMP_SHOULDER | p.COMP_TRUNK | p.COMP_SWING))
check(awful.score == 0, "a terrible repetition floors at 0, not below")
check(0 <= g.evaluate(clean()).score <= 100, "a good one stays inside 0..100")
# Every completed repetition is counted and then graded: a compensated
# repetition still produces a result, it just scores lower.
flagged = g.evaluate(clean(comp_flags=p.COMP_SHOULDER))
check(flagged.score > 0 and flagged.comp_flags == p.COMP_SHOULDER,
      "a compensated repetition is still graded and still reported")

print("\n[10] the patient hears pass or fail, not the number")
check(g.haptic_for(g.evaluate(clean())) == p.HapticPattern.REP_COMPLETE,
      "clean repetition gets the single pulse")
check(g.haptic_for(flagged) == p.HapticPattern.REP_COMPENSATED,
      "compensated repetition gets the three pulses")

print("\n[11] weights are overridable per patient")
# A reasonable penalty for a healthy volunteer staging a compensation is an
# unreasonable one for a patient whose compensation is the only way they can
# complete the movement.
gentle = g.Weights(p_shoulder=5.0)
check(g.evaluate(clean(comp_flags=p.COMP_SHOULDER), gentle).score == base - 5,
      "a lighter shoulder penalty applies")
range_only = g.Weights(w_range=1.0, w_activation=0.0, w_smoothness=0.0,
                       w_hold_steady=0.0)
check(g.evaluate(clean(peak_angle=54.0), range_only).score == 50,
      "weighting range alone gives the range fraction as the score")

print("\n[12] the accumulator builds the same input tick by tick")
acc = g.Accumulator(8.0, 100.0)
for i in range(40):
    acc.movement(angle=8.0 + i * 2.3, velocity=40.0, agonist=0.45,
                 antagonist=0.05)
for _ in range(50):
    acc.hold(100.0)
acc.compensation(p.COMP_SHOULDER)
res = acc.result(index=3)
check(res.index == 3, "index is carried")
check(res.comp_flags == p.COMP_SHOULDER, "compensation latched during the rep")
check(abs(res.activation - 0.45) < 1e-6, "mean activation")
check(res.hold_steadiness > 0.99, "a still hold")
check(len(res.to_event_payload()) == 16, "packs into the event payload")

print(f"\n{'FAILURES PRESENT' if failures else 'all checks passed'} "
      f"({failures} failure{'' if failures == 1 else 's'})")
sys.exit(1 if failures else 0)
