# RehabSense v5

The final prototype firmware: **pnh_step5_adaptive_target + Bluetooth LE**.

Everything from step 5 is unchanged: n-paced calibration, `g` to start, the rest countdown with buzzes, false-curl checks FC1–FC6, fatigue FT1–FT4, auto-pause AP1–AP2, guided pace GP1–GP3 and adaptive target AT1–AT4. The Serial Monitor works exactly as before.

What's new is Bluetooth, using the team protocol (EE542-RehabSense repo), so the session viewer, the app and `rehab_client.py` can all connect. Details in `BLE_PROTOCOL.md`.

**Update 28 Oct:** Bluetooth now queues printed lines and events instead of sending them in bursts, so none are lost on a busy link (before, most calibration lines and rep events could go missing). Only `ble.cpp` changed. Details in `BLE_PROTOCOL.md`.

**Update 28 Oct (2):** `imu.cpp` now tries each BMI270 at 0x68 and 0x69, falls back from 400 kHz to 100 kHz, and prints exactly why a sensor didn't start (nothing answering, or answering but the setup failed), instead of only "not found".

**Update 28 Oct (3):** the EMG test (`e`) keeps Bluetooth updated while it runs, so the viewer shows each step live; `i` also reports whether guided pace is on (`pace=1`).

## Install

1. Arduino IDE, board **ESP32 Dev Module** (esp32 core 2.x or 3.x).
2. Libraries (Library Manager): SparkFun BMI270 Arduino Library, Adafruit DRV2605 Library, **NimBLE-Arduino** by h2zero (version 2.x).
3. Tools → Partition Scheme → **Huge APP (3MB No OTA/1MB SPIFFS)** if the sketch doesn't fit.
4. Open `rehabsense_v5/rehabsense_v5.ino` (all files must be in that folder) and upload.
5. Serial Monitor at 115200. You should see `# Bluetooth advertising as "RehabSense"`.

## New files

| File | What it does |
|---|---|
| `ble.h` / `ble.cpp` | Bluetooth service: features at 50 Hz, IMU frames, status, events, settings, commands |
| `rs_proto.h` / `rs_proto.cpp` | Team byte formats (from rehabsense_v4, tested against `rehab_protocol.py`) |
| `rs_log.h` / `rs_log.cpp` | Everything printed goes to the Serial Monitor **and** to the Bluetooth Messages characteristic |

Changed: `calib.cpp` (can run by itself when started from the app, can be aborted, reports each step), `comms.cpp` (Bluetooth can send any typed command), `rep.cpp` (sends rep, partial, fatigue and set events), `imu.cpp` (keeps the raw samples for IMU frames), `sampler.cpp` (calls the Bluetooth tick), and every module prints through `Log` instead of `Serial`.

## Quick check after upload

1. Serial Monitor shows the header line `# RehabSense v5 (...)` and `# Bluetooth advertising as "RehabSense"`.
2. On a phone, nRF Connect → scan: **RehabSense** appears. Connect: service `A5B10001-…` with characteristics 0002–000A.
3. Open the session viewer in Chrome or Edge, **Connect sleeve**, pick RehabSense. Live angle and EMG appear; press **Calibrate** and the Serial Monitor shows the calibration starting, the same as typing `c`.
4. Do a few curls: the viewer shows each REP line, the chart, and the summary updating.
5. Close the viewer tab, then connect again: the sleeve is found again (advertising restarts after a disconnect).

Note: the protocol and log files are named `rs_proto.*` and `rs_log.*`. A sketch file called `wire.h` would replace the Arduino `Wire.h` library on a Mac (macOS doesn't tell upper and lower case apart in file names), so don't rename them back.
