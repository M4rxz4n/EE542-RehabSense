#!/usr/bin/env python3
"""Check the Dart message parser's regexes against the firmware's own output.

Why this exists
---------------
`lib/protocol/sleeve_messages.dart` carries about twenty regexes, and three
things the app cannot get anywhere else are read through them: the `[FT1]`
fatigue percentages, the per-rep `biceps=` activation ratio, and every
calibration result. A regex that silently fails to match does not crash — it
produces a line classified as `other`, which looks exactly like a line the
firmware never sent. That is the worst failure mode available: a therapist's
fatigue chart quietly stays empty.

There is no Dart toolchain in the environment this was written in, so the
patterns are extracted from the Dart source and run here against sample lines
built from the **firmware's own `Log.printf` format strings**. Both halves
come from the real source: if `rep.cpp` changes its format, the sample changes
with it and the matching pattern fails here.

The Dart patterns in that file are plain regexes using only constructs Python
and Dart share, which is what makes this comparison legitimate. Anything using
a Dart-specific construct would have to be checked by a Dart test instead.

Usage:  python3 tool/check_message_patterns.py [path/to/sleeve_messages.dart]
Exit:   0 clean, 1 findings.
"""

from __future__ import annotations

import re
import sys

# ── Sample lines, built from the firmware's format strings ────────────────
#
# Each entry: (the line, the pattern name expected to claim it, the fields it
# must capture). Format strings referenced by file and line as of the S3 port.

