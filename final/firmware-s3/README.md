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
the DevKitC-1 N8R8. Measured, from the seven configurations
`verify_build.sh` builds:

Figures are the compiler's own, in bytes, so they can be checked against a
rebuild rather than against a rounding:

| Build | Flash used | of | Static RAM | of 327,680 | left for locals |
| --- | --- | --- | --- | --- | --- |
| **XIAO, SPI + TCA9543A — the default** | 636,552 | 3,342,336 (19%) | 39,772 | 12% | 287,908 |
| XIAO, SPI + TCA9543A, PSRAM OPI | 641,810 | 3,342,336 (19%) | 40,248 | 12% | 287,432 |
| S3 Dev Module, SPI + TCA9543A | 666,541 | 1,310,720 (50%) | 40,092 | 12% | 287,588 |
| XIAO, I2C x2 — the breadboard | 634,252 | 3,342,336 (18%) | 39,772 | 12% | 287,908 |
| S3 Dev Module, I2C x2 — the breadboard | 664,261 | 1,310,720 (50%) | 40,092 | 12% | 287,588 |
| S3 Dev Module, I2C x2 + TCA9543A | 664,765 | 1,310,720 (50%) | 40,092 | 12% | 287,588 |
| S3 Dev Module, SPI + two haptic buses | 666,057 | 1,310,720 (50%) | 40,092 | 12% | 287,588 |

Static RAM is identical across every configuration on a given board: a second
DRV2605L driver object is a handful of bytes, `Wire1` already existed in the
core, and the TCA9543A path adds two bytes of state. The whole spread, across
all seven, is 2,289 bytes of flash and nothing of consequence in RAM.

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

Two boards and two sensor wirings are live at once, so `pins.h` selects rather
than assumes. The defaults are the breadboard, because that is what exists.

| | chosen by | what it is |
| --- | --- | --- |
| **XIAO** | `ARDUINO_XIAO_ESP32S3`, from the Seeed board variant | the sleeve, and the module the PCB carries |
| **DevKitC-1** | anything else | the breadboard, and the board the PRD names |
| **SPI × 1** | **the default** | the custom PCB (`CS_IMU1`, `CS_IMU2`, `SCK`, `MISO`, `MOSI`) — pin numbers still provisional |
| **I2C × 2** | `-DRS_IMU_BUS=RS_IMU_I2C` | the breadboard, as the wiring diagram draws it |
| **TCA9543A switch** | the default with SPI IMUs, or `-DRS_HAPTIC_MUX=1` | the custom PCB |
| **2 haptic buses** | the default with I2C IMUs | the breadboard |

The haptic topology follows the IMU bus, so **one flag selects the whole
architecture**. The default build is the PCB.

### The EMG path is not a difference of bus

Everything above differs between the two wirings by which bus a part sits on.
The EMG channel differs completely, and this is the one thing the firmware does
not yet do.

The prototype and the breadboard read a **MyoWare 2.0** module's envelope on
**ADC1**. The PCB has no MyoWare. It has its own analog front end —
`emg.kicad_sch`: two **TL074** quad op-amps, two **3.5 mm electrode jacks**,
gain and filter jumpers — feeding an **ADS131M02**, a two-channel 24-bit
delta-sigma ADC on the SPI bus, clocked by an **LTC6903** programmable
oscillator (`adc.kicad_sch`). Two channels, so the PRD's Phase 2 triceps
channel is already on the board.

`RS_EMG_SRC` in `pins.h` is the seam. `RS_EMG_ADC1` is the default and is what
builds; `RS_EMG_ADS131M02` **fails the build on purpose**, listing what it
needs: the ADC's CS and DRDY pins, the rate the LTC6903 is programmed to, and
the front end's gain and oversampling ratio. None of those are readable from
net names. Every effort percentage, fatigue indicator and rep decision in the
system comes from this one signal, so a guessed gain does not produce a bad
reading — it produces a confident wrong answer.

A PCB flashed with the default reads an unconnected pin, which looks like a
patient who is not trying. The boot banner names the EMG source for that
reason.

### ESP32-S3-DevKitC-1 — the breadboard

