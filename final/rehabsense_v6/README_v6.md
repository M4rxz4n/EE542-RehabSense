# RehabSense v6 (15 Nov 2026)

v5 moved to the ESP32-S3-DevKitC-1, with everything digital on I2C and two haptic motors.
Behaviour is otherwise identical to v5.

**This folder holds only the four files that changed.** To build v6:

1. Copy the whole `rehabsense_v5` folder and rename the copy `rehabsense_v6`.
2. In the copy, delete `rehabsense_v5.ino`.
3. Put these four files in, replacing the old ones: `rehabsense_v6.ino`, `pins.h`, `haptic.h`, `haptic.cpp`.
4. Arduino IDE: board **ESP32S3 Dev Module**, UART port, **USB CDC On Boot: Disabled**,
   partition scheme Huge APP. Libraries as in v5.

## What changed

| File | Change |
|---|---|
| `pins.h` | I2C bus 0 on GPIO8/9, bus 1 on GPIO17/18, biceps envelope on GPIO4. Custom-board pins reserved (GPIO5, 6, 7, 15, 16, 21). |
| `haptic.h`, `haptic.cpp` | Second DRV2605L on Wire1. Both motors play every pattern together. Driver #2 is optional: if it isn't found, start-up continues with one motor. |
| `rehabsense_v6.ino` | Starts both haptic drivers, reports whether #2 was found, updated wiring notes. |

## Expected at start-up (Serial Monitor, 115200)

    # RehabSense v6 (...)
    # Haptic driver #2 found on GPIO17/18: both motors active
    # Upper IMU, forearm IMU and haptic driver OK

## EMG input

GPIO4 reads the biceps envelope. MyoWare 2.0 ENV and the custom board's ENV_A use the
same pin, so swapping between them needs no firmware change. v6 does not read the
custom board's RAW outputs or the sigma-delta bit streams yet.

## Not yet tested

Written on 15 Nov without the hardware. `haptic.cpp` and `pins.h` pass a syntax check;
the full sketch has not been compiled for the S3 or run on the board. First upload: check
the three start-up lines above, then `h` commands for both motors and `e` for the EMG test.
