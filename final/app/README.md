# RehabSense app

The phone app: the host for the sleeve, and the thing that gets demoed. One
Dart codebase for iOS and Android.

It talks to `../firmware-s3/` — the shipping Arduino firmware for the ESP32-S3
/ XIAO. Build and wiring for that are in `../firmware-s3/README.md`.

---

## Run it

```bash
flutter pub get
flutter analyze && flutter test
flutter run            # a phone, or -d chrome for the layout only
```

**Do `flutter analyze` first.** Large parts of this app were written in an
environment with no Dart toolchain, and verified instead by two checkers of
its own (below). Those catch what goes wrong *across* files; they are not a
compiler.

### iOS

`ios/Runner/Info.plist` already carries the Bluetooth usage strings. On a
device you need a signing team in Xcode — open `ios/Runner.xcworkspace`, set
it under Signing & Capabilities, then `flutter run`.

### Android

See `platform/AndroidManifest.xml`: Android 12+ splits Bluetooth into
`BLUETOOTH_SCAN` / `BLUETOOTH_CONNECT`, and Android 11 and below need location
for a BLE scan. A scan without those permissions returns an empty list and
reports nothing, which is the single most common way to lose an afternoon to
this.

---

## The five tabs

| Tab | Reader | Question it answers |
| --- | --- | --- |
| **Exercise** | the patient, mid-curl | Am I high enough, is my elbow drifting, is the muscle doing the work |
| **Calibrate** | patient and therapist | Is this set up so the numbers mean anything |
| **Session** | therapist, between sets | What happened, and which rep went wrong |
| **Progress** | therapist, between visits | Is this person getting better |
| **Therapist** | therapist, live | Is this prescription working, and is it safe to carry on |

**Developer tools** are in the overflow menu, not a sixth tab. A bench tool one
tap from a patient's screen is a bench tool that gets opened by accident
mid-session.

### What is on the Developer screen

The sleeve's own command line, the twelve haptic patterns with a blind test,
the EMG signal test, every printed line the sleeve sent, the binary event log,
the adaptive-target controls, link diagnostics, the clinician bridge and the
Wi-Fi fetch.

---

## How this relates to the HTML session viewer

The viewer (`prototype/prototype demo final file/RehabSense Session Viewer.html`)
was the reference for this port, and nearly all of it is here:

| Viewer feature | Where it went |
| --- | --- |
| Live readouts, chips, status | Exercise + Therapist |
| Calibration tool and console | Calibrate |
| Session summary tiles | Session |
| Whole-session overview strip | Session |
| Elbow-angle and biceps-effort charts | Session |
| Peak-angle and duration bar charts | Session |
| Rep table with per-rep "why" | Session |
| Progress-over-time charts | Progress |
| Session comparison, saved list | Progress |
| Export / import progress | Progress |
| Patient kiosk screen | Exercise, plus the pain/effort rating |
| Therapist dashboard, fatigue trend, flags | Therapist |
| Haptic tester, event log, command box, CSV | Developer |

**Not ported:** replaying a recorded Serial Monitor log. The viewer loads a
`.txt` log and plays it through the charts, which is genuinely useful on a
laptop with a USB cable attached — and on a phone there is no log file to
load, because the phone is never the thing holding the serial port. The
Developer tab's **Copy the whole log** puts the sleeve's printed output on the
clipboard in exactly the viewer's input format, so the two tools still meet:
record on the phone, replay in the viewer.

---

## Two things that are easy to get wrong

### The target the sleeve is using is not the target you configured

Calibration replaces the target angle with an adaptive one derived from the
patient's own comfortable bend, capped at that bend plus 15°, and it announces
the change **only in a printed line**. A screen reading the TLV config would
tell a therapist their 110° target was in force when the sleeve had quietly
eased it to 95°.

So everything reads `state.effectiveTargetDeg` and friends, which prefer what
the sleeve says over what the app wrote, and the Therapist tab says plainly
when the two differ. The Developer tab can lock the therapist's number.

### Three things arrive only as text

The Messages characteristic (`000A`) is not a debug channel. These exist
nowhere else:

- the `[FT1]` fatigue percentages — `EVT_FATIGUE_WARN` carries only a *count*
  of signs, so without the text the therapist's fatigue chart is empty
- the per-rep `biceps=NN%` activation ratio — the `[FC2]` criterion
- all of calibration's results: the rest level, the noise floor, the maximum
  contraction, the comfortable bend