| Function | Part | Interface | GPIO |
| --- | --- | --- | --- |
| Upper-arm IMU | SparkFun BMI270 | I2C bus 0 at `0x68` | SDA **8**, SCL **9** |
| Upper-arm haptics | DRV2605L + ERM M1 | I2C bus 0 at `0x5A` | — same bus |
| Forearm IMU | SparkFun BMI270 | I2C bus 1 at `0x68` | SDA **17**, SCL **18** |
| Forearm haptics | DRV2605L + ERM M2 | I2C bus 1 at `0x5A` | — same bus |
| sEMG | MyoWare 2.0 × 1, ENV output | ADC1_CH3 | **4** |
| Status | on-board WS2812 | `rgbLedWrite` | **48**, or **38** on v1.1 |
| Start calibration | on-board BOOT button | GPIO | **0** |

Spare: GPIO**5** (where the diagram suggests MyoWare RAW could go) and
GPIO**6**. One 4.7 kΩ pull-up per line per bus, to 3V3.

**Why two buses, and not one.** Not a preference. Both BMI270 breakouts sit at
`0x68` and the DRV2605L's `0x5A` has no address strap, so a single bus can hold
exactly one of each. Pairing them by limb — upper IMU with upper motor — is
also the lead dressing that makes sense on a sleeve.

**If the LED stays dark,** build with `-DRS_LED_PIN=38`. DevKitC-1 v1.1 moved
the WS2812 there and nothing else about the board differs.

### XIAO ESP32S3 — the shipping sleeve

Same build, no edits. Only the pins that leave the module. Silkscreen in
brackets.

| Function | GPIO |
| --- | --- |
| I2C bus 0 | SDA **5** [D4], SCL **6** [D5] |
| I2C bus 1 | SDA **8** [D9], SCL **9** [D10] |
| sEMG | **4** [D3] |
| Status | **21**, plain and active LOW — the XIAO has no WS2812 |

Free on the XIAO: GPIO3 [D2] (held for the Phase 2 triceps channel) and the
two UART pins GPIO43/44 [D6/D7].

### The PCB's SPI wiring

| Function | Net | GPIO (provisional) |
| --- | --- | --- |
| Shared bus | `SCK` / `MISO` / `MOSI` | **7** / **8** / **9** |
| Upper-arm IMU chip select | `CS_IMU1` | **1** |
| Forearm IMU chip select | `CS_IMU2` | **2** |
| Haptic bus (both motors, via the switch) | `SDA` / `SCL` | SDA **15**, SCL **16** (DevKitC) / **5**, **6** (XIAO) |

The haptic pair moves off GPIO8/9 in this mode: there it would sit on top of
MISO and MOSI, which compiles perfectly and does not work.

**Per BMI270 breakout, on this wiring only:** ADR jumper **fully open** — that
is what selects SPI; cutting it to GND selects I2C `0x69` instead. I2C pull-ups
cut. The BMI270's SDO is the bus's MISO and its SDI is the bus's MOSI. On the
breadboard the jumpers stay closed at `0x68` and the pull-ups stay.

**These GPIO numbers are provisional.** The schematic names the nets but not,
readably, its pin assignment. One thing it carries that the firmware still
does not model: an external **SPI ADC** (`CS_ADC`, `DRDY_ADC`), which would
replace the MyoWare going straight into ADC1. Read that part of the board
before flashing this mode.

On a XIAO this wiring is the tightest of the four: ten of the eleven header
pins, which it reaches only by using D6/D7 as plain GPIOs. That is fine here —
the console is USB CDC, not UART — and D2 is left over.

### Why these pins and not the ESP-IDF firmware's

The XIAO breaks out eleven I/O: GPIO1–9 plus GPIO43/44. The ESP-IDF pin map
puts the IMU chip selects on GPIO10 and GPIO14 and the status LED on GPIO38,
and **none of those three leave the XIAO's module**. Every XIAO pin above is
inside its header *and* a plain GPIO on the DevKitC-1, which is what lets one
sketch serve both.

