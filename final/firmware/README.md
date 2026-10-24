# RehabSense firmware

Single-channel sEMG + dual-IMU armband for home-based stroke rehabilitation.
Prototype firmware for the **ESP32-S3-DevKitC-1 v1.1 (N8R8)**.

Design doc: *RehabSense Firmware Design v2.0*, built to **PRD v1.4**.

Everything PRD v1.4 specifies is implemented and exercised by five host-side
test suites. What remains needs a bench, volunteer data, or a team decision —
see **Known gaps** at the bottom. Nothing stubbed is stubbed silently.

**Phase 1 sensing:** one MyoWare 2.0 on the biceps — two electrodes on the
muscle belly ~20 mm apart plus one reference on the bony elbow landmark, three
in all. The custom PCB's two-channel front end is reached by setting
`EMG_N_CHANNELS` to 2; every path that needs a second channel is guarded on
that constant rather than deleted.

---

## Hardware

| Function | Part | Interface |
| --- | --- | --- |
| sEMG | MyoWare 2.0 × 1, RAW output | ADC1 GPIO4 (GPIO5 reserved for Phase 2) |
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
cd test && ./run_tests.sh     # repetition cycle (16 scenarios) + DSP
cd host && ./run_tests.sh     # wire format, grading mirror, simulated session
```

`test/test_rep.c` compiles the **real** `rep_cycle.c`, `grading.c` and
`activation.c` against small stubs and drives simulated angle and EMG traces
through them. Sixteen scenarios, including the ones that would otherwise fail
silently:

- ten deliberate repetitions counted as exactly ten (the demo's acceptance gate)
- **a passively swung arm counts nothing and starts nothing** — full range,
  correct posture, correct timing, agonist silent
- the gate needs muscle *and* movement; neither alone arms a repetition
- a long hold at the top counts nothing: the count follows the **return**
- set completion fires exactly once, at targets of 5 and 20
- tempo measured and scored; a 9 s repetition scores below a 2.4 s one
- smoothness counts pushes and does not reward slowness
- a shoulder hike does not *also* register as trunk lean
- host configuration takes effect mid-session
- the activation detector does not chatter at its own boundary

Three real bugs were found this way and are fixed in the shipped source:

1. **Smoothness rewarded slow movement.** Mean |Δvelocity| scales with speed,
   so an unnormalised metric gave a better score to anyone who simply moved
   slower — rewarding exactly the guarding behaviour this device exists to
   discourage. Smoothness is now a velocity-peak count, which is scale-free.
2. **Hold steadiness punished a deeper curl.** The steadiness window began the
   moment the angle crossed into the band, so it included the tail of the
   ascent. The hold timer now requires the limb to have settled first, which
   also makes "hold for one second" mean a second of stillness.
3. **Trunk lean and shoulder hike double-counted.** Both tested upper-arm
   deviation, at 10° and 15°, so any deviation past 15° with a slow elbow set
   both flags and cost −35 instead of −20. Trunk lean is now true common-mode
   rotation of both IMUs, which cannot collide with a shoulder hike.

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
  calibration.c         six-step protocol, donning check, NVS
  config.c              runtime configuration over BLE (TLV), NVS
  rehab_time.c          host epoch offset; the device clock is never adjusted
  emg/
    emg_driver.h        acquisition HAL — two backends behind one interface
    emg_esp32_adc.c     internal ADC, continuous DMA      (prototype)
    emg_ads131m02.c     ADS131M02                          (STUB, final PCB)
    emg_dsp.c           biquad chain, envelope, median frequency, mains
    activation.c        muscle-on detection, 3σ/2σ with hysteresis
  imu/
    bmi270.c            SPI driver, config blob upload, self-test
    fusion.c            Madgwick + relative elbow angle
  haptic/
    drv2605l.c          I2C config at boot, PWM drive after
    patterns.c          the seven-pattern vocabulary, priority, preemption
  rep/
    rep_cycle.c         repetition cycle, gated on agonist activation
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
READY -> CONCENTRIC -> PEAK -> ECCENTRIC -> EXTENDED_HOLD -> (counted)
  ^                                                              |
  +--------------------------------------------------------------+
```

A repetition **begins** when the biceps activates *and* the arm rises past the
start threshold, and is **counted** when the arm has returned below the finish
threshold and been held still there for `hold_duration_ms`.