`lib/protocol/sleeve_messages.dart` parses them. A regex that silently stops
matching does not throw — it yields a line classified as `other`, which looks
exactly like a line the firmware never sent. That is why the parser has its
own checker.

---

## Verification

```bash
flutter analyze && flutter test       # the real thing — run this
python3 tool/check_dart.py            # structural cross-check, no SDK needed
python3 tool/check_message_patterns.py
```

### `tool/check_dart.py`

Checks, across every file in `lib/` and `test/`: delimiters balance, every
import resolves (relative and `package:rehabsense/…`), no public top-level
name is declared twice, every capitalised identifier is declared or imported
or a known SDK name, every `Type.member` access names a real member, and every
named argument matches a real constructor parameter.

Name-level, not a compile: a clean run means the names line up. It is the
reason a few thousand lines of Dart written without a toolchain are not simply
unchecked. An SDK name it has not heard of shows up as a finding; adding it to
the list in that file is a one-line fix.

### `tool/check_message_patterns.py`

Extracts the regexes from the parser and runs them against sample lines built
from the firmware's own `Log.printf` format strings — 28 positive cases and 9
negative ones, each commented with the firmware file it came from. Both halves
come from real source, so if `rep.cpp` changes its format the sample changes
with it and the pattern fails here.

`test/sleeve_messages_test.dart` runs the same corpus in Dart. The Python
version exists because it can run with no SDK.

---

## Layout

```
lib/
  main.dart                 app, device, session state, saved-session store
  protocol/                 the wire format. Mirrors the firmware; change both sides together
    constants.dart          UUIDs, frame sizes, scaling
    enums.dart              opcodes, events, states, flag bits
    frames.dart             frame encode/decode, incl. the features_t pad byte
    commands.dart           command builders, event payloads, TEXT (0x20)
    sleeve_messages.dart    the printed lines: reassembly and parsing
    config_tlv.dart         runtime configuration
    calib.dart status.dart xfer.dart
  ble/
    rehab_device.dart       the link, and nothing else
    permissions.dart seq_tracker.dart
  session/
    session_state.dart      one place holding what the sleeve has said
    rep_log.dart            the rep log, and the phase reconstruction
    session_record.dart     a finished session, saveable and comparable
    session_store.dart      saved sessions on the phone, per patient
  sim/demo_driver.dart      a synthetic sleeve, frames and printed lines
  ui/
    app.dart                the shell: five tabs, the connect pane
    patient_screen.dart calibration_screen.dart session_screen.dart
    progress_screen.dart therapist_screen.dart developer_screen.dart
    settings_screen.dart
    arm_pose_painter.dart   the anatomical arm
    charts/                 chart kit: palette, scales, traces, bars, trends
    theme.dart
  bridge/                   the clinician bridge: an HTTP + WebSocket page
  xfer/session_fetch.dart   the post-session Wi-Fi fetch (ESP-IDF firmware only)
tool/                       the two checkers, and the golden-vector generator
```

---

## The arm visualizer

`ui/arm_pose_painter.dart`. An anatomical limb rather than two sticks, because
a line with a dot on it answers only the first of the patient's three
questions.

The biceps belly carries **two signals on two channels, deliberately kept
apart**:

- **shape** follows the elbow angle — the belly shortens and thickens as the
  elbow flexes, because that is what a contracting biceps does, and it happens
  whether or not the muscle is doing the work
- **colour** follows the EMG envelope — cool and flat at rest, warm under load

So an arm somebody else is lifting shows a flexed shape in a cold colour. That
is visibly different from a rep the patient drove, and it is the exact case a
motion-only device cannot show at all.

Both arms are still drawn from the two numbers the device already derives —
`elbow_angle_deg` and `upper_arm_dev_deg`. Nothing here re-derives orientation
from raw accelerometer and gyroscope data.

---

## The charts

`ui/charts/`. Two rules they do not break.

**No dual axes.** Elbow angle is degrees and muscle effort is a percentage of
a calibrated squeeze. On two y-scales in one frame they appear to cross, and
the crossing point is an artefact of the two scalings — it means nothing and it
is the first thing the eye goes to. They are two panels sharing one time axis,
which makes the true comparison (*when* the muscle worked against *when* the
arm moved) the easy one to read. That comparison is what diagnoses a passive
lift.

**Status colours stay status.** Green, amber and red mean on target, needs
attention, problem. They are never pressed into service as "series 4", and
they always carry a label or a shape as well.

