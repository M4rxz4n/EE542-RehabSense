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
| `firmware-s3/` | **The shipping firmware.** `rehabsense_v5` retargeted from the ESP32 Dev Module to the ESP32-S3, on either of two wirings, with two haptic motors. All of FC1–FC6, FT1–FT4, AP1–AP2, GP1–GP3, AT1–AT4 |
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

1. **Flash.** `firmware-s3/README.md`. Arduino IDE, board `ESP32S3 Dev Module`
   for the breadboard. On the XIAO it is `XIAO_ESP32S3` plus
   **Tools → PSRAM → OPI PSRAM** — the default is Disabled and the boot log
   then reads `PSRAM 0 kB`, which looks exactly like a dead memory chip.
2. **Check the sleeve alone.** Serial Monitor at 115200. The banner prints the
   bus map it was built for, which is how you catch a board flashed for the
   other wiring. Both IMUs should report started; if one does not, the message
   names its bus, the address it tried, the clock it reached and which failure
   it saw.
3. **Check both motors.** Type `hm`. It says which DRV2605Ls answered and
   where each cue plays. A sleeve running on one motor keeps working and feels
   subtly wrong, so this is worth doing before anything else is judged.
4. **Check the signal.** Type `e` for the EMG test: 3 s relaxed, 3 s
   squeezing, then an SNR figure. Do this before trusting any effort
   percentage, and especially after the move from GPIO34 to GPIO4.
5. **Calibrate.** Type `c`, then `n` through the three steps, then `g`.
6. **Run the app.** `cd app && flutter pub get && flutter analyze &&
   flutter test`, then `flutter run`. Connect, and the Calibrate tab will walk
   the same three steps from the phone.

No sleeve to hand? The app's **demo mode** drives every screen with synthetic
frames and printed lines in the real wire formats.

---

## What has and has not been verified

Worth being precise about, because the two halves have been checked by very
different means.

**Firmware — compiled, not run.** Seven configurations build with zero errors
and zero warnings at `--warnings all` — two boards × two sensor buses × two
haptic topologies, minus the crossings nobody will build;
`firmware-s3/verify_build.sh` reproduces that from nothing. The default build
is the PCB's architecture. It has never been flashed. The second haptic channel is the
one piece of behaviour that is new rather than ported, so it is the first thing
to check on the bench: `hm` on the console says which DRV2605Ls answered.

**App — cross-checked, not compiled.** `flutter analyze` and `flutter test`
have not been run; there was no Dart toolchain where this was written. Instead
`app/tool/check_dart.py` verifies names, imports, members and constructor
arguments across all 41 files, and `app/tool/check_message_patterns.py`
verifies the printed-line parser against the firmware's own format strings.
Both run clean. **Run `flutter analyze && flutter test` before the demo.**

Measured, from the real builds:

| Build | Flash used | Static RAM used, of 327,680 B | Free for locals |
| --- | --- | --- | --- |
| S3 Dev Module, I2C x2 — **the breadboard** | 664,105 B (50%) | 40,092 B (12%) | 287,588 B |
| S3 Dev Module, SPI + TCA9543A — **the PCB** | 666,401 B (50%) | 40,092 B (12%) | 287,588 B |
| XIAO ESP32S3, I2C x2 | 634,116 B (18%) | 39,772 B (12%) | 287,908 B |
| XIAO, I2C x2, PSRAM OPI | 639,386 B (19%) | 40,248 B (12%) | 287,432 B |
| XIAO ESP32S3, SPI | 636,412 B (19%) | 39,772 B (12%) | 287,908 B |

The other two `verify_build.sh` compiles — the crossed haptic topologies — land
within 500 B of these. Static RAM does not move at all.

The XIAO is **not** a memory downgrade: its ESP32-S3R8 carries the same 512 KB
SRAM and 8 MB octal PSRAM as the DevKitC-1 N8R8. The firmware uses 12% of
static RAM and never touches PSRAM.

---

## Two wirings, one firmware

The PCB is the target; the breadboard is a bring-up configuration kept
alongside it. `pins.h` chooses at compile time and nothing above `imu.cpp`
knows which it got.

| | Custom PCB — the default | Breadboard |
| --- | --- | --- |
| Board | XIAO ESP32-S3 on a carrier | ESP32-S3-DevKitC-1 |
| IMUs | **one SPI bus**, a chip select each | **two I2C buses**, one each |
| Haptics | one bus + **TCA9543A** switch | two I2C buses |
| EMG | **ADS131M02** on SPI — *not yet driven* | MyoWare 2.0 on ADC1 |
| Build with | nothing | `-DRS_IMU_BUS=RS_IMU_I2C` |
| Source | `schematics/` | the wiring diagram of 1 Nov |
| Pin numbers | **provisional** — see below | from the diagram |

Both agree on two DRV2605Ls and two ERMs. The haptic topology follows the IMU
bus, so one flag selects the whole architecture.

