# RehabSense — Phase 2 host (Flutter)

The patient-facing application of PRD §5.9, Phase 2. One Dart codebase, native
Android and iOS builds, talking to the sleeve over the BLE contract frozen in
`../firmware/main/ble/ble_service.h`.

It replaces nothing the Python client does for tuning. `../python` stays the
tool for CSV logging and offline filter work; this is the thing a patient
holds, and the thing that exercises what Python cannot — platform BLE
behaviour, connection intervals, permissions, and a user experience.

## What it does

| | |
|---|---|
| **Patient view** | Where the arm should be versus where it is, drawn live from the two IMUs. Rep counter, device-reported score, visual mirrors of the haptic cues. |
| **Calibration** | The six prompted steps of PRD §5.3, each individually repeatable. |
| **Clinician bridge** | The phone serves a live web page over the local network. Realtime features, events and scores. No backend, no accounts. |
| **Session fetch** | After a set is sealed, pulls the full ~6.6 MB record off the sleeve's SoftAP over HTTP in seconds. |

The device is authoritative for every event it reports — rep counted,
compensation, fatigue, fault. This app **displays** those events; it never
re-derives them from the raw stream. If a number here disagrees with the
firmware, the firmware is right and this is a bug.

## Build

**Toolchain first.** Neither Flutter nor the Android SDK is installed on the
project machine yet. `SETUP.md` has the current steps for both, the phone
setup, and what tends to break first. Come back here once `flutter --version`
works.

### Android — works from Windows, macOS or Linux

PowerShell, and commit first — step 1 overwrites files that only git can put
back:

```powershell
git add -A; git commit -m "Flutter host"
cd final\app

# 1. Generate the platform scaffolding. Only needed once, on a fresh clone
#    that has no android/ directory. It overwrites lib/main.dart,
#    pubspec.yaml and README.md with placeholders, so put ours back after.
flutter create --org edu.usc.cse475 --platforms=android,ios .
git checkout -- lib pubspec.yaml README.md SETUP.md
Remove-Item test\widget_test.dart -Force -ErrorAction SilentlyContinue

# 2. Apply the platform patches. Without these a BLE scan returns zero
#    devices and tells you nothing about why.
Copy-Item platform\AndroidManifest.xml android\app\src\main\AndroidManifest.xml -Force
#    iOS: follow platform/ios-Info.plist.patch.md

# 3. Build and run. pub get is NOT redundant after step 1: flutter create
#    resolved against its own placeholder pubspec, which the checkout
#    replaced.
flutter pub get
flutter test
flutter devices
flutter run -d <device-id>
```

Then **commit `android/` and `ios/`**, so the permission entries survive and
nobody has to re-apply them.

A release APK for the demo, so it does not depend on a laptop being present:

```powershell
flutter build apk --release
# build\app\outputs\flutter-apk\app-release.apk
```

### iOS — needs a Mac

There is no way around this. The iOS toolchain runs on macOS only; Windows
cannot produce an iOS build at all, and no Flutter flag changes that. The same
Dart code compiles unchanged — it is purely a toolchain problem.

Three ways through it, in order of what makes sense for a December demo:

1. **Borrow a Mac.** Clone, `flutter create --platforms=ios .`, apply
   `platform/ios-Info.plist.patch.md`, sign with a free Apple ID, `flutter run`.
   A free account installs on a connected device for 7 days, which is enough
   to prove platform BLE behaviour. Cheapest and fastest.
2. **macOS CI.** Codemagic or a GitHub Actions `macos-latest` runner builds
   the IPA from this repo with no Mac in the room. Distributing it to a device
   still needs a paid account.
3. **Paid Developer Program**, $99/yr. Only worth it if the sleeve has to be
   demonstrated on an iPhone specifically, or if TestFlight is wanted.

Until then Android is the development target, exactly as the PRD scopes it.

## Layout