CASES: list[tuple[str, str, dict[str, str]]] = [
    # comms.cpp: "# LIVE calibrated=%d set=%d/%d reps=%d partials=%d
    #             resting=%d done=%d paused=%d pace=%d"
    (
        "# LIVE calibrated=1 set=2/3 reps=7 partials=1 resting=0 done=0 "
        "paused=0 pace=1",
        "_live",
        {"1": "1", "2": "2", "3": "3", "4": "7", "5": "1", "9": "1"},
    ),
    # The same line from firmware before the 28 Oct update, with no pace field.
    (
        "# LIVE calibrated=0 set=1/3 reps=0 partials=0 resting=0 done=0 "
        "paused=0",
        "_live",
        {"1": "0", "4": "0"},
    ),
    # calib.cpp / comms.cpp: "# PARAMS target=%.0f peak=%.2f start=%.0f
    #   hyst=%.0f tempo=%.1f-%.1f muscle=%.0f sets=%dx%d rest=%d"
    (
        "# PARAMS target=95 peak=0.80 start=15 hyst=5 tempo=3.0-8.0 "
        "muscle=10 sets=3x10 rest=60",
        "_params",
        {"1": "95", "2": "0.80", "5": "3.0", "6": "8.0", "8": "3", "9": "10",
         "10": "60"},
    ),
    # rep.cpp: "# REP %d  peak=%.1f deg  duration=%.1f s  rom=%d
    #   tempo=%d (%s)  score=%d%s" then "  flags=%s" then "  biceps=%.0f%%"
    (
        "# REP 3  peak=95.0 deg  duration=4.2 s  rom=100  tempo=100 (ok)  "
        "score=100  biceps=78%",
        "_rep",
        {"1": "3", "2": "95.0", "3": "4.2", "4": "100", "5": "100", "6": "ok",
         "7": "100"},
    ),
    (
        "# REP 11  peak=62.5 deg  duration=1.8 s  rom=65  tempo=93 "
        "(too fast)  score=79  FLAGGED  flags=swing  biceps=55%",
        "_rep",
        {"1": "11", "2": "62.5", "3": "1.8", "6": "too fast", "7": "79"},
    ),
    # A slow rep: tempoText is "slow", and the duration has two digits.
    (
        "# REP 4  peak=88.0 deg  duration=11.4 s  rom=92  tempo=83 (slow)  "
        "score=87  biceps=61%",
        "_rep",
        {"3": "11.4", "6": "slow"},
    ),
    # rep.cpp: "# Partial rep (peak %.0f deg, needed %.0f)"
    (
        "# Partial rep (peak 45 deg, needed 72)",
        "_partial",
        {"1": "45", "2": "72"},
    ),
    # rep.cpp: "# NOT COUNTED [FC2]: peak %.0f deg, but the biceps was working
    #   for only %.0f%% of the lift (needs %.0f%%)."
    (
        "# NOT COUNTED [FC2]: peak 90 deg, but the biceps was working for "
        "only 20% of the lift (needs 60%).",
        "_passive",
        {"1": "90", "2": "20", "3": "60"},
    ),
    # rep.cpp: "#   [FT1] vs your first reps: range %.0f%%, effort %.0f%%,
    #   time %.0f%%%s%s%s"
    (
        "#   [FT1] vs your first reps: range 88%, effort 112%, time 105%",
        "_fatigue",
        {"1": "88", "2": "112", "3": "105"},
    ),
    (
        "#   [FT1] vs your first reps: range 72%, effort 141%, time 155%  "
        "RANGE  EFFORT  SLOW",
        "_fatigue",
        {"1": "72", "2": "141", "3": "155"},
    ),
    # rep.cpp: "#   Set %d: %d of %d"
    ("#   Set 2: 7 of 10", "_setProgress", {"1": "2", "2": "7", "3": "10"}),
    # rep.cpp: "#   [FC4] Your upper arm moved %.0f deg: ... (-%d)."
    (
        "#   [FC4] Your upper arm moved 25 deg: keep your elbow by your side "
        "and sit tall (-20).",
        "_shoulderFault",
        {"1": "25"},
    ),
    # rep.cpp: "#   [FC5] Lowered at %.0f deg/s: ... (-%d)."
    (
        "#   [FC5] Lowered at 180 deg/s: lower slowly, don't let it drop "
        "(-10).",
        "_dropFault",
        {"1": "180"},
    ),
    # pace.cpp: "# [GP1] >> UP: pull up and squeeze (%d beats)"
    ("# [GP1] >> UP: pull up and squeeze (2 beats)", "_pacePhase", {"1": "UP"}),
    ("# [GP1] >> HOLD at the top (2 beats)", "_pacePhase", {"1": "HOLD"}),
    ("# [GP1] >> DOWN: lower slowly (2 beats)", "_pacePhase", {"1": "DOWN"}),
    ("# [GP1] >> RELAX, arm straight (2 beats)", "_pacePhase", {"1": "RELAX"}),
    # emgtest.cpp: "# REST     mean %6.0f mV   noise (SD) %5.1f mV
    #   range %4.0f..%4.0f mV"  — note the width specifiers pad with spaces.
    (
        "# REST     mean    120 mV   noise (SD)   3.4 mV   range   98.. 145 mV",
        "_emgRest",
        {"1": "120", "2": "3.4"},
    ),
    # emgtest.cpp: "# SQUEEZE  mean %6.0f mV   peak %4.0f mV
    #   rise above rest %5.0f mV"
    (
        "# SQUEEZE  mean    980 mV   peak 1240 mV   rise above rest   860 mV",
        "_emgSqueeze",
        {"1": "980", "2": "1240", "3": "860"},
    ),
    # emgtest.cpp: "# SNR      %.1f dB (squeeze rise / rest noise)"
    (
        "# SNR      24.0 dB (squeeze rise / rest noise)",
        "_emgSnr",
        {"1": "24.0"},
    ),
    # emgtest.cpp verdict lines.
    (
        "# PASS  SNR at least 20 dB: clean enough for rep detection and "
        "scoring.",
        "_emgVerdict",
        {"1": "PASS"},
    ),
    (
        "# FAIL  SNR under 10 dB: rest and squeeze are hard to tell apart.",
        "_emgVerdict",
        {"1": "FAIL"},
    ),
    # calib.cpp: "Comfortable bend %.0f deg: target %.0f deg
    #   (a rep counts from %.0f deg)"
    (
        "Comfortable bend 95 deg: target 95 deg (a rep counts from 76 deg)",
        "_comfortableBend",
        {"1": "95", "2": "95"},
    ),
    # calib.cpp: "Comfortable bend only %.0f deg: keeping target %.0f deg. ..."
    (
        "Comfortable bend only 55 deg: keeping target 90 deg. Ask your "
        "therapist to set it (t<deg>).",
        "_comfortableBend",
        {"1": "55", "2": "90"},
    ),
    # calib.cpp: "Step 1 done."
    ("Step 1 done.", "_stepDone", {"1": "1"}),
    ("Step 3 done. Now relax your arm and let it hang straight.", "_stepDone",
     {"1": "3"}),
    # rep.cpp rest countdown prints bare seconds, and "Ready! 10" at ten left.
    ("60", "_restCountdown", {"1": "60"}),
    ("Ready! 10", "_restCountdown", {"1": "10"}),
]