The series palette is not the UI palette. `RehabColors.actual` and `.muscle`
are bright because the patient view is read at arm's length; both sit at OKLCH
L ≈ 0.77, outside the 0.48–0.67 band a dark chart surface needs, so two series
in those colours fight each other and the surface. `ChartPalette.series` is
three validated darker siblings of the same hues — lightness band, chroma
floor, CVD separation (worst adjacent pair ΔE 20.4 protan / 13.6 tritan),
normal-vision floor (ΔE 21.2) and contrast all pass against surface
`#181D23`. Three slots, assigned in fixed order, never cycled.

---

## What the sleeve does not report

Stated here because each one is a place where the app could be made to look
more capable than the hardware is, and should not be.

| Not reported | Consequence |
| --- | --- |
| Lift / hold / lower split | Reconstructed in the app by timing `rep_state` at 20 Hz. Labelled as reconstructed everywhere it appears, including the CSV column names |
| Median frequency | Always zero: it needs the MyoWare's RAW output and the prototype uses ENV. The therapist view leans on the sleeve's `[FT1]` comparison instead |
| Trunk lean | Separating a lean from a shoulder hike needs common-mode rotation of both IMUs. A lean is reported as a shoulder hike, and the Therapist tab says so |
| `RepState.extendedHold` | The sleeve's cycle is four states and it counts on crossing the finish angle, not after a confirming hold. Nothing may *require* this state |
| Wi-Fi session transfer | Every `START_TRANSFER` is answered `FAILED`. The fetch card says so rather than letting someone wait |
| Session backfill | Nothing is buffered, so there is no gap recovery. The app therefore does not subscribe to the raw stream by default — see below |

### The raw stream is off by default

Not an optimisation. NimBLE has about a dozen notification buffers, and
subscribing to the raw characteristic costs ~17 IMU frames a second whether or
not anything decodes them. That burst is what used to exhaust the buffers and
silently discard printed lines and rep events — the bug the firmware's 28 Oct
fix was written for. Not asking for data nothing reads keeps the headroom that
fix bought.

Against the ESP-IDF firmware, which does buffer a session and serve backfill,
set `RehabDevice.wantRawSamples` before connecting: it also controls gap
detection and the ACK that frees the device's storage.

---

## Demo mode

No sleeve needed. It builds **real wire-format frames** with the same builders
the golden tests use and pushes them through
`RehabDevice.injectNotification`, so the same decoders, sequence tracker and
session state run as with a real sleeve. If the pad byte in `features_t` were
wrong, demo mode would show wrong rep counts too.

It also emits the **printed lines**, in the firmware's own formats — otherwise
it would exercise none of the paths most likely to be wrong: the fatigue chart
would be empty, the rep table's pace column blank and the calibration console
silent.

Scripted so the interesting cases show up rather than twenty identical reps: a
shoulder-hike rep flagged and scored down, a passive swing that counts
nothing, a partial that stops short, the fatigue comparison walking up to a
sign, and the set-complete rating prompt.

It proves nothing about Bluetooth itself — connection intervals, permissions,
MTU, throughput. Every screen says DEMO while it runs, because synthetic data
that is not obviously synthetic is how a demo ends up quoted as a result.

---

## Saved sessions

One JSON file per session under the app's documents directory, indexed by
reading the directory. One corrupt file costs one session rather than the whole
history, and a session is written once and then only read.

**The configuration snapshot is data, not metadata.** A rep that reached 95°
means something different against a 90° target than against a 120° one, so the
thresholds in force are part of the record. Without them the progress charts
would quietly become meaningless the first time a therapist changed the
target.

Per patient, always: one sleeve and one phone get shared between people, and
merging two patients' reps into one trend line is worse than having no trend
line — it produces a chart that looks like data and is not.

Export is the files concatenated into one JSON document, so it restores on
another phone and can be read by hand. Import is additive and keyed on session
id, so importing the same file twice changes nothing.

---

## Still open

| Open | Needs |
| --- | --- |
| `flutter analyze` and `flutter test` | A machine with the SDK. Neither has been run — see the top of this file |
| A real connection to the S3 firmware | The firmware has never been flashed. Both sides are built; neither has met the other |
| The MTU path on Android | Android starts every connection at 23 bytes. iOS negotiates 185 on its own, which is why frames are capped at 180 |
| Rep-complete fidelity | `RepComplete`'s 16-byte layout is the proposal from `rehab_protocol.py`. The Arduino firmware emits it; the ESP-IDF firmware does not wire it up yet |
| Pain/effort scale wording | Clinical review. The 0–10 anchors here are the usual ones, not a validated instrument |