```
lib/
  main.dart
  protocol/        the wire format, and nothing else
    constants.dart     UUIDs, rates, frame sizes, MTU floor
    enums.dart         every wire enum and flag bit
    frames.dart        header, EMG, IMU, features, events
    status.dart        device_status_t            (packed, 29 B)
    calib.dart         calib_record_t             (padded, 104 B)
    xfer.dart          xfer_info_t                (packed, 63 B)
    config_tlv.dart    the PRD 5.9.1 parameters
    commands.dart      control opcodes, RepComplete payload
  ble/
    rehab_device.dart  the link: scan, MTU, subscribe, commands
    seq_tracker.dart   raw-stream sequence accounting, ACK and backfill
    permissions.dart   the Android runtime permission dance
  session/
    session_state.dart what the sleeve has told us
  ui/
    theme.dart           colours and type for a phone at arm's length
    app.dart             shell, connect flow
    patient_screen.dart  the exercise view
    arm_pose_painter.dart  target versus actual, drawn
    calibration_screen.dart
    settings_screen.dart   the PRD 5.9.1 parameters, live
    clinician_screen.dart  bridge control and the Wi-Fi fetch
  bridge/
    clinician_server.dart  HTTP + WebSocket, on the phone
    clinician_page.dart    the page it serves, self-contained
  xfer/
    session_fetch.dart   post-session bulk download, resumable
test/
  protocol_golden_test.dart   wire format against the Python reference
  seq_tracker_test.dart       ACK and gap accounting
  arm_pose_test.dart          pose logic, and the painter under abuse
tool/
  gen_golden.py   regenerates the golden test's expected bytes
platform/
  AndroidManifest.xml          overwrite the generated one with this
  ios-Info.plist.patch.md      what to add on a Mac
```

## The protocol layer, and why it is tested the way it is

`lib/protocol/` is a byte-for-byte port of `../python/rehab_protocol.py`. Every
expected byte string in `test/protocol_golden_test.dart` was produced by
**running that Python module**, not by reading the header comments and not by
this Dart code.

That distinction is the whole value of the test. The Python host's status
parser once carried explicit pad bytes that the packed C struct does not have,
so every field after `battery_mv` was read from the wrong offset — and its own
test suite passed the entire time, because it parsed what it itself built.
Only a real device showed the fault. A port verified against itself would
reproduce the bug and call it green.

Three layout traps live in here, all of them silent failures rather than
crashes:

- **`features_t` is not packed.** It leads with a `uint64_t`, so the compiler
  inserts a pad byte after `rep_state` and `sizeof` is 40, not 33. Read it
  without the pad and `rep_count`, `comp_flags` and `sig_flags` all shift one
  byte left: wrong rep counts and wrong compensation flags on screen, no error
  anywhere. Both layouts are accepted and chosen by body length, so this keeps
  working if `features_t` is ever marked packed.
- **`device_status_t` and `xfer_info_t` are packed.** No padding at all.
- **`host_time_offset_us` is signed** and routinely negative. The high word
  must come from an arithmetic shift, not integer division, or it comes back
  as a large positive number.

After any deliberate wire change: run `python3 tool/gen_golden.py`, paste the
new byte strings into the test, and change the firmware in the same commit.
If it produces different bytes and nobody meant to change the format, something
has drifted and the test is doing its job.

## Two platform facts that shape the BLE layer

**Android starts at a 23-byte MTU.** Every frame here is up to 180 bytes, so
the app must `requestMtu(247)` after connecting and before subscribing, or
notifications arrive truncated. iOS negotiates 185 on its own and needs no
request — which is exactly why the firmware caps frames at 180 rather than the
244 a 247-byte MTU would allow.

**Leave the raw stream off on a phone.** At ~10.4 kB/s the full-rate EMG and
IMU stream is near the practical ceiling of a phone BLE link, and the live view
does not need it: features arrive at 20 Hz and the device has already done the
analysis. Turn it on deliberately for a debugging session (`CfgTag.rawStream`),
not by default. The clinical record travels over Wi-Fi instead.

## Why the clinician view is served by the phone

The obvious-looking design — sleeve joins the clinic Wi-Fi and streams
everywhere — is not available, and not by accident:

- The ESP32-S3 has **one 2.4 GHz radio**. Running Wi-Fi and a saturated BLE
  link together means software coexistence arbitrating between them, which
  costs throughput on both and makes BLE miss connection events. The live
  stream is the thing that must not degrade.