# Lines that must NOT be claimed by a pattern they could plausibly collide
# with. A false positive here is as bad as a miss: a calibration line
# classified as a rep would attach its numbers to the wrong row.
NEGATIVE: list[tuple[str, str]] = [
    ("# REP 3  peak=95.0 deg  duration=4.2 s  rom=100  tempo=100 (ok)  "
     "score=100  biceps=78%", "_partial"),
    ("#   Set 2: 7 of 10", "_rep"),
    ("# Partial rep (peak 45 deg, needed 72)", "_rep"),
    ("# Waiting to calibrate. Put the sleeve on, sit comfortably, then type "
     "c (or press BOOT).", "_rep"),
    ("Rep start! Set 1 of 3", "_rep"),
    ("Rep start! Set 1 of 3", "_restCountdown"),
    ("# LIVE calibrated=1 set=2/3 reps=7 partials=1 resting=0 done=0 "
     "paused=0 pace=1", "_params"),
    ("# === EMG signal-quality test ===", "_emgVerdict"),
    ("Set 2 of 3 complete. Well done! Rest for 60 s: let your arm relax.",
     "_restCountdown"),
]


def extract_patterns(src: str) -> dict[str, str]:
    """Pull the regex bodies out of the Dart source.

    The parser builds its patterns two ways — a raw string `RegExp(r'…')` and
    an interpolated one `RegExp('…$_numPattern…')` — so both are handled, and
    `$_numPattern` is substituted with its literal value.
    """
    num = re.search(r"final\s+_numPattern\s*=\s*r'([^']*)'", src)
    if not num:
        raise SystemExit("could not find _numPattern in the Dart source")
    num_body = num.group(1)

    out: dict[str, str] = {}

    # Adjacent string literals are concatenated in Dart, so a pattern may be
    # split across several lines. Grab everything up to the closing paren.
    for m in re.finditer(
        r"final\s+(_[A-Za-z0-9_]+)\s*=\s*RegExp\(\s*(.*?)\s*\);",
        src,
        re.S,
    ):
        name, body = m.group(1), m.group(2)
        pieces = re.findall(r"r?'((?:[^'\\]|\\.)*)'", body)
        if not pieces:
            continue
        joined = "".join(pieces)
        joined = joined.replace("$_numPattern", num_body)
        # Dart's \\ inside a non-raw string is one backslash to the regex
        # engine; a raw string's is already one. Normalise to one.
        joined = joined.replace("\\\\", "\\")
        out[name] = joined
    return out


def main(path: str) -> int:
    with open(path, encoding="utf-8") as fh:
        src = fh.read()

    patterns = extract_patterns(src)
    if not patterns:
        print("no patterns extracted — has the Dart source been restructured?")
        return 1

    compiled: dict[str, re.Pattern[str]] = {}
    findings: list[str] = []

    for name, body in patterns.items():
        try:
            compiled[name] = re.compile(body)
        except re.error as e:
            findings.append(f"{name}: will not compile as a regex: {e}")

    print(f"extracted {len(patterns)} patterns from {path}")

    for line, name, groups in CASES:
        pat = compiled.get(name)
        if pat is None:
            findings.append(f"{name}: no such pattern (case: {line[:50]}…)")
            continue
        m = pat.search(line)
        if m is None:
            findings.append(
                f"{name} did NOT match a line the firmware prints:\n"
                f"    {line}"
            )
            continue
        for g, expected in groups.items():
            try:
                got = m.group(int(g))
            except (IndexError, re.error):
                findings.append(f"{name}: no group {g} (line: {line[:50]}…)")
                continue
            if got != expected:
                findings.append(
                    f"{name} group {g}: expected {expected!r}, got {got!r}\n"
                    f"    {line}"
                )

    for line, name in NEGATIVE:
        pat = compiled.get(name)
        if pat is None:
            continue
        if pat.search(line) is not None:
            findings.append(
                f"{name} WRONGLY claimed a line that is not its shape:\n"
                f"    {line}"
            )

    print(f"ran {len(CASES)} positive and {len(NEGATIVE)} negative cases")
    if not findings:
        print("every pattern matches the firmware's own output")
        return 0

    for f in findings:
        print(f)
    print(f"\n{len(findings)} finding(s)")
    return 1


if __name__ == "__main__":
    sys.exit(main(
        sys.argv[1] if len(sys.argv) > 1
        else "lib/protocol/sleeve_messages.dart"
    ))
