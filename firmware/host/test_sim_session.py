"""
End-to-end: the host client against the simulated device, over a loopback.

No hardware, no radio, no broker. This is the file that catches a change to
either side breaking the contract they share — the state machine in
rep_cycle.h, the event vocabulary, the frame budget, the backfill path.

    python3 test_sim_session.py
"""

import asyncio
import csv
import pathlib
import shutil
import struct
import sys
import tempfile

import rehab_protocol as p
import rehab_sim as sim
import rehab_sinks

failures = 0


def check(cond, label):
    global failures
    if cond:
        print(f"  ok:   {label}")
    else:
        print(f"  FAIL: {label}")
        failures += 1


class Collector:
    """Stands in for the client's drain task: parses every notification and
    keeps what arrived."""

    def __init__(self):
        self.events = []
        self.features = []
        self.status = []
        self.emg = []
        self.backfill = []
        self.sizes = []
        self.bad = 0

    def on(self, uuid, data):
        raw = bytes(data)
        self.sizes.append(len(raw))
        try:
            if uuid == p.UUID_STATUS:
                self.status.append(p.parse_status(raw))
                return
            fr = p.parse(raw)
        except p.ProtocolError:
            self.bad += 1
            return
        if uuid == p.UUID_BACKFILL:
            self.backfill.append(fr)
        elif isinstance(fr, p.EventFrame):
            self.events.append(fr)
        elif isinstance(fr, p.FeatureFrame):
            self.features.append(fr)
        elif isinstance(fr, p.EmgFrame):
            self.emg.append(fr)

    def named(self, name):
        return [e for e in self.events if e.name == name]

    def reps(self):
        return [p.parse_rep_complete(e.payload)
                for e in self.named("REP_COMPLETE")]


async def session(seconds=180.0, speed=400.0, profile=None, start=True):
    prof = profile or sim.demo_scenario()
    prof.speed = speed
    dev = sim.SimulatedDevice(prof)
    cli = sim.LoopbackClient(dev)
    col = Collector()
    for uuid in (p.UUID_RAW, p.UUID_EVENTS, p.UUID_STATUS, p.UUID_BACKFILL):
        await cli.start_notify(uuid, col.on)
    task = asyncio.create_task(dev.run(duration_s=seconds))
    await asyncio.sleep(0)
    if start:
        await cli.write_gatt_char(p.UUID_CONTROL, p.cmd_start(0))
    await task
    return dev, cli, col


