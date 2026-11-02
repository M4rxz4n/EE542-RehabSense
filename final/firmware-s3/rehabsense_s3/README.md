# rehabsense_s3

The sketch. **Build and hardware instructions are one level up, in
[`../README.md`](../README.md)** — board, the PSRAM setting that will otherwise
look like a hardware fault, the pin map and what is still open on the bench.

Protocol reference: [`BLE_PROTOCOL.md`](BLE_PROTOCOL.md), unchanged from the
prototype, because the wire format is unchanged.

```
Arduino IDE · Board: XIAO_ESP32S3 · Tools > PSRAM: OPI PSRAM
Open rehabsense_s3.ino and upload. Serial Monitor at 115200. Type ? for commands.
```

Keep the folder named `rehabsense_s3`: the Arduino IDE requires it to match
the `.ino`.

---

## What this firmware is

`pnh_step5_adaptive_target + Bluetooth LE`, retargeted to the ESP32-S3. The
feature set is the prototype's, unchanged: n-paced calibration, `g` to start,
the rest countdown with buzzes, false-curl checks FC1–FC6, fatigue FT1–FT4,
auto-pause AP1–AP2, guided pace GP1–GP3 and adaptive target AT1–AT4. The
Serial Monitor works exactly as before, and the Bluetooth layer speaks the team
protocol, so the session viewer, the Flutter app and `rehab_client.py` all
connect to it.

### History inherited from the prototype

- **v5** added Bluetooth over the step-5 firmware, using the team protocol.
- **28 Oct** — Bluetooth queues printed lines and events instead of sending
  them in bursts, so none are lost on a busy link. Before this, most
  calibration lines and rep events went missing. Only `ble.cpp` changed.
- **28 Oct (2)** — `imu.cpp` tried each BMI270 at 0x68 and 0x69, fell back from
  400 kHz to 100 kHz, and printed exactly why a sensor did not start.
  *Superseded:* the IMUs are on SPI now, and the same diagnostic shape was
  carried across — see `../README.md`.
- **28 Oct (3)** — the EMG test (`e`) keeps Bluetooth updated while it runs, so
  the viewer shows each step live; `i` also reports whether guided pace is on.

### Changed for the S3

`pins.h`, `imu.cpp` (I2C → SPI), `emg.cpp` (ADC setup), `sampler.cpp` (the
10 ms wait yields), and this folder's `.ino` (I2C started there, control loop
pinned to core 1, status LED). Nothing else.

---

## Files

| File | What it does |
|---|---|
| `pins.h` | Every pin number, and why each one |
| `params.*` | Therapist/host settings + fixed signal-processing constants |
| `quat.*` | Quaternion maths, Madgwick filter |
| `imu.*` | Both BMI270s over SPI, elbow angle and velocity |
| `emg.*` | MyoWare biceps channel |
| `emgtest.*` | EMG signal-quality test (command `e`) |
| `haptic.*` | The vibration patterns |
| `sampler.*` | The 100 Hz sampling tick |
| `calib.*` | Calibration steps |
| `rep.*` | Repetition state machine |
| `score.*` | Per-rep grading |
| `fatigue.*` | Muscle fatigue indicators |
| `autopause.*` | Pause when the arm stays still |
| `pace.*` | Guided pace beats |
| `progress.*` | Adaptive target saved in flash |
| `comms.*` | Serial Monitor commands and plotter output (Bluetooth too) |
| `rs_log.*` | Everything printed goes to Serial **and** to the BLE Messages characteristic |
| `rs_proto.*` | Team BLE byte formats |
| `ble.*` | Bluetooth LE service: features, events, status, settings, commands |

---

## Quick check after upload

1. Serial Monitor shows `# RehabSense S3 (...)`, a board line with the SRAM and
   PSRAM figures, then `# Bluetooth advertising as "RehabSense"`. The user LED
   lights immediately and blinks once a second while waiting to calibrate.
2. If the board line says `PSRAM 0 kB`: Tools → PSRAM → **OPI PSRAM**. Nothing
   here needs PSRAM, but that reading looks like a dead chip.
3. Both IMUs report started. If one does not, the message names the chip
   select, the clock it got to and which failure it saw — check that breakout's
   ADR jumper is fully open.
4. On a phone, nRF Connect → scan: **RehabSense** appears. Connect: service
   `A5B10001-…` with characteristics 0002–000A.
5. Open the session viewer in Chrome or Edge, or the Flutter app, **Connect**,
   pick RehabSense. Live angle and EMG appear; press **Calibrate** and the
   Serial Monitor shows calibration starting, the same as typing `c`.
6. Do a few curls: each REP line, the chart and the summary update.
7. Close the viewer, connect again: the sleeve is found (advertising restarts
   after a disconnect).

Note: the protocol and log files are named `rs_proto.*` and `rs_log.*`. A
sketch file called `wire.h` would shadow the Arduino `Wire.h` library on a Mac
(macOS does not distinguish upper and lower case in file names), so do not
rename them back.
