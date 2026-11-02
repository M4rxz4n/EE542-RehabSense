# RehabSense S3 firmware

The shipping sleeve firmware: `rehabsense_v5` retargeted from the ESP32 Dev
Module to the **ESP32-S3**, for the **Seeed Studio XIAO ESP32S3**, developed
against the **ESP32-S3-DevKitC-1 v1.1 (N8R8)** that PRD v1.4 and the firmware
design doc name. One build serves both boards.

This is the firmware to flash. `../firmware/` is the ESP-IDF tree: the
PRD-shaped reference implementation, kept for its design, its host test suites
and its wire-format definitions, but it does not implement the step 1–5
behaviour (FC/FT/AP/GP/AT) that the prototype proved on hardware and that the
demo depends on.

---

## The short version

```
Arduino IDE · Board: XIAO_ESP32S3 · Tools > PSRAM: OPI PSRAM
Libraries: SparkFun BMI270, Adafruit DRV2605, NimBLE-Arduino 2.x
Open rehabsense_s3/rehabsense_s3.ino and upload. Serial Monitor at 115200.
```

Both boards have 8 MB of flash, so the default partition scheme fits with room
to spare. The **"Huge APP"** workaround the prototype needed on a 4 MB ESP32
is no longer required.

---

## Memory: there is nothing to re-cut

The concern that prompted this port was that the XIAO might have less RAM than
the DevKit. It does not. The XIAO ESP32S3 is an **ESP32-S3R8**: dual-core
Xtensa LX7, **512 KB SRAM, 8 MB octal PSRAM, 8 MB flash** — the same memory as
the DevKitC-1 N8R8. Measured, from the three configurations
`verify_build.sh` builds:

| Board | Flash used | Static RAM used | RAM left for locals |
| --- | --- | --- | --- |
| XIAO ESP32S3, PSRAM off | 634 KB of 3.34 MB (18%) | 39.8 KB of 320 KB (12%) | 281 KB |
| XIAO ESP32S3, PSRAM OPI | 640 KB of 3.34 MB (19%) | 40.2 KB of 320 KB (12%) | 281 KB |
| ESP32-S3 Dev Module | 664 KB of 1.31 MB (50%) | 40.1 KB of 320 KB (12%) | 281 KB |

The firmware's own state is a few kilobytes of filter and rep-counter
variables; the rest of that 40 KB is NimBLE's buffers. **PSRAM is not used and
is not needed** — it exists in the budget for the ESP-IDF firmware's tiered
session buffer, not for this one.

### One setting that will look like a hardware fault

The Arduino board definition for the XIAO defaults **PSRAM to Disabled**, and
the XIAO's PSRAM is **octal (OPI)**, not quad. Leave the menu alone and the
boot log says `PSRAM 0 kB`, which reads exactly like a dead memory chip.

**Tools → PSRAM → OPI PSRAM.**

This is the same trap `../firmware/README.md` documents for ESP-IDF, where the
equivalent is `CONFIG_SPIRAM_MODE_OCT=y`. Nothing here needs PSRAM, so getting
it wrong costs only the confusion — but the boot line prints the size, and the
confusion is the expensive part.

---

## Hardware

Pin labels in brackets are the XIAO's silkscreen.

| Function | Part | Interface | GPIO |
| --- | --- | --- | --- |
| Upper-arm IMU | SparkFun BMI270 | SPI, own chip select | CS **1** [D0] |
| Forearm IMU | SparkFun BMI270 | SPI, own chip select | CS **2** [D1] |
| — shared SPI bus | | SCK / MISO / MOSI | **7** [D8] / **8** [D9] / **9** [D10] |
| sEMG | MyoWare 2.0 × 1, ENV output | ADC1 | **4** [D3] |
| Haptics | DRV2605L + ERM, real-time mode | I2C at 0x5A | SDA **5** [D4], SCL **6** [D5] |
| Status | on-board user LED | GPIO, active LOW | **21** |
| Start calibration | on-board BOOT button | GPIO | **0** |