- So the firmware **refuses to start a transfer while `OPERATIONAL`**, and
  `session_xfer.h` is explicit that this is not a policy the host can override.
- The sleeve's Wi-Fi is a **SoftAP with no route anywhere**. Station mode
  needs credential provisioning and is deliberately out of this revision.

So the phone bridges. It holds the BLE link, renders the patient view, and
relays a thinned JSON feed to a page it serves itself. The clinician opens the
phone's address on the same network; nothing is deployed and no account exists.
Swapping that for a cloud relay later is a URL change behind the same
interface.

Sequence for a full session:

```
connect BLE  →  SET_TIME  →  GET_CONFIG  →  calibration (6 steps)
    →  START_SESSION  →  live: features 20 Hz, events, status
                         clinician page updating in realtime
    →  STOP_SESSION  →  START_TRANSFER  →  join sleeve SoftAP
    →  HTTP GET the record  →  rejoin normal Wi-Fi  →  STOP_TRANSFER
```

## Status

| | |
|---|---|
| Protocol layer + golden tests | written, tests pass by construction against the Python reference |
| BLE client, sequence accounting, live session state | written, unit-tested |
| Patient view and pose visualisation | written, painter unit-tested |
| Calibration wizard | written |
| Live parameter editing | written |
| Clinician bridge | written |
| Session fetch | written |
| Demo mode (synthetic sleeve) | written |
| **Any of it against real hardware** | **not yet — see below** |

### Nothing here has run yet

This was written against the frozen interface in `ble_service.h` and the
Python reference, on a machine with no Flutter toolchain, so it has never been
compiled and has never seen a sleeve. The byte layouts are verified against
golden vectors generated from `rehab_protocol.py`, and the sequence and pose
logic have unit tests — but `flutter pub get && flutter test && flutter run`
is the first real check, and expect to fix things on that first pass.

First bring-up, in this order:

1. `flutter test` — pure Dart, no device. If the golden tests fail, the port
   and the firmware disagree and that is worth resolving before anything else.
2. **nRF Connect on the phone, before this app.** It shows the GATT table and
   raw notification bytes with no code at all, which separates "the firmware
   is not advertising what we think" from "the app is wrong".
3. `flutter run`, connect, and watch the Settings tab: it shows the negotiated
   MTU, frames received, and what has been acknowledged. If the MTU comes back
   under 183 the raw stream will not fit.

## Working without a sleeve

Every screen past the connect pane needs a live link, so with no hardware the
app opens and stops there. **Demo mode** is the way round that: the button is
on the connect screen, below the divider.

`lib/sim/demo_driver.dart` builds real wire-format frames with the same
builders the golden tests use and pushes them through
`RehabDevice.injectNotification`, so they run the same decoders, the same
sequence tracker and the same session state as a real sleeve. Nothing above
the radio is stubbed — if the `features_t` padding were wrong, demo mode would
show wrong rep counts too.

The set is scripted so the interesting cases show up rather than twenty
identical reps:

- median frequency falling across the set, with the rest cue once it has
  fallen far enough
- every fifth rep hikes the shoulder: flagged live, named on screen, scored
  down (demo item 3)
- rep four is a passive swing — the angle rises with the biceps quiet, so no
  rep starts (demo item 4)
- `START_TRANSFER` during a set is refused, the way the firmware refuses it

Changing the confirming hold in Settings visibly changes the demo's cadence,
which is a quick way to see the live-parameter path work (demo item 6). The
seed is fixed, so a rehearsed walkthrough behaves the same every time.

What it cannot tell you: anything about platform BLE behaviour, connection
intervals, permissions, MTU negotiation or throughput. Those are exactly the
things the PRD says stay phone-side work against real hardware.

`EVT_REP_COMPLETE` is **not yet emitted by the firmware**. `rep_cycle.c`
produces a `rep_result_t` and the event path can carry 16 payload bytes, but
`main.c` does not wire it up, so `RepComplete` here implements the proposed
16-byte layout from `rehab_protocol.py`. The simulator emits it, so this path
is exercised — but per-rep scores will be empty against real firmware until
that wiring lands. Adopt, amend or replace the layout then, on both sides at
once.
