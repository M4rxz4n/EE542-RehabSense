# RehabSense v5 Bluetooth: the team protocol on the prototype sleeve

v5 is the step 5 firmware (every feature from `prototype_new_haptics` plus FC1–FC6, FT1–FT4, AP1–AP2, GP1–GP3 and AT1–AT4) with a Bluetooth LE layer that speaks the team protocol from the EE542-RehabSense repo (`final/firmware/main/ble/ble_service.h`, `final/python/rehab_protocol.py`). The byte packing (`rs_proto.cpp`, called wire.cpp in v4) is taken unchanged from rehabsense_v4, where it was checked byte for byte against `rehab_protocol.py`.

The Bluetooth layer only reports what the sleeve does and passes commands in. Counting, haptics and the Serial Monitor work exactly as they do without a connection.

## How it was checked (no ESP32 toolchain in the build environment)

- All modules compile and link on a laptop against stubs that copy the NimBLE-Arduino 2.3.6 signatures used (`onConnect(NimBLEServer*, NimBLEConnInfo&)`, `onDisconnect(…, int reason)`, `onWrite(NimBLECharacteristic*, NimBLEConnInfo&)`, `notify(const uint8_t*, size_t)`, `createCharacteristic(uuid, props, max_len)`), checked against the library source.
- A host test runs the real `setup()`/`loop()`, plays the app (writes to 0002), simulates an arm and dumps every notification. The dump was decoded with the team's `rehab_protocol.py`: features, IMU frames, status, config TLV, calibration record and all events parsed without errors. Tested: SET_CONFIG, GET_CONFIG, START when uncalibrated (calibrates by itself, then starts), 3 reps → SET_COMPLETE → rest, START during the rest, a partial (REP_ABANDONED), a dropped rep (comp flag 8), TEXT "b", HAPTIC_TEST, STOP, disconnect → advertising restarts, REQUEST_RECALIBRATION, ABORT_CALIBRATION.
- The step 1–5 simulations (false curls, fatigue, auto-pause, pace, adaptive target, rest countdown) give the same output as step 5.

Still to do on the real board: the first upload, phone/laptop connection and range.

## Fix after the first hardware test (28 Oct): no more lost lines and events

On the first real connection most printed lines never reached the viewer (for example `=== Calibration done ===` and every `Step … done.`). NimBLE sends a notification with its own value to the client whether it subscribed or not, and has only about 12 buffers for them; the 17 raw IMU frames a second (which the viewer never asked for) plus a burst of printed lines used them up, and every notification after that was refused and lost.

Now:
- Raw IMU frames (0003), feature frames and events (0004) and printed lines (000A) are sent only after the client turns notifications on for that characteristic.
- Events and printed lines go into queues and are sent a few per tick. An item leaves the queue only once NimBLE has accepted it, so a busy link delays a line instead of dropping it. Events go first, then lines, then the 50 Hz feature frame.
- Several short lines share one notification (up to 180 bytes, whole lines when they fit).

Host test with a slow link (one free buffer every 25 ms): before the fix 9 of 122 lines and none of the 4 REP_COMPLETE events arrived; after it, all lines and all events arrived, still decoding with `rehab_protocol.py`.

## Two fixes compared with rehabsense_v4's Bluetooth

1. **The service is started** (`svc->start()`). v4 never called it; NimBLE leaves a service that isn't started out of the GATT table, so a client connects but finds no RehabSense service.
2. **Advertising restarts after a disconnect.** v4 didn't, so after the first disconnect the sleeve could not be found again until it was reset.

## Service and characteristics

Service `A5B10001-7C4E-4D9A-9E3F-1D2C3B4A5968`; characteristics `A5B1000N-7C4E-4D9A-9E3F-1D2C3B4A5968`. Advertised name **RehabSense** (in the advertising packet); service UUID in the scan response.

| Char | Name | Properties | v5 |
|---|---|---|---|
| 0002 | Control | write, write without response | opcode + payload (table below) |
| 0003 | Raw stream | notify | IMU frames, 100 Hz, 6 samples per frame, while RAW_STREAM = 1 and the client has subscribed. No raw EMG frames. |
| 0004 | Events + features | notify | feature frames at 50 Hz and event frames |
| 0005 | Status | read, notify | 29-byte `device_status_t`, every 1 s and on every state change |
| 0006 | Backfill | notify | unused (nothing is buffered) |
| 0007 | Calibration | read, write | 104-byte record, refreshed after each calibration; writes accepted and ignored |
| 0008 | Configuration | read, notify | TLV block, re-sent after every change |
| 0009 | Transfer | read, notify | always state FAILED (4): no Wi-Fi transfer on this board |
| **000A** | **Messages** (RehabSense extension) | notify | **every line the sleeve prints**, the same text as the Serial Monitor (REP, Partial, [FC…], [FT…], [AP…], [GP…], calibration prompts), each line ending in `\n`, split into notifications of at most 180 bytes. The 20 Hz plotter lines are not sent this way; Bluetooth carries the live data as feature frames. |

## Feature frame (0004, type 0x03, 50 Hz)

| Field | v5 value |
|---|---|
| envelope | biceps, % of the calibration squeeze / 100 |
| mdf | 0 (not measured) |
| elbow_angle_deg | the gravity-based elbow angle, 0 = calibrated straight arm |
| upper_arm_dev_deg | upper-arm tilt from its calibrated pose ([FC4]) |
| rep_state | 0 READY, 1 CONCENTRIC (lifting), 2 PEAK, 3 ECCENTRIC (lowering). Never 4. |
| rep_count | reps counted in the current set |
| comp_flags | live: 1 = upper arm tilted past the shoulder limit now, 4 = upper arm turning faster than the swing limit now |
| activation_on | biceps "on" ([FC1] adaptive threshold) |