Free: GPIO3 [D2] (held for the Phase 2 triceps channel) and the two UART pins
GPIO43/44 [D6/D7].

**Per BMI270 breakout:** ADR jumper **fully open** — that is what selects SPI;
cutting it to GND selects I2C 0x69 instead. I2C pull-ups cut. The BMI270's SDO
is the bus's MISO and its SDI is the bus's MOSI.

### Why these pins and not the ESP-IDF firmware's

The XIAO breaks out eleven I/O: GPIO1–9 plus GPIO43/44. The ESP-IDF pin map
puts the IMU chip selects on GPIO10 and GPIO14 and the status LED on GPIO38,
and **none of those three leave the XIAO's module**. Every pin above is inside
the XIAO's header *and* a plain GPIO on the DevKitC-1, which is what lets one
sketch serve both.

Avoided on both boards: GPIO19–20 (USB), GPIO26–32 (flash), GPIO33–37 (octal
PSRAM — the XIAO's R8 is octal too, so these are not free there either).

The EMG pin is GPIO4 because that is the pin `../firmware/README.md` already
names, so the two firmwares agree about the wiring. ADC**1** matters: ADC2
shares hardware with the radio and reads garbage while Bluetooth is up.

---

## What changed from the prototype, and what did not

| File | Change |
| --- | --- |
| `pins.h` | New map for the S3 / XIAO; the reasoning is in the file |
| `imu.cpp` | Both BMI270s moved from two I2C buses to one SPI bus with a chip select each, as the PRD and the ESP-IDF firmware specify |
| `emg.cpp` | ADC resolution pinned at 12 bits and attenuation set for the S3's ADC1 |
| `sampler.cpp` | The 10 ms wait now yields to the idle task |
| `rehabsense_s3.ino` | I2C started here, the control loop pinned to core 1, and a status LED |

**Nothing else.** Every threshold, printed line, Bluetooth byte, event and
haptic pattern is the prototype's. The session viewer, the Flutter app and
`rehab_client.py` talk to this exactly as they talked to v5 — same service,
same characteristics (0002–0009 plus the **000A Messages** extension), same
opcodes (including **0x20 TEXT**). `rehabsense_s3/BLE_PROTOCOL.md` remains the
protocol reference and is unchanged.

### Both cores

**Core 1** runs the control task: the 100 Hz sample tick, sensor fusion, the
repetition state machine and haptic pulse timing — everything whose
correctness is a matter of timing. **Core 0** is left to NimBLE's host and
controller tasks, where the Arduino ESP32 core already pins them.

So a radio event can no longer stretch a haptic gap or delay a sample. That is
the open risk `../firmware/README.md` lists under *Haptic pattern timing
margin* ("the haptic task shares core 0 with NimBLE, so a radio event can
stretch a gap"), and this arrangement removes it by construction rather than
by measurement.

Nothing is shared across the two cores: the Bluetooth layer is still driven
from the control task, and NimBLE's own queues carry the data over. The one
consequence is that `sampler_tick`'s wait had to start yielding — it used to
spin inside Arduino's `loopTask`, which was harmless there but would starve
core 1's idle task and trip the task watchdog in a task of our own. It yields
at 1 ms granularity, and the shortest haptic step in the whole vocabulary is
40 ms, so nothing audible changes.

### Why SPI, and what it cost

The prototype ran each BMI270 on its own I2C bus, both at address 0x68, to
avoid needing the address jumper. SPI was chosen here instead because it is
what the PRD and the ESP-IDF firmware specify, it costs one pin fewer for two
sensors, and the 8 KB configuration blob each BMI270 wants at start-up uploads
in milliseconds rather than a fifth of a second.

The prototype's I2C bring-up diagnostics were the thing worth not losing — it
tried 0x68 and 0x69, fell back from 400 kHz to 100 kHz, and said exactly which
failure it saw. The SPI version keeps all of that shape: it steps 8 MHz → 1 MHz
→ 100 kHz, distinguishes "nothing answering on MISO" from "answered but the
config upload failed", names the actual GPIOs in the message, and points at the
ADR jumper. It also drives one deliberate chip-select edge before the first
transaction, because a BMI270 powers up listening on I2C and only commits to
SPI on that edge — without it a perfectly wired sensor can be reported missing
once, which is a long evening.

### Status LED

The DevKitC-1 has an addressable WS2812 and the ESP-IDF firmware uses colour to
show state. The XIAO has one plain LED, so state is carried by **rhythm**:

| Pattern | Meaning |
| --- | --- |
| Solid | counting reps |
| 1 Hz blink | waiting to calibrate |
| 4 Hz blink | calibrating |
| 5 Hz blink | fault — an IMU stopped answering |
| Double blink each 1.2 s | resting between sets |
| One blink each 2.4 s | auto-paused [AP1] |
| Slow 1.5 s on, 1.5 s off | session finished |

The app's own troubleshooting text tells people "the status LED should be lit",
so something had to drive it.

---

## Verifying a build

```bash
./verify_build.sh
```

Installs its own `arduino-cli`, the esp32 core and the four libraries under
`./.build-tools`, then compiles all three configurations with `--warnings all`.
It touches no installed IDE and no `~/.arduino15`; delete `.build-tools` to
start over. About 500 MB and a few minutes the first time, seconds after.

This replaces the prototype's verification method, which was to compile the
modules on a laptop against hand-written stubs of the NimBLE and sensor APIs.
Stubs were the best available at the time but they cannot catch what a board
change actually breaks — whether `analogSetPinAttenuation` still takes that
enum on an S3, whether `SPI.begin` has the four-argument form, whether the
sketch still fits the partition. This builds the real binary with the real
toolchain and prints what it costs.

Verified: esp32 core **3.3.12**, NimBLE-Arduino **2.5.2**, SparkFun BMI270
**1.0.3**, Adafruit DRV2605 **1.2.4**. All three configurations compile with no
errors and no warnings.

### Three things the first real compile found

None of these would have shown up against stubs.

1. **`NimBLEService::start()` is now a deprecated no-op.** The prototype's
   `BLE_PROTOCOL.md` records that v4's bug was never calling it — NimBLE 2.3.x
   leaves an unstarted service out of the GATT table, so a client connected and
   found no RehabSense service at all. From **2.5.0** services are started with
   the server and the call does nothing. The call is now behind a version
   guard, so it is still made on 2.3.x and skipped on 2.5+. Either version
   builds clean and behaves correctly, which matters because "NimBLE-Arduino
   2.x" from the Library Manager is whatever is current that day.
2. **Chained assignment through a `volatile` is deprecated** in the C++20 the
   esp32 core now compiles with. `subRaw = subEvents = subText = false` in the
   disconnect handler is three statements now.
3. **A dead variable** in `rep.cpp` (`restCuePlayed`, assigned nowhere, read
   nowhere) — harmless, but it was the only thing standing between the build
   and a clean `--warnings all`, which is worth keeping true.

---

## Still to do on the bench

Everything in this list needs the hardware; nothing here can settle it.

| Open | Why it needs a bench |
| --- | --- |
| First upload and a real BLE connection on the XIAO | Never flashed. The build is verified, the behaviour is not |
| Both BMI270s answering over SPI | The whole SPI path is new. The bring-up diagnostics were written to make this a five-minute job rather than an evening |
| EMG levels on GPIO4 vs the prototype's GPIO34 | Different ADC, different attenuation curve. Run the `e` signal test and compare the rest and squeeze numbers against a prototype log before trusting any effort percentage |
| Haptic feel on the final ERM | DRV2605L real-time values are carried over unchanged from a different motor mounting |
| Elbow-angle accuracy | PRD acceptance gate: 5–10° against a goniometer at 0°, 45°, 90°, 135° |
| Battery endurance | A two-hour run |

The SPI move is the one change that is not behaviour-preserving by
construction, so it is the one to check first.