**Leaving READY needs posture and muscle.** Posture alone is satisfied by an
arm somebody else is moving — which is exactly the case this device exists to
catch, and the one a motion-only device cannot. An arm that rises with the
agonist quiet produces `REP_EVT_PASSIVE_SWING`: reported, never counted.

Counting on the **return** makes the score cover the whole movement including
the eccentric phase, where a weak limb usually fails first, and the confirming
hold supplies a stationary moment at a predictable point — which is what the
haptic and the gravity re-anchor both need. Feedback is *scheduled*, not
reactive, and the budget from criterion to perceptible motor movement is
~43 ms.

Holds require the limb to be *stationary*, not merely inside the band.
Thresholds are angles against the therapist's **target**, not fractions of
measured ROM: the therapist prescribes what the patient should reach, which is
not the same as what they currently can.

A soft click fires at 80 % of the target angle — "you may begin the return".
It is the one cue delivered mid-movement, so it is the shortest and lightest
in the set and is dropped rather than displacing a result.

Compensation detected mid-repetition is latched and reported at the confirming
hold, where it selects the three-pulse pattern instead of the single clean
click. **One haptic per repetition, never two** — except on the repetition
that completes the set, where a compound pattern plays the result, a 300 ms
gap, then the set-complete cue.

Reps are counted and *then* graded. Nothing is silently discarded: a patient
who gets no credit for a hard-won compensated repetition learns that the
device is broken, not that their form needs work.

---

## Scoring

Three components of equal weight — **range** against the therapist's target,
**tempo** against the prescribed window, **smoothness** as a velocity-peak
count — then deductions for shoulder compensation (−20), trunk lean (−15) and
momentum (−15), clamped to 0–100.

Co-contraction is the PRD's fourth component and needs an antagonist envelope,
which one sensor on the biceps does not provide. It is weighted zero, and the
score normalises by the weights in force, so the three remaining components
take a third each rather than the best achievable score being capped at 75.
Phase 2 restores it.

Hold steadiness is computed and reported but carries zero weight by default.

Every weight, threshold and window is settable over BLE at runtime — see
`config.h` for the TLV tag vocabulary.

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
observable: gravity where it should be, the channel alive and not saturated,
mains pickup within limits, and the envelope rising while the elbow flexes.

With one channel the two-channel orientation test — biceps must exceed triceps
during a test curl — is not available, so the check can no longer say *the
sleeve is on backwards*. It catches a dead, lifted or misplaced electrode, and
the message says exactly that rather than claiming more.

---

## Known gaps

Everything PRD v1.4 specifies is implemented. What is left needs something
this repository cannot supply.

| Gap | Blocked on |
| --- | --- |
| ERM rated voltage and overdrive clamp | The Adafruit 1201 datasheet, at bring-up. Wrong values give a weak or buzzy actuator |
| Haptic pattern timing margin | A scope capture on the PWM line with BLE active — the haptic task shares core 0 with NimBLE, so a radio event can stretch a gap |
| ADS131M02 backend | The custom PCB; the interface is in place and the stub fails loudly |
| Battery endurance | A two-hour run. Sensing is implemented; the ADC is sampled while acquisition is idle, because ADC1 is in continuous DMA during a session |
| Wrist substitution | Undetectable with two IMUs; needs a third on the hand |
| Cue blanking | A team decision (PRD §5.6). Nothing is implemented, and nothing should be until the firmware and algorithms owners agree — it changes scoring behaviour around every cue |
| Repetition events to flash | Not yet written; the partition table reserves the space |

Filter corners, Madgwick beta, compensation thresholds, the tempo window and
all grading weights are starting points. Tune them against volunteer data —
and note that all of them are now settable over BLE, so tuning is a session
rather than a rebuild. The acceptance gate for elbow angle is 5–10° against a
goniometer at 0°, 45°, 90° and 135°.

---

## Keeping the two sides honest

The host client mirrors the firmware's wire formats, and a mismatch there is
invisible to tests that parse what they themselves built. Three layouts are
therefore pinned by arithmetic over `EMG_N_CHANNELS` on **both** sides, with a
`_Static_assert` in C and an assertion in Python:

- `calib_record_t` (calibration characteristic)
- `device_status_t` (status characteristic)
- the EMG frame batch size

This is not hypothetical. `device_status_t` is `packed`, and the host carried
pad bytes it does not have — every field after `battery_mv` was read from the
wrong offset, and no test caught it because the host suites parse what the
host builds. Add a field to one side and forget the other, and the build now
fails instead.
