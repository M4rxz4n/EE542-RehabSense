# RehabSense firmware

Two-channel sEMG + dual-IMU armband for home-based stroke rehabilitation.
Prototype firmware for the **ESP32-S3-DevKitC-1 v1.1 (N8R8)**.

Design doc: *RehabSense Firmware Design — Prototype v0.1*.

This is a **rough prototype**: the structure, the acquisition path, the DSP
chain and the repetition logic are real and tested; the orchestration layer has
`TODO(hardware)` markers everywhere a decision is still open. Nothing stubbed
is stubbed silently.

---

## Hardware

| Function | Part | Interface |
| --- | --- | --- |
| sEMG | MyoWare 2.0 × 2, RAW output | ADC1 GPIO4 / GPIO5 |
| IMU | SparkFun BMI270 Qwiic × 2 | SPI2, CS on GPIO10 / GPIO14 |
| Haptics | DRV2605L + Adafruit 1201 ERM | I2C at boot, PWM on GPIO6 |
| Status | On-board WS2812 | GPIO38 |

**Board jumpers, per BMI270 breakout:** ADR jumper *fully open* (this selects
SPI — cutting it to GND selects I2C 0x69 instead), I2C pull-ups cut.

Pins deliberately avoided: GPIO19–20 (USB), GPIO26–32 (flash), **GPIO33–37
(octal PSRAM on the N8R8)**.

---

## Build

```bash
# once, after cloning — pulls Bosch's BMI270 config image
python tools/fetch_bmi270_blob.py

idf.py set-target esp32s3
idf.py build flash monitor
```

Requires ESP-IDF 5.2 or newer. Managed components (`esp-dsp`, `led_strip`) are
pulled automatically by `idf.py reconfigure`.

### The one setting that matters

`sdkconfig.defaults` sets `CONFIG_SPIRAM_MODE_OCT=y`. **Do not lose this.** The
default is quad mode, in which an N8R8 module reports *zero* PSRAM — which
looks exactly like a hardware fault and sends you debugging the wrong thing.

A good boot log says:

```
I (xxx) esp_psram: Found 8MB PSRAM device
I (xxx) esp_psram: Speed: 80MHz
I (xxx) main: PSRAM: 8192 kB
```

---

## Tests

Both suites run on a laptop — no hardware, no ESP-IDF.

```bash
cd test && make          # repetition state machine + DSP verification
cd host && python3 test_protocol.py
```

`test/test_rep.c` compiles the **real** `rep_cycle.c` and `grading.c` against
small stubs and drives simulated angle traces through them. It covers the
demo's acceptance gate (ten deliberate reps counted as exactly ten), early hold
release, swinging through the band without holding, phase timeout, bad start
posture, compensation flagging, partial range, and the scale-free smoothness
property.

Two real bugs were found this way and are fixed in the shipped source:

1. **Smoothness rewarded slow movement.** Mean |Δvelocity| scales with speed,
   so an unnormalised metric gave a better score to anyone who simply moved
   slower — rewarding exactly the guarding behaviour this device exists to
   discourage. It is now normalised by the movement's own mean speed.
2. **Hold steadiness punished a deeper curl.** The steadiness window began the
   moment the angle crossed into the flexion band, so it included the tail of
   the ascent. A patient who curled *further* past the band edge accumulated
   more apparent wobble. The hold timer now requires the limb to have settled
   below `REP_HOLD_MAX_VEL_DPS` first, which also makes "hold for one second"
   mean a second of stillness rather than a second of anything.

`test/verify_dsp.py` ports the filter design and median-frequency estimator to
NumPy and checks them against known signals: −3 dB at both corners, 60 Hz notch
at 0.000 gain, MDF within 2 Hz on pure tones, and a monotonic MDF fall as the
spectrum shifts down (the fatigue signature).

---

## Host client

```bash
pip install bleak
cd host
python rehab_client.py --calibrate     # run the calibration protocol
python rehab_client.py --start         # begin a set, log everything
python rehab_client.py --haptic 1      # fire one pattern and exit
```

Logs land in `host/logs/session-<timestamp>/` as four CSVs (emg, imu, features,
events). Those logs are the input to offline tuning — filter coefficients,
thresholds and grading weights all need recorded data, which is why this tool
matters more than its live display.