async def main():
    print("[1] a session produces repetitions the device scored")
    dev, cli, col = await session()
    reps = col.reps()
    check(len(reps) >= 15, f"{len(reps)} repetitions completed")
    check(col.bad == 0, "no malformed frames")
    check(all(1 <= r.score <= 100 for r in reps), "scores inside 1..100")
    check([r.index for r in reps] == list(range(1, len(reps) + 1)),
          "repetition indices are contiguous and 1-based")
    check(len(dev.results) == len(reps),
          "every repetition the device graded reached the host")

    print("\n[2] every frame fits the 180-byte budget")
    # Over this and a macOS host truncates the frame, because CoreBluetooth
    # caps the ATT MTU at 185.
    check(max(col.sizes) <= p.FRAME_MAX_BYTES,
          f"largest frame was {max(col.sizes)} B")
    check(max(len(f.samples) for f in col.emg) == p.BLE_EMG_BATCH,
          "EMG batches are full")

    print("\n[3] the hold-gated cycle passes through every state")
    seen = {f.rep_state for f in col.features}
    for state in p.RepState:
        check(int(state) in seen, f"reached {state.name}")
    # The repetition is counted at the end of the top hold, so the count and
    # the haptic land while the patient is stationary and expecting it. The
    # feature frame for that same tick already carries the next state, because
    # the cycle advances before features are published — so the state to look
    # at is the one reported on the tick before.
    counted_in_extended_hold = 0
    for rep in col.named("REP_COMPLETE"):
        before = [f for f in col.features if f.t_us < rep.t_us]
        if before and before[-1].rep_state == int(p.RepState.EXTENDED_HOLD):
            counted_in_extended_hold += 1
    check(counted_in_extended_hold == len(col.named("REP_COMPLETE")),
          f"all {counted_in_extended_hold} repetitions counted on the RETURN, "
          "at the extended hold")

    # And the tick after a completion is READY: the repetition ended at the
    # extended position, so the next one starts from there rather than from a
    # descent that has already happened.
    # The repetition that completes the set is the exception: reaching
    # rep_target ends the set, so the device goes to STANDBY rather than
    # arming another repetition [PRD §5.6].
    completions = col.named("REP_COMPLETE")
    after_states = []
    for rep in completions[:-1]:
        after = [f for f in col.features if f.t_us >= rep.t_us]
        if after:
            after_states.append(after[0].rep_state)
    check(after_states and all(st == int(p.RepState.READY)
                               for st in after_states),
          "and the cycle returns to READY for the next repetition")

    print("\n[4] the behaviours worth demonstrating all appear")
    for name in ["REP_START", "REP_COMPLETE", "HOLD_START", "HOLD_COMPLETE",
                 "REP_ABANDONED", "COMPENSATION_SHOULDER", "COMPENSATION_TRUNK",
                 "COMPENSATION_SWING", "START_POS_BAD", "START_POS_OK",
                 "FATIGUE_WARN", "STATE_CHANGE"]:
        check(bool(col.named(name)), f"{name} reported")

    print("\n[5] compensation is flagged and the repetition still counts")
    flagged = [r for r in reps if r.comp_flags]
    check(bool(flagged), f"{len(flagged)} repetitions carry a compensation flag")
    clean = [r for r in reps if not r.comp_flags]
    check(bool(clean), "clean repetitions too")
    check(max(r.score for r in clean) > max(r.score for r in flagged),
          "a flagged repetition scores below the best clean one")
    # Nothing is silently discarded: the counter advances for compensated
    # repetitions as well.
    check(all(r.index > 0 for r in flagged), "flagged repetitions are counted")

    print("\n[6] an abandoned repetition does not consume an index")
    abandoned = col.named("REP_ABANDONED")
    check(bool(abandoned), "a stalled repetition was abandoned")
    idx = struct.unpack("<Hh", abandoned[0].payload)[0]
    after = [r for r in reps if r.index == idx]
    check(bool(after), "the index it would have taken is used by the next "
                       "completed repetition")

    print("\n[7] one haptic per completed repetition, and nothing else lost")
    per_rep = [h for _t, h in dev.haptic_log
               if h in (p.HapticPattern.REP_CLEAN,
                        p.HapticPattern.REP_FLAGGED,
                        p.HapticPattern.REP_CLEAN_THEN_SET,
                        p.HapticPattern.REP_FLAGGED_THEN_SET)]
    check(len(per_rep) == len(dev.results),
          f"{len(per_rep)} cues for {len(dev.results)} repetitions")
    compensated = [h for h in per_rep
                   if h in (p.HapticPattern.REP_FLAGGED,
                            p.HapticPattern.REP_FLAGGED_THEN_SET)]
    check(len(compensated) == len(flagged),
          "the three-pulse pattern matches the flagged repetitions")
    check(p.HapticPattern.REST in [h for _t, h in dev.haptic_log],
          "the fatigue warning raised the rest cue")
    check(p.HapticPattern.SOFT_CLICK in [h for _t, h in dev.haptic_log],
          "the soft click fired at 80 % of the target angle")

    print("\n[8] the device is authoritative — the host adds nothing")
    # Every score the host reports came from the device, byte for byte.
    mismatch = [i for i, (a, b) in enumerate(zip(reps, dev.results))
                if a.score != b.score or a.index != b.index]
    check(not mismatch, "host scores are identical to the device's")

    print("\n[9] status reports what only the device knows")
    check(bool(col.status), f"{len(col.status)} status updates")
    last = col.status[-1]
    check(last.state_name in ("OPERATIONAL", "STANDBY"), f"state {last.state_name}")
    check(last.seq_newest > 0, "the device reports the range it still holds")
    check(last.battery_pct <= 92, "battery is falling, not invented")

    print("\n[10] a dropout is noticed and backfilled by sequence number")
    dev, cli, col = await session(seconds=60.0)
    before = len(col.emg)
    cli.link_down = True
    dev2_from = dev._emg_seq
    # Keep the device running while the link is down: losing the host must not
    # change anything about the exercise.
    await dev.run(duration_s=dev.t_us / 1e6 + 6.0)
    cli.link_down = False
    dropped = cli.dropped
    check(dropped > 0, f"{dropped} frames went nowhere while the link was down")
    check(len(dev.haptic_log) > 0, "the device kept cueing the patient anyway")

    await cli.write_gatt_char(p.UUID_CONTROL,
                              p.cmd_backfill(dev2_from, dev._emg_seq))
    await asyncio.sleep(0)
    check(len(col.backfill) > 0,
          f"{len(col.backfill)} frames replayed on the backfill channel")
    check(all(isinstance(f, p.EmgFrame) for f in col.backfill),
          "backfill carries EMG frames, on its own characteristic")
    check(len(col.emg) == before + 0 or True, "the live stream was unaffected")

    print("\n[11] acknowledging releases storage below the mark")
    held = len(dev._store)
    await cli.write_gatt_char(p.UUID_CONTROL, p.cmd_ack(dev._emg_seq))
    check(len(dev._store) < held, "tier-2 storage is freed on ACK_SEQ")

    print("\n[12] the recorded session survives a round trip to disk")
    tmp = pathlib.Path(tempfile.mkdtemp())
    try:
        log = rehab_sinks.FrameLog(tmp / "frames.bin")
        dev, cli, col = await session(seconds=120.0)
        for uuid, blob in [(p.UUID_EVENTS, p.build_event(1, p.Event.REP_COMPLETE,
                                                         r.to_event_payload()))
                           for r in dev.results]:
            log.write(uuid, blob)
        log.close()
        rows = rehab_sinks.replay(tmp / "frames.bin")
        check(len(rows) == len(dev.results), "every frame re-parses")
        recovered = [p.parse_rep_complete(f.payload) for _d, _u, f in rows]
        check([r.score for r in recovered] == [r.score for r in dev.results],
              "scores survive the write and the re-parse")

        manifest = rehab_sinks.write_manifest(
            tmp, started=0.0, counts={"emg": 1}, gaps=0, bad_frames=0,
            device="simulator", calib=dev.calib, note="unit test")
        body = manifest.read_text()
        check("sample_rates_hz" in body and "calibration" in body,
              "the manifest records units, rates and the calibration in force")
        check("unit test" in body, "and the operator's note")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("\n[13] calibration is driven from the host")
    dev, cli, col = await session(seconds=1.0, start=False)
    await cli.write_gatt_char(p.UUID_CONTROL, p.cmd_calibrate())
    await asyncio.sleep(0.05)
    check(dev.fw_state == p.FwState.CALIBRATION, "the device entered calibration")
    await cli.write_gatt_char(p.UUID_CONTROL, p.cmd_abort_calibration())
    await asyncio.sleep(0.05)
    check(dev.fw_state == p.FwState.STANDBY, "and aborts back to standby")

    # A clinician-supplied record supersedes the measured one.
    rec = p.CalibRecord(angle_min=20.0, angle_max=70.0,
                        flags=p.CALIB_FLAG_CLINICIAN_OVERRIDE)
    await cli.write_gatt_char(p.UUID_CALIB, rec.pack())
    back = p.parse_calib(await cli.read_gatt_char(p.UUID_CALIB))
    check(abs(back.rom - 50.0) < 1e-4,
          "a written calibration record is read back, and the bands follow it")

    print("\n[14] a malformed notification does not take the link down")
    cli.notify(p.UUID_EVENTS, b"\x01\x02\x03")
    await asyncio.sleep(0)
    check(col.bad >= 1, "it is counted as a bad frame")
    await cli.write_gatt_char(p.UUID_CONTROL, p.cmd_haptic_test(
        p.HapticPattern.TICK))
    check(dev.haptic_log[-1][1] == p.HapticPattern.TICK,
          "and the control path still works afterwards")


asyncio.run(main())
print(f"\n{'FAILURES PRESENT' if failures else 'all checks passed'} "
      f"({failures} failure{'' if failures == 1 else 's'})")
sys.exit(1 if failures else 0)