## States (STATE_CHANGE payload, status `fw_state`)

| State | When |
|---|---|
| 2 STANDBY | waiting to calibrate, resting between sets, auto-paused, session done |
| 4 CALIBRATION | calibration running |
| 5 OPERATIONAL | reps being counted |
| 6 FAULT | an IMU stopped answering (FAULT event, code 2) |

## Events v5 sends

| id | Event | When | Payload |
|---|---|---|---|
| 0x01 | REP_START | angle passes the start angle (15°) | – |
| 0x02 | REP_COMPLETE | rep counted | 16 bytes as `rehab_protocol.py`: index in set, score (after deductions), ROM %, 0, 0, 0, peak (deg × 10), comp flags, duration ms |
| 0x03 | REP_ABANDONED | partial rep: came back down below the target, or [FC6] 10 s timeout | `<Hh`: next index in set, peak (deg × 10), as `rehab_sim.py` |
| 0x06 | COMPENSATION_SHOULDER | after a REP_COMPLETE with [FC4] | – |
| 0x08 | COMPENSATION_SWING | after a REP_COMPLETE with [FC3] | – |
| 0x0B | FATIGUE_WARN | [FT2] one sign (note), [FT3]/[FT4] two or more signs (set or session ends), or three partials in a row | `<hH`: number of signs (1–3; **9** = three partials in a row), total reps. The team simulator puts an MDF slope in the first field; v5 has no MDF. |
| 0x0D | CALIB_PHASE_DONE | calibration progress | `[phase, percent]`: `[phase, 0]` when a step starts, `[phase, 100]` when it's done. Phases REST 2, STRAIGHT 3, BICEPS 4, then DONE 8 or FAILED 9 |
| 0x0E | SET_COMPLETE | set finished (rest starts), session finished, fatigue stop | u16 reps in the set; no payload after STOP |
| 0x0F | FAULT | an IMU stopped answering | u8 fault code 2 |
| 0x10 | STATE_CHANGE | every state change | u8 state |
| 0x11 | PASSIVE_SWING | [FC2] the arm went up but the biceps was on for less than 60 % of the lift: not counted | – |

Comp flags in REP_COMPLETE: 1 shoulder / lean [FC4], 4 swing / momentum [FC3], **8 drop [FC5]** (RehabSense extension: lowered faster than 150°/s).

## Control opcodes (0002)

| Op | Command | v5 behaviour |
|---|---|---|
| 0x01 | START_SESSION | Not calibrated: runs calibration by itself (each step starts after 3 s), then starts the reps. Resting between sets: ends the rest now. Session done: new session. |
| 0x02 | STOP_SESSION | Ends the session (counts kept, adaptive target updated), SET_COMPLETE with no payload |
| 0x03 | START_CALIBRATION + phase | STRAIGHT (3): re-zero only (same as typing `z`). Anything else: the full 3 steps by themselves |
| 0x04 | ABORT_CALIBRATION | Stops calibration within 0.1 s. CALIB_PHASE_DONE FAILED, sleeve back to "waiting to calibrate". During the final 3 s before reps start, it keeps the calibration and doesn't start. |
| 0x05 | REQUEST_RECALIBRATION | Full calibration by itself |
| 0x08 | SET_CONFIG + TLV | REP_TARGET, SET_COUNT, REST_SECONDS, TARGET/START/FINISH_ANGLE, TEMPO, COMP_THRESH (shoulder, swing; trunk ignored), DEDUCTIONS (shoulder, swing; trunk ignored), RAW_STREAM. HOLD_MS, HOLD_VEL, WEIGHTS, CHANNEL_ROLES accepted and ignored. Wrong length: whole block rejected. Applied until the sleeve is switched off (not saved). Calibration replaces the target with the adaptive one [AT1]; send TARGET_ANGLE after calibrating, or lock it with TEXT `t<deg>`. |
| 0x09 | GET_CONFIG | Re-sends 0008 |
| 0x0A | HAPTIC_TEST + pattern | Team pattern ids 1–9 |
| 0x0B | SET_TIME + u64 epoch µs | Sets `host_time_offset_us` in status |
| 0x0C | POWER_OFF | Same as STOP (switch the power bank off) |
| 0x0D | START_TRANSFER | Answered on 0009 with FAILED |
| 0x06, 0x07, 0x0E | ack, backfill, stop transfer | Accepted, nothing to do |
| **0x20** | **TEXT** + ASCII (RehabSense extension) | Runs a Serial Monitor command as if typed: `c`, `n`, `z`, `g`, `r`, `b`, `t?`, `t110`, `tl`, `tr`, `l`, `h1`… During calibration, `n`, `z` and `g` move it on, just like typing them. New command `i` prints a `# LIVE …` status line and the `# PARAMS …` line; the session viewer sends it on connecting so it knows the thresholds even mid-session. |

During calibration only TEXT, ABORT, HAPTIC_TEST, GET_CONFIG, SET_TIME and acks are handled; other commands wait until calibration ends.

## Known issue in `rehab_client.py` (one-line fix, still in the repo)

With one EMG channel, `_print_live` reads `fr.envelope[1]`, which doesn't exist; the first live line raises `IndexError` and logging stops. Line 267 of `final/python/rehab_client.py`:

```python
              f"bi {fr.envelope[0]:5.2f}  tri {fr.envelope[1]:5.2f}  "
```

becomes

```python
              f"bi {fr.envelope[0]:5.2f}  "
```