Avoided on both boards: GPIO19–20 (USB), GPIO26–32 (flash), GPIO33–37 (octal
PSRAM — the XIAO's R8 is octal too, so these are not free there either), and
GPIO45/46 (strapping).

The EMG pin is GPIO4 because that is the pin `../firmware/README.md`, the
wiring diagram and the PCB all name, so every description of this system
agrees about it. ADC**1** matters: ADC2 shares hardware with the radio and
reads garbage while Bluetooth is up.

---

## What changed from the prototype, and what did not

| File | Change |
| --- | --- |
| `pins.h` | New map for the S3, selecting board and IMU bus at compile time; the reasoning is in the file |
| `imu.cpp` | Both wirings — two I2C buses or one SPI bus — behind one `imu_begin()` / `imu_update()` contract |
| `haptic.cpp` | Two DRV2605Ls and two ERMs, one per bus, with a motor target per cue. One motor still works and says so |
| `emg.cpp` | ADC resolution pinned at 12 bits and attenuation set for the S3's ADC1 |
| `sampler.cpp` | The 10 ms wait now yields to the idle task |
| `rehabsense_s3.ino` | Both I2C buses started here, a colour status LED, and the control loop pinned to core 1 |

**Almost nothing else.** Every threshold, printed line, Bluetooth byte and
event is the prototype's. The session viewer, the Flutter app and
`rehab_client.py` talk to this exactly as they talked to v5 — same service,
same characteristics (0002–0009 plus the **000A Messages** extension), same
opcodes (including **0x20 TEXT**). `rehabsense_s3/BLE_PROTOCOL.md` remains the
protocol reference.

Two things are genuinely new rather than ported, and both are listed under
open items:

- **`C_HAPTIC_TEST` takes an optional second byte**, the motor. Absent or zero
  means "wherever this cue normally plays", which is what every older host
  sends, so the one-byte form behaves exactly as before.
- **The guided-pace beat plays on the forearm motor alone** rather than
  everywhere. That is the whole reason the hardware grew a second motor — the
  forearm is the part the beat is asking to move — but it changes what a
  wearer feels, and it is one column of the `PATS` table in `haptic.cpp` if it
  turns out to be wrong.

Console additions: **`hm`** reports which DRV2605Ls answered and where each cue
plays, and a trailing `u`, `f` or `b` on any `h<n>` forces a motor — `h1f`
plays the rep click on the forearm.

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

### Why both buses are kept

The prototype ran each BMI270 on its own I2C bus, both at `0x68`. The port to
the S3 moved them to one SPI bus, because that is what the PRD, the ESP-IDF
firmware and the PCB schematic all specify, and because the 8 KB configuration
blob each BMI270 wants at start-up uploads in milliseconds rather than a fifth
of a second. Then the breadboard arrived wired for I2C.

Both are real hardware, so both are in the tree, selected by one `#if` in
`pins.h`. Throwing either away would mean the firmware works on one of the two
boards this project actually has.

What matters more than the bus is that the **bring-up diagnostics** are the
same on both paths, because that is the part that turns a wiring mistake into
a five-minute fix. Each retries forever, steps the clock down before blaming
the wiring, and names the pin, the speed and the failure mode:

- **I2C** tries `0x68` then `0x69`, alternates 400 kHz and 100 kHz, and
  distinguishes "nothing answers at either address" from "answers but would not
  start". When one IMU fails and the other works it says so, and points at the
  DRV2605L on the same bus as the cross-check: if the motor driver came up, the
  bus wiring is fine and it is that sensor's power or its stub.
- **SPI** steps 8 MHz → 1 MHz → 100 kHz, distinguishes "nothing answering on
  MISO" from "answered but the config upload failed", and points at the ADR
  jumper. It also drives one deliberate chip-select edge before the first
  transaction, because a BMI270 powers up listening on I2C and only commits to
  SPI on that edge — without it a perfectly wired sensor can be reported
  missing once, which is a long evening.

### Two motors

One pattern plays at a time, on one or both motors. The second motor adds
*where* a cue is felt, not a second thing happening at once — so the existing
priority and queue behaviour is untouched.

Everything plays on both motors, which is what the single-motor sleeve felt
like, **except the guided-pace beat**: up, hold and down play on the forearm
alone, the part of the arm the beat is asking to move. The routing is one
column of the `PATS` table in `haptic.cpp`.

If only one DRV2605L answers, every cue plays on the one that did and the
console says which is missing and where to look. The sleeve keeps working; it
just stops being directional. `hm` reports this at any time, and the app's
Developer tab shows it.

### Two motors on one address, two ways

`0x5A` is fixed on a DRV2605L with no address strap, so two of them cannot
answer on one bus. The breadboard and the PCB solve that differently, and
`RS_HAPTIC_MUX` in `pins.h` selects:

| | `RS_HAPTIC_MUX 0` | `RS_HAPTIC_MUX 1` |
| --- | --- | --- |
| Topology | two MCU I2C buses, one driver each | one bus into a **TCA9543A** 2-channel I2C switch |
| Where | the breadboard | the custom PCB |
| Default | when the IMUs are on I2C | when the IMUs are on SPI |

The PCB's arrangement is not a guess: `haptic.kicad_sch` contains one
`TCA9543APWR`, two `DRV2605LDGST`s, and the nets `SDA_H1` / `SCL_H1` /
`SDA_H2` — a switch with one driver downstream of each channel, while
`mcu.kicad_sch` brings out a single `SDA` / `SCL` pair.

In mux mode every driver access is preceded by a channel select, cached so an
unchanged selection costs nothing. The switch's own address depends on its
A1/A0 strapping, which the schematic's net names do not reveal, so
`haptic_begin()` scans `0x70`–`0x73` and prints which it found; build with
`-DHAPTIC_MUX_ADDR=0x7n` to skip the scan once it is known.

`mcu.kicad_sch` also uses the symbol `XIAO_ESP32_S3`, so the PCB is a **XIAO
carrier board** rather than a DevKitC — which is why that combination is one of
the configurations `verify_build.sh` compiles.

### Status LED

Two kinds of LED, one vocabulary. The DevKitC-1 has a WS2812 and no plain LED;
the XIAO has a plain active-LOW LED and no WS2812. `pins.h` compiles in one.

**Rhythm** carries the state on both — that is what the plain LED has, and
colour alone is no use to a red-green colour-blind user. Colour is added on top
where there is colour to add, which is how the ESP-IDF firmware uses the same
part.

| Pattern | Colour | Meaning |
| --- | --- | --- |
| Solid | green | counting reps |
| 1 Hz blink | blue | waiting to calibrate |
| 4 Hz blink | amber | calibrating |
| 5 Hz blink | red | fault — an IMU stopped answering |
| Double blink each 1.2 s | amber | resting between sets |
| One blink each 2.4 s | magenta | auto-paused [AP1] |
| Slow 1.5 s on, 1.5 s off | cyan | session finished |

The app's own troubleshooting text tells people "the status LED should be lit",
so something had to drive it.

The WS2812 is written only on a change and scaled to about a tenth of full
brightness: a WS2812 at full white draws roughly 60 mA, which is a real
fraction of the battery budget and unpleasant to look at on a bench.

---

## Verifying a build

```bash
./verify_build.sh
```

Installs its own `arduino-cli`, the esp32 core and the four libraries under
`./.build-tools`, then compiles all seven configurations with `--warnings all`.
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
**1.0.3**, Adafruit DRV2605 **1.2.4**. All seven configurations compile with no
errors and no warnings.

Compiling all seven is the point, not thoroughness for its own sake: `pins.h`
chooses between two boards, two sensor buses and two haptic topologies, and a
`#if` that only ever takes one branch is a branch nobody has checked.

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
| Both BMI270s answering over SPI | Never run on this wiring. The bring-up diagnostics were written to make this a five-minute job rather than an evening |
| Both DRV2605Ls answering | Two motors is new scope, not a port. Type `hm`: it names the missing one and its bus |
| Whether the pace beat belongs on the forearm alone | The one change to what a wearer feels. Needs someone wearing it, and it is one column of the `PATS` table |
| Whether the WS2812 is on GPIO48 or GPIO38 | Depends on the DevKitC-1 revision. If the LED stays dark, build `-DRS_LED_PIN=38` |
| The PCB's real pin assignment | The SPI numbers here are provisional, and the board also has an external SPI ADC the firmware does not model |
| The TCA9543A's strapped address | `haptic_begin()` scans 0x70–0x73 and says which answered. The mux path has never run |
| **The whole EMG path on the PCB** | Four numbers off the board (see above). Until then the PCB has no EMG, which is most of what the sleeve measures |
| EMG levels on GPIO4 vs the prototype's GPIO34 | Different ADC, different attenuation curve. Run the `e` signal test and compare the rest and squeeze numbers against a prototype log before trusting any effort percentage |
| Haptic feel on the final ERM | DRV2605L real-time values are carried over unchanged from a different motor mounting |
| Elbow-angle accuracy | PRD acceptance gate: 5–10° against a goniometer at 0°, 45°, 90°, 135° |
| Battery endurance | A two-hour run |

Two things to check first, in this order. **`hm`**, then `h1u` and `h1f`, to
feel that each motor is where the firmware thinks it is: the second haptic
channel is new rather than ported, and so is the switch in front of it. Then
the EMG — on the PCB there is nothing behind `ADC1`, so run `e` and expect it
to fail, which is the correct result until the ADS131M02 driver exists.
