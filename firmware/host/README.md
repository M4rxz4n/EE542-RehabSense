# host — the Python BLE client

Connects to the sleeve, logs every frame to disk, and prints live state. The
log is the more important half: tuning filter coefficients, thresholds and
grading weights needs recorded data, not a live plot.

```
pip install bleak                       # paho-mqtt and matplotlib are optional

python3 rehab_client.py                 # connect, stream, log
python3 rehab_client.py --scan          # list devices
python3 rehab_client.py --calibrate     # run the calibration protocol
python3 rehab_client.py --start         # begin a set once connected
python3 rehab_client.py --haptic 1      # fire pattern 1 and exit

python3 rehab_client.py --sim           # against the simulator, no hardware
python3 rehab_client.py --plot          # live view on the bench
python3 rehab_client.py --mqtt          # publish reps to the backend topics

./run_tests.sh                          # everything, with nothing plugged in
```

| File | What it is |
|---|---|
| `rehab_protocol.py` | The wire format. Mirrors `main/ble/ble_service.h` — change one, change the other. |
| `rehab_client.py` | Connect, drain, record, print. |
| `rehab_grading.py` | Python mirror of `main/rep/grading.c`, for the simulator and as a cross-check. |
| `rehab_sim.py` | A simulated device on the other end of a loopback. |
| `rehab_sinks.py` | MQTT, the byte-exact frame log, the session manifest. |
| `rehab_plot.py` | Optional live view. |
| `test_protocol.py`, `test_grading.py`, `test_sim_session.py` | Run them with `./run_tests.sh`. |

## Two things to know before changing anything

**The notification callback only enqueues.** Parsing, recording and plotting
happen in a separate task. Do the work inline and the BLE connection stalls
behind it.

**The device is authoritative** for repetition counts, scores, compensation
flags and fatigue. The host displays them; it never re-derives them from the
raw stream. `rehab_grading.py` exists for the simulator and as a cross-check on
`grading.c` — it is never run on live device data. If the two ever disagree
that is a firmware bug to fix, not a discrepancy to paper over in the UI.

## The simulator

The host had to be finished before the board was, and even afterwards there is
no way to rehearse a dropped link, a fatiguing set or a staged compensation on
demand. `--sim` puts a device-shaped thing on the other end of a loopback that
speaks the real wire format: same 14-byte header, same four frame types, same
control opcodes, same 180-byte budget, same hold-gated cycle from
`rep_cycle.h`, scored through `rehab_grading`.

```
python3 rehab_client.py --sim --speed 20 --sim-seconds 300 --plot
```

`--speed` runs device time faster than wall clock, so a three-minute set takes
nine seconds. The demo scenario walks through a clean repetition, a staged
shoulder hike, an arm swung rather than curled, a bad start posture, a
repetition abandoned mid-range, heavy co-contraction, a trunk lean, and a
fatiguing run-out that trips the fatigue warning.

It is faithful about the protocol, the state machine, the event vocabulary and
the frame rates. It is **not** a model of an arm, of electrode physics, or of
BLE timing — the numbers are plausible, not measured. **Do not tune thresholds
against it.** Tune them against recorded volunteer data. Its job is to prove
the host works and to keep both sides honest about the contract.

## What a session leaves behind

`logs/session-<timestamp>/`:

```
emg.csv        2 kSPS x 2 channels, per-sample timestamps from the frame base
imu.csv        100 Hz x 2 IMUs, accel in g and gyro in deg/s
features.csv   50 Hz: envelopes, MDF, elbow angle, upper-arm deviation, state
events.csv     every event, with its payload
reps.csv       one row per completed repetition, as the device scored it
status.csv     battery, faults, clipping counters, the range the device holds
frames.bin     byte-exact frame log
manifest.json  units, sample rates, the calibration record in force, counts
summary.png    with --plot
```

`frames.bin` is the one to keep. It replays through a changed parser, so a
protocol change gets checked against real captures rather than against freshly
generated ones:

```python
import rehab_sinks
for dt_ms, uuid, frame in rehab_sinks.replay("logs/session-.../frames.bin"):
    ...
```

## MQTT

`rehabsense/<device_id>/{rep,event,status,online}`, JSON. A broker that is down
never stalls the BLE link: paho runs its own network thread, failures are
counted and reported in the summary, and nothing raises.

The topic names and payload shape are **a proposal, not a decision** — they
need to match whatever the Flutter client subscribes to. Nothing else depends
on them, so changing them is a change to `rehab_sinks.py` alone.

## Open points

**1. `features_t` is not packed, and the host used to assume it was.**
`ble_notify_features()` memcpy's `features_t` straight into the frame.
`features_t` leads with a `uint64_t`, so its alignment is 8 and the compiler
inserts a pad byte after `rep_state` — `sizeof(features_t)` is 40, not 39.
Reading it without the pad does not fail; it silently shifts `rep_count`,
`comp_flags` and `sig_flags` one byte left. In a test frame carrying
`rep_count = 7`, the unpadded read returns 1792.

The host now accepts both layouts and picks by body length, so it works either
way. The tidier fix is on the firmware side: mark `features_t`
`__attribute__((packed))`, which is what `rehab_types.h`'s own convention says
should happen to anything crossing BLE. `device_status_t` has the same shape of
problem (it pads to 40) and is handled the same way here.

**2. `EVT_REP_COMPLETE` has no payload layout yet.** `rep_cycle.c` produces a
`rep_result_t`, and `ble_notify_event()` can carry 16 payload bytes, but
nothing in `main.c` emits the event — so there is no C-side layout to mirror.
`rep_result_t` is 56 bytes and will not fit. `rehab_protocol.RepComplete` is a
16-byte proposal covering what the host needs, and the simulator emits it, so
the whole path is exercised. Adopt it, amend it or replace it when `main.c`
grows its event wiring — but change both sides together.

**3. Where a repetition is counted.** `rep_cycle.h` counts at the end of the
*top* hold. PRD v1.3 §12.1 records a 22 October decision to count on the return
to the extended position instead, so that tempo covers the full excursion and
the gravity re-anchor gets its stationary moment. The firmware predates that
decision. The simulator follows the firmware, not the PRD, because the firmware
is what the host has to talk to. Worth settling at a Thursday lab.

**4. Calibration.** `calibration.h` defines a four-phase protocol with
`calibration_begin_neutral_only()` for a returning patient. `cmd_calibrate()`
takes a phase so a single step can be re-run without the full 90 seconds, but
the firmware's command handler currently ignores the argument.