Two I2C buses is not a preference: both BMI270 breakouts sit at 0x68 and the
DRV2605L's 0x5A has no address strap, so each bus can hold exactly one of
each.

The two motors also reach the MCU differently, and for the same reason: `0x5A`
is fixed on a DRV2605L, so two cannot answer on one bus. The breadboard gives
each its own bus. The PCB puts both behind a **TCA9543A** 2-channel I2C switch
— `haptic.kicad_sch` has one `TCA9543APWR`, two `DRV2605LDGST`s and the nets
`SDA_H1` / `SCL_H1` / `SDA_H2`, while `mcu.kicad_sch` brings out a single
`SDA` / `SCL` pair. `RS_HAPTIC_MUX` selects, and follows the IMU bus by
default, so neither board needs its own firmware.

| | Breadboard | Custom PCB |
| --- | --- | --- |
| Two DRV2605Ls reached by | two I2C buses | one bus + TCA9543A switch |
| `RS_HAPTIC_MUX` | 0 (default with I2C IMUs) | 1 (default with SPI IMUs) |

Still unmodelled, and still provisional: the SPI mode's **GPIO numbers** (the
schematic names nets, not readably pins), the **TCA9543A's strapped address**
(`haptic_begin()` scans 0x70–0x73 and reports which answered), and the PCB's
**external SPI ADC** (`CS_ADC`, `DRDY_ADC`), which would replace the MyoWare
going straight into ADC1. `mcu.kicad_sch` also uses the `XIAO_ESP32_S3`
symbol, so the PCB is a XIAO carrier board rather than a DevKitC. The I2C
mode is the one that matches wiring that exists.

## Pin map at a glance

Full reasoning in `firmware-s3/rehabsense_s3/pins.h`.

**ESP32-S3-DevKitC-1 — the breadboard, as drawn**

| Function | GPIO |
| --- | --- |
| I2C bus 0: upper-arm BMI270 `0x68` + DRV2605L `0x5A` → ERM M1 | SDA **8**, SCL **9** |
| I2C bus 1: forearm BMI270 `0x68` + DRV2605L `0x5A` → ERM M2 | SDA **17**, SCL **18** |
| MyoWare 2.0 ENV | **4** — ADC1_CH3 |
| Status LED, WS2812 | **48** (**38** on v1.1 — build `-DRS_LED_PIN=38`) |
| Start calibration | **0** (BOOT button) |
| Spare | **5** (MyoWare RAW), **6** |

One 4.7 kΩ pull-up per line per bus, to 3V3. Do not wire GPIO 0/3/45/46
(strapping), 19/20 (USB), 26–32 (flash), 33–37 (octal PSRAM), 43/44 (UART).

**XIAO ESP32S3 — the shipping sleeve.** Same build; only pins that leave the
module. Silkscreen in brackets.

| Function | GPIO |
| --- | --- |
| I2C bus 0 | SDA **5** [D4], SCL **6** [D5] |
| I2C bus 1 | SDA **8** [D9], SCL **9** [D10] |
| MyoWare 2.0 ENV | **4** [D3] |
| Status LED | **21** (plain, active LOW — the XIAO has no WS2812) |

Free on the XIAO: GPIO3 [D2] for the Phase 2 triceps channel, and GPIO43/44
[D6/D7].

On the PCB's SPI wiring each BMI270 breakout needs its **ADR jumper fully
open** — that is what selects SPI — and its I2C pull-ups cut. On the
breadboard the jumpers stay closed at 0x68 and the pull-ups stay.

---

## Open items

| Open | Blocked on |
| --- | --- |
| First flash, and a real BLE connection | A bench |
| Both BMI270s answering over SPI | A bench |
| **Any EMG at all on the PCB** | The ADS131M02 driver, which needs four numbers off the board. `ADC1` is unconnected there |
| Both DRV2605Ls answering — type `hm` | A bench. Two motors is new scope, not a port |
| Whether the pace beat belongs on the forearm alone | Someone wearing it. One column of the table in `haptic.cpp` |
| Whether the WS2812 is on GPIO48 or GPIO38 | Which DevKitC-1 revision is on the desk |
| The PCB's real pin assignment, and its external SPI ADC | Reading `schematics/`. The SPI mode's GPIO numbers are provisional and that board also moves the EMG off ADC1 |
| The TCA9543A path, and its strapped address | Never run. `haptic_begin()` scans 0x70–0x73 and says which answered |
| EMG levels on GPIO4 against the prototype's GPIO34 | Different ADC, different attenuation curve. Run `e` and compare |
| Elbow-angle accuracy | PRD gate: 5–10° against a goniometer at 0°, 45°, 90°, 135° |
| `flutter analyze` / `flutter test` | A machine with the Flutter SDK |
| Battery endurance | A two-hour run |
| Haptic feel on the final ERM | DRV2605L values carried over from a different motor mounting |
| Filter corners, thresholds, grading weights | Volunteer data. All settable over BLE at runtime, so tuning is a session rather than a rebuild |
