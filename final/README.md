# RehabSense — final

Single-channel sEMG + dual-IMU armband for home-based stroke rehabilitation.
Built to PRD v1.4.

## What to flash, and what to run

```
firmware-s3/   ← FLASH THIS.  Arduino, ESP32-S3 / XIAO ESP32S3
app/           ← RUN THIS.    Flutter, iOS and Android
```

Everything else here is reference or tooling:

| Directory | What it is |
| --- | --- |
| `firmware-s3/` | **The shipping firmware.** `rehabsense_v5` retargeted from the ESP32 Dev Module to the ESP32-S3. All of FC1–FC6, FT1–FT4, AP1–AP2, GP1–GP3, AT1–AT4 |
| `app/` | **The shipping app.** Patient, calibration, session analysis, progress over time, therapist dashboard, developer tools |
| `firmware/` | The ESP-IDF tree: the PRD-shaped reference implementation. Kept for its design, its host test suites and its wire-format definitions. **Does not implement the step 1–5 behaviour**, so it is not what gets flashed |
| `python/` | The `bleak` host client and the offline analysis tools. Still the fastest way to capture raw data for tuning |
| `schematics/` | KiCad project for the custom PCB |

---

## Why there are two firmwares

The prototype firmware and the ESP-IDF firmware grew in parallel and diverged.

The **ESP-IDF tree** is architecturally what the PRD describes: tiered session
buffer in PSRAM, DSP chain with a mains notch and a median-frequency
estimator, a six-step calibration protocol, five host-side test suites. What
it does not have is any of the behaviour the demo actually shows — false-curl
rejection, fatigue indicators, auto-pause, guided pace, adaptive target.

The **prototype firmware** has all of that, and it is the only one that has
ever run on hardware with electrodes attached. So it is the one that ships,
retargeted to the S3. The ESP-IDF tree stays because its wire-format
definitions are the contract both halves are written against, and because its
design is the one the written documents describe.

They speak the same BLE protocol. That is what made the retarget tractable and
what lets the app, the HTML session viewer and `rehab_client.py` all talk to
either one.

---

## The three hosts, and when to use each

| Host | Good for | Needs |
| --- | --- | --- |
| **`app/`** (Flutter) | The demo. A session with a patient. Progress across visits | A phone |
| **HTML session viewer** (`../prototype/prototype demo final file/`) | Reading a recorded Serial Monitor log. Quick bench work next to a USB cable | Chrome or Edge |
| **`python/rehab_client.py`** | Capturing raw data for offline tuning — filter corners, thresholds, grading weights | A laptop and `pip install bleak` |

The app's Developer tab copies the sleeve's printed output to the clipboard in
exactly the viewer's input format, so a session recorded on the phone can be
read in the viewer afterwards.

---

## Getting from nothing to a working demo

1. **Flash.** `firmware-s3/README.md`. Arduino IDE, board `XIAO_ESP32S3`, and
   **Tools → PSRAM → OPI PSRAM** — the default is Disabled and the boot log
   then reads `PSRAM 0 kB`, which looks exactly like a dead memory chip.
2. **Check the sleeve alone.** Serial Monitor at 115200. Both IMUs should
   report started; if one does not, the message names its chip select, the
   clock it reached and which failure it saw.
3. **Check the signal.** Type `e` for the EMG test: 3 s relaxed, 3 s
   squeezing, then an SNR figure. Do this before trusting any effort
   percentage, and especially after the move from GPIO34 to GPIO4.
4. **Calibrate.** Type `c`, then `n` through the three steps, then `g`.
5. **Run the app.** `cd app && flutter pub get && flutter analyze &&
   flutter test`, then `flutter run`. Connect, and the Calibrate tab will walk
   the same three steps from the phone.

No sleeve to hand? The app's **demo mode** drives every screen with synthetic
frames and printed lines in the real wire formats.

---

## What has and has not been verified

Worth being precise about, because the two halves have been checked by very
different means.

**Firmware — compiled, not run.** Three configurations build with zero errors
and zero warnings at `--warnings all` (XIAO, XIAO with OPI PSRAM, and the
ESP32-S3 Dev Module); `firmware-s3/verify_build.sh` reproduces that from
nothing. It has never been flashed. The move from two I2C buses to one SPI bus
is the one change that is not behaviour-preserving by construction, so it is
the first thing to check on the bench.

**App — cross-checked, not compiled.** `flutter analyze` and `flutter test`
have not been run; there was no Dart toolchain where this was written. Instead
`app/tool/check_dart.py` verifies names, imports, members and constructor
arguments across all 41 files, and `app/tool/check_message_patterns.py`
verifies the printed-line parser against the firmware's own format strings.
Both run clean. **Run `flutter analyze && flutter test` before the demo.**

Measured, from the real builds:

| Board | Flash | Static RAM | Free for locals |
| --- | --- | --- | --- |
| XIAO ESP32S3 | 634 KB of 3.34 MB (18%) | 39.8 KB of 320 KB (12%) | 281 KB |
| XIAO, PSRAM OPI | 640 KB (19%) | 40.2 KB (12%) | 281 KB |
| ESP32-S3 Dev Module | 664 KB of 1.31 MB (50%) | 40.1 KB (12%) | 281 KB |

The XIAO is **not** a memory downgrade: its ESP32-S3R8 carries the same 512 KB
SRAM and 8 MB octal PSRAM as the DevKitC-1 N8R8. The firmware uses 12% of
static RAM and never touches PSRAM.

---

## Pin map at a glance

XIAO silkscreen in brackets. Full reasoning in `firmware-s3/rehabsense_s3/pins.h`.

| Function | GPIO |
| --- | --- |
| Both BMI270s, SPI | SCK **7** [D8], MISO **8** [D9], MOSI **9** [D10] |
| Upper-arm IMU chip select | **1** [D0] |
| Forearm IMU chip select | **2** [D1] |
| MyoWare 2.0 ENV | **4** [D3] — ADC1 |
| DRV2605L haptics, I2C | SDA **5** [D4], SCL **6** [D5] |
| Status LED | **21** (on-board, active LOW) |
| Start calibration | **0** (BOOT button) |

Free: GPIO3 [D2], held for the Phase 2 triceps channel, and the UART pins
GPIO43/44 [D6/D7].

Each BMI270 breakout needs its **ADR jumper fully open** — that is what
selects SPI — and its I2C pull-ups cut.

---

## Open items

| Open | Blocked on |
| --- | --- |
| First flash, and a real BLE connection | A bench |
| Both BMI270s answering over SPI | A bench. The whole SPI path is new |
| EMG levels on GPIO4 against the prototype's GPIO34 | Different ADC, different attenuation curve. Run `e` and compare |
| Elbow-angle accuracy | PRD gate: 5–10° against a goniometer at 0°, 45°, 90°, 135° |
| `flutter analyze` / `flutter test` | A machine with the Flutter SDK |
| Battery endurance | A two-hour run |
| Haptic feel on the final ERM | DRV2605L values carried over from a different motor mounting |
| Filter corners, thresholds, grading weights | Volunteer data. All settable over BLE at runtime, so tuning is a session rather than a rebuild |