For first bring-up, **nRF Connect** on a phone is faster than any client: it
shows the GATT table and raw notification bytes with no code at all.

---

## Layout

```
main/
  rehab_config.h        pin map + every tunable, single source of truth
  rehab_types.h         shared types; wire-format structs are packed
  main.c                task wiring, boot, self-test
  state_machine.c       OFF/BOOT/STANDBY/DONNING/CALIB/OPERATIONAL/FAULT
  calibration.c         four-phase protocol, donning check, NVS
  emg/
    emg_driver.h        acquisition HAL — two backends behind one interface
    emg_esp32_adc.c     internal ADC, continuous DMA      (prototype)
    emg_ads131m02.c     ADS131M02                          (STUB, final PCB)
    emg_dsp.c           biquad chain, envelope, median frequency
  imu/
    bmi270.c            SPI driver, config blob upload, self-test
    fusion.c            Madgwick + relative elbow angle
  haptic/
    drv2605l.c          I2C config at boot, PWM drive after
    patterns.c          the five-pattern vocabulary
  rep/
    rep_cycle.c         hold-gated repetition state machine
    grading.c           0–100 quality score
  ble/ble_service.c     NimBLE GATT — the interface contract
  storage/session_buffer.c   tier 1 SRAM + tier 2 PSRAM + backfill
  ui/status_led.c       WS2812 state palette
host/
  rehab_protocol.py     wire format, mirrors ble_service.h
  rehab_client.py       bleak client + CSV logger
test/                   host-side tests, no hardware needed
tools/fetch_bmi270_blob.py
```

---

## How a repetition works

```
WAIT_START -> EXTENDED_HOLD -> CONCENTRIC -> FLEXED_HOLD -> ECCENTRIC
                   ^                                            |
                   +--------------------------------------------+
```

The patient extends to their limit and holds for 1 s, curls up, holds at the
top for 1 s, then lowers. The repetition is counted **at the end of the top
hold**, and that is also when the haptic fires.

Holds require the limb to be *stationary*, not merely inside the band. Bands
are fractions of the patient's calibrated ROM, never absolute anatomical
angles — a patient who cannot reach full extension still gets a working
detector scaled to what they can do.

This is why there is no latency problem: every haptic lands at a moment the
patient is already still and expecting it. Budget from criterion to perceptible
motor movement is ~43 ms.

Compensation detected mid-repetition is latched and reported at the top hold,
where it selects the three-pulse pattern instead of the single clean pulse.
**One haptic per repetition, never two.**

Reps are counted and *then* graded. Nothing is silently discarded: a patient
who gets no credit for a hard-won compensated repetition learns that the device
is broken, not that their form needs work.

---

## Why no ML yet

Band crossings held for a fixed duration are a solved problem — deterministic,
debuggable, and every miscount traces to a threshold you can print. There is
also no training data: these thresholds are what *produce* the labelled
repetition boundaries any future model would need.

ML belongs in repetition *quality* scoring, once therapist-labelled data
exists. That is v2 — trained offline in Python, deployed as TFLite Micro only
if it beats the weights in `grading.c`.

The donning check needs no classifier either. Correct donning is directly
observable: gravity where it should be, both channels alive, and biceps
exceeding triceps during a test curl while the forearm rotates and the upper
arm stays still.

---

## Known gaps

| Gap | Where | Blocked on |
| --- | --- | --- |
| Battery monitoring | `main.c` housekeeping | Divider ratio; needs a oneshot read while continuous mode is paused |
| ADS131M02 backend | `emg/emg_ads131m02.c` | Custom PCB; interface is already in place |
| Trunk lean | `rep/rep_cycle.c` | Inferred from upper-arm attitude; a trunk IMU would make it a measurement |
| Wrist substitution | — | Undetectable with two IMUs; needs a third on the hand |
| Backfill request handling | `main.c` command dispatch | `session_buffer_read_emg()` works; the command path is not wired |
| Haptic auto-calibration values | `rehab_config.h` | ERM rated voltage and overdrive clamp from the Adafruit 1201 datasheet |

Filter corners, Madgwick beta, compensation thresholds and all grading weights
are starting points. Tune them against volunteer data in week 1 — the
acceptance gate for elbow angle is 5–10° against a goniometer at 0°, 45°, 90°
and 135°.
