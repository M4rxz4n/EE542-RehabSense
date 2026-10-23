#!/usr/bin/env python3
"""
rehab_client.py — RehabSense host client over BLE.

Logs every frame to disk and prints live state. The log is the input to
offline algorithm tuning in NumPy and SciPy, which is this tool's more
important job: tuning filter coefficients, thresholds and grading weights
needs recorded data, not a live plot.

    pip install bleak

    python rehab_client.py                 # connect, stream, log
    python rehab_client.py --scan          # just list devices
    python rehab_client.py --calibrate     # run the calibration protocol
    python rehab_client.py --start         # begin a set once connected
    python rehab_client.py --haptic 1      # fire pattern 1 and exit

    python rehab_client.py --sim           # against the simulator, no hardware
    python rehab_client.py --sim --speed 20 --duration 120 --start
    python rehab_client.py --plot          # live view on the bench
    python rehab_client.py --mqtt          # publish reps to the backend topics

Implementation notes that matter:

  * The notification callback runs on the asyncio event loop. Frames go into
    a queue and are processed in a separate task — do the work inline and the
    BLE connection stalls behind it.
  * MTU differs by backend (WinRT negotiates up to 517, CoreBluetooth caps at
    185, BlueZ is configurable). The firmware's 180-byte frame budget makes
    that invisible, which is why it is set there rather than here.
"""

from __future__ import annotations

import argparse
import asyncio
import csv
import datetime as dt
import pathlib
import sys
import time

try:
    from bleak import BleakClient, BleakScanner
except ImportError:
    # Not fatal any more: --sim needs no radio, which is what makes the host
    # testable in CI and on a machine with no adapter.
    BleakClient = BleakScanner = None

import rehab_protocol as p
import rehab_sinks


class Recorder:
    """Writes each stream to its own CSV. Flat files, easy to load."""

    def __init__(self, outdir: pathlib.Path):
        stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        self.dir = outdir / f"session-{stamp}"
        self.dir.mkdir(parents=True, exist_ok=True)

        self._files = {}
        self._writers = {}

        self._open("emg", ["seq", "t_us", "ch_a", "ch_b"])
        self._open("imu", ["seq", "t_us",
                           "u_ax", "u_ay", "u_az", "u_gx", "u_gy", "u_gz",
                           "f_ax", "f_ay", "f_az", "f_gx", "f_gy", "f_gz"])
        self._open("features", ["seq", "t_us", "env_a", "env_b",
                                "mdf_a", "mdf_b", "angle_deg", "upper_dev_deg",
                                "rep_state", "rep_count", "comp_flags",
                                "sig_flags"])
        self._open("events", ["t_us", "event", "payload_hex"])
        # One row per completed repetition, unpacked from EVT_REP_COMPLETE.
        # The device is authoritative for all of it.
        self._open("reps", ["t_us", "index", "score", "rom_fraction",
                            "cocontraction", "smoothness", "hold_steadiness",
                            "peak_angle_deg", "duration_ms", "compensation"])
        self._open("status", ["t_host", "state", "fault", "battery_pct",
                              "battery_mv", "rep_count", "clip_a", "clip_b",
                              "seq_oldest", "seq_newest", "gap_occurred"])

        self.frames = rehab_sinks.FrameLog(self.dir / "frames.bin")
        print(f"logging to {self.dir}")

    def _open(self, name, header):
        f = open(self.dir / f"{name}.csv", "w", newline="")
        w = csv.writer(f)
        w.writerow(header)
        self._files[name] = f
        self._writers[name] = w

    def emg(self, fr: p.EmgFrame):
        us_per = 1_000_000 / p.EMG_SAMPLE_RATE_HZ
        w = self._writers["emg"]
        for i, (a, b) in enumerate(fr.samples):
            w.writerow([fr.seq + i, int(fr.t_us + i * us_per), a, b])

    def imu(self, fr: p.ImuFrame):
        us_per = 1_000_000 / p.IMU_SAMPLE_RATE_HZ
        w = self._writers["imu"]
        for i, (upper, fore) in enumerate(fr.samples):
            w.writerow([fr.seq + i, int(fr.t_us + i * us_per),
                        *upper[0], *upper[1], *fore[0], *fore[1]])

    def features(self, fr: p.FeatureFrame):
        self._writers["features"].writerow(
            [fr.seq, fr.t_us, *fr.envelope, *fr.mdf, fr.elbow_angle_deg,
             fr.upper_arm_dev_deg, fr.rep_state, fr.rep_count,
             fr.comp_flags, fr.sig_flags])

    def event(self, fr: p.EventFrame):
        self._writers["events"].writerow(
            [fr.t_us, fr.name, fr.payload.hex()])

    def rep(self, t_us: int, rc: p.RepComplete):
        self._writers["reps"].writerow(
            [t_us, rc.index, rc.score, f"{rc.rom_fraction:.3f}",
             f"{rc.cocontraction:.3f}", f"{rc.smoothness:.3f}",
             f"{rc.hold_steadiness:.3f}", f"{rc.peak_angle_deg:.1f}",
             rc.duration_ms, "|".join(rc.comp)])

    def status(self, st: p.StatusFrame):
        self._writers["status"].writerow(
            [round(time.time(), 3), st.state_name, st.fault_name,
             st.battery_pct, st.battery_mv, st.rep_count,
             st.clip_count[0], st.clip_count[1], st.seq_oldest, st.seq_newest,
             int(st.gap_occurred)])

    def close(self):
        for f in self._files.values():
            f.close()
        self.frames.close()


class Session:
    def __init__(self, rec: Recorder, mqtt=None, buf=None):
        self.rec = rec
        self.mqtt = mqtt
        self.buf = buf                      # rehab_plot.LiveBuffer, or None
        self.queue: asyncio.Queue = asyncio.Queue(maxsize=4096)
        self.highest_seq = 0
        self.gaps = 0
        self.counts = {"emg": 0, "imu": 0, "features": 0, "events": 0,
                       "status": 0, "backfill": 0}
        self.bad_frames = 0
        self._expect_seq = None
        self.rep_count = 0
        self.started = time.time()
        self.last_status: p.StatusFrame | None = None
        self.results: list[p.RepComplete] = []

    def on_notify(self, sender, data: bytearray):
        """Runs on the event loop — keep it to an enqueue.

        bleak hands us the characteristic; the loopback hands us its UUID. The
        channel matters because the status characteristic carries a bare
        device_status_t, not a framed stream.
        """
        uuid = str(getattr(sender, "uuid", sender)).lower()
        try:
            self.queue.put_nowait((uuid, bytes(data)))
        except asyncio.QueueFull:
            self.gaps += 1

    async def drain(self, client):
        while True:
            uuid, raw = await self.queue.get()
            self.rec.frames.write(uuid, raw)

            if uuid == p.UUID_STATUS:
                try:
                    st = p.parse_status(raw)
                except p.ProtocolError as exc:
                    self.bad_frames += 1
                    print(f"  ! malformed status: {exc}")
                    continue
                self.counts["status"] += 1
                self.last_status = st
                self.rec.status(st)
                if self.mqtt:
                    self.mqtt.status(st)
                if self.buf:
                    self.buf.status(st)
                continue

            if uuid == p.UUID_BACKFILL:
                self.counts["backfill"] += 1

            try:
                fr = p.parse(raw)
            except p.ProtocolError as exc:
                self.bad_frames += 1
                if self.bad_frames < 5:
                    print(f"  ! malformed frame: {exc}")
                continue

            if isinstance(fr, p.EmgFrame):
                self.counts["emg"] += 1
                self.rec.emg(fr)
                self._track_seq(fr)
                # Acknowledge roughly once a second so the device can release
                # tier-2 storage below the mark.
                if self.counts["emg"] % p.FEATURE_RATE_HZ == 0:
                    await self._ack(client, self.highest_seq)

            elif isinstance(fr, p.ImuFrame):
                self.counts["imu"] += 1
                self.rec.imu(fr)

            elif isinstance(fr, p.FeatureFrame):
                self.counts["features"] += 1
                self.rec.features(fr)
                if self.buf:
                    self.buf.feature(fr)
                self._print_live(fr)

            elif isinstance(fr, p.EventFrame):
                self.counts["events"] += 1
                self.rec.event(fr)
                if self.buf:
                    self.buf.event(fr)
                if self.mqtt:
                    self.mqtt.event(fr)
                if fr.event == p.Event.REP_COMPLETE:
                    self._on_rep(fr)
                self._print_event(fr)

    def _on_rep(self, fr: p.EventFrame):
        """Unpack the repetition record the device scored. If the payload is
        not the agreed 16 bytes the event still counts — the repetition
        happened — but there is nothing to record beyond that."""
        try:
            rc = p.parse_rep_complete(fr.payload)
        except p.ProtocolError as exc:
            print(f"\n  ! REP_COMPLETE without a usable payload: {exc}")
            return
        self.results.append(rc)
        self.rec.rep(fr.t_us, rc)
        if self.mqtt:
            self.mqtt.rep(rc, fr.t_us)
        if self.buf:
            self.buf.rep(rc)

    def _track_seq(self, fr: p.EmgFrame):
        n = len(fr.samples)
        if self._expect_seq is not None and fr.seq != self._expect_seq:
            missing = fr.seq - self._expect_seq
            if missing > 0:
                self.gaps += 1
                print(f"  ! gap: {missing} samples missing at seq {fr.seq}")
        self._expect_seq = fr.seq + n
        self.highest_seq = max(self.highest_seq, fr.seq + n)

    async def _ack(self, client, seq):
        try:
            await client.write_gatt_char(p.UUID_CONTROL, p.cmd_ack(seq),
                                         response=False)
        except Exception:
            pass   # link down; the device keeps buffering regardless

    def _print_live(self, fr: p.FeatureFrame):
        if self.counts["features"] % 10:      # ~5 Hz
            return
        state = p.RepState(fr.rep_state).name if fr.rep_state < 5 else "?"
        print(f"\r  {fr.elbow_angle_deg:6.1f} deg  "
              f"bi {fr.envelope[0]:5.2f}  tri {fr.envelope[1]:5.2f}  "
              f"MDF {fr.mdf[0]:5.1f} Hz  {state:<14} reps {fr.rep_count:3d} ",
              end="", flush=True)

    def _print_event(self, fr: p.EventFrame):
        if fr.event == p.Event.REP_COMPLETE:
            self.rep_count += 1
            if self.results:
                rc = self.results[-1]
                bar = ("=" * round(rc.score / 5)).ljust(20, ".")
                comp = ", ".join(rc.comp)
                print(f"\n  rep {rc.index:3d}  score {rc.score:3d} [{bar}]  "
                      f"rom {rc.rom_fraction * 100:3.0f}%  "
                      f"peak {rc.peak_angle_deg:5.1f} deg  "
                      f"{rc.duration_ms / 1000:4.1f} s"
                      + (f"   <- {comp}" if comp else ""))
            else:
                print(f"\n  rep {self.rep_count} complete")
        elif fr.event == p.Event.REP_ABANDONED:
            print("\n  rep abandoned")
        elif fr.event == p.Event.FATIGUE_WARN:
            print("\n  *** fatigue — rest cue sent ***")
        elif fr.event == p.Event.START_POS_BAD:
            pass   # nagged by haptic already; too noisy to print
        elif fr.event == p.Event.STATE_CHANGE and fr.payload:
            try:
                print(f"\n  state -> {p.FwState(fr.payload[0]).name}")
            except ValueError:
                pass
        else:
            print(f"\n  {fr.name}")

    def summary(self):
        print("\n\n--- session summary ---")
        for k, v in self.counts.items():
            print(f"  {k:9s} {v}")
        print(f"  gaps      {self.gaps}")
        print(f"  bad frames {self.bad_frames}")
        if self.results:
            scores = [r.score for r in self.results]
            flagged = sum(1 for r in self.results if r.comp_flags)
            print(f"  reps      {len(scores)} "
                  f"(mean score {sum(scores) / len(scores):.0f}, "
                  f"{flagged} with compensation)")
        if self.mqtt:
            print(f"  mqtt      {self.mqtt.published} published, "
                  f"{self.mqtt.failed} failed, "
                  f"{'connected' if self.mqtt.connected else 'not connected'}")
        print(f"  logged to {self.rec.dir}")


async def find_device(timeout=10.0):
    print(f"scanning for {p.DEVICE_NAME}...")
    devices = await BleakScanner.discover(timeout=timeout)
    for d in devices:
        if d.name and p.DEVICE_NAME.lower() in d.name.lower():
            print(f"found {d.name} at {d.address}")
            return d
    return None


async def run(args):
    if args.scan:
        if BleakScanner is None:
            sys.exit("bleak is not installed.  pip install bleak")
        for d in await BleakScanner.discover(timeout=args.timeout):
            print(f"  {d.address}  {d.name or '(no name)'}")
        return

    sim = None
    if args.sim:
        import rehab_sim
        profile = rehab_sim.demo_scenario()
        profile.speed = args.speed
        sim = rehab_sim.SimulatedDevice(profile)
        client = rehab_sim.LoopbackClient(sim)
        print(f"simulated device, scenario 'demo', speed x{args.speed:g}")
    else:
        if BleakClient is None:
            sys.exit("bleak is not installed.  pip install bleak "
                     "(or run with --sim)")
        device = await find_device(args.timeout)
        if device is None:
            sys.exit(f"no {p.DEVICE_NAME} found. Is it powered and advertising?")
        client = BleakClient(device)

    mqtt = None
    if args.mqtt:
        mqtt = rehab_sinks.MqttPublisher(args.mqtt_host, args.mqtt_port,
                                         device_id=args.device_id,
                                         patient_id=args.patient_id)

    buf = None
    plot = None
    if args.plot:
        import rehab_plot
        buf = rehab_plot.LiveBuffer()

    rec = Recorder(pathlib.Path(args.outdir))
    sess = Session(rec, mqtt=mqtt, buf=buf)
    stop = asyncio.Event()
    tasks = []
    if sim is not None:
        tasks.append(asyncio.create_task(sim.run(duration_s=args.sim_seconds)))
        await asyncio.sleep(0)

    async with client:
        print(f"connected (MTU {getattr(client, 'mtu_size', '?')})")

        await client.start_notify(p.UUID_RAW, sess.on_notify)
        await client.start_notify(p.UUID_EVENTS, sess.on_notify)
        await client.start_notify(p.UUID_BACKFILL, sess.on_notify)
        # The device is authoritative for battery, faults, clipping counters
        # and the sequence range it still holds, so subscribe rather than
        # inferring any of it here.
        await client.start_notify(p.UUID_STATUS, sess.on_notify)

        calib = None
        try:
            calib = p.parse_calib(await client.read_gatt_char(p.UUID_CALIB))
            print(f"calibration: ROM {calib.angle_min:.0f}..{calib.angle_max:.0f} deg"
                  + ("  (MVC flagged unreliable)" if calib.mvc_unreliable else ""))
        except Exception as exc:                      # noqa: BLE001
            print(f"  no calibration record readable ({exc})")

        if plot is None and buf is not None:
            plot = rehab_plot.LivePlot(buf, calib or p.CalibRecord(
                angle_min=0.0, angle_max=140.0))
            if plot.ok:
                tasks.append(asyncio.create_task(plot.run(stop)))

        now_us = int(dt.datetime.now().timestamp() * 1e6)
        await client.write_gatt_char(p.UUID_CONTROL, p.cmd_set_time(now_us),
                                     response=False)

        if args.haptic is not None:
            await client.write_gatt_char(p.UUID_CONTROL,
                                         p.cmd_haptic_test(args.haptic),
                                         response=False)
            print(f"fired haptic pattern {args.haptic}")
            await asyncio.sleep(2)
            return

        if args.calibrate:
            print("starting calibration — follow the prompts on the device")
            await client.write_gatt_char(p.UUID_CONTROL, p.cmd_calibrate(),
                                         response=False)
        elif args.start or args.sim:
            await client.write_gatt_char(p.UUID_CONTROL, p.cmd_start(0),
                                         response=False)
            print("set started")

        drain = asyncio.create_task(sess.drain(client))
        tasks.append(drain)
        try:
            if args.duration:
                await asyncio.sleep(args.duration)
            elif sim is not None:
                await asyncio.sleep(max(0.1, (args.sim_seconds or 120)
                                        / max(0.01, args.speed)))
            else:
                print("streaming — Ctrl-C to stop\n")
                while client.is_connected:
                    await asyncio.sleep(0.5)
        except asyncio.CancelledError:
            pass
        finally:
            stop.set()
            if sim is not None:
                sim.stop()
            for t in tasks:
                t.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            try:
                await client.write_gatt_char(p.UUID_CONTROL, p.cmd_stop(),
                                             response=False)
            except Exception:
                pass
            if plot is not None:
                plot.close()
            png = None
            if buf is not None:
                import rehab_plot
                png = rehab_plot.save_summary(buf, rec.dir / "summary.png")
            rehab_sinks.write_manifest(
                rec.dir, started=sess.started, counts=sess.counts,
                gaps=sess.gaps, bad_frames=sess.bad_frames,
                device="simulator" if sim is not None else p.DEVICE_NAME,
                calib=calib, note=args.note,
                extra={"haptic_cues": [[t, p.HapticPattern(h).name]
                                       for t, h in sim.haptic_log]}
                if sim is not None else None)
            rec.close()
            if mqtt is not None:
                mqtt.close()
            sess.summary()
            if png:
                print(f"  summary   {png}")


def main():
    ap = argparse.ArgumentParser(description="RehabSense BLE host client")
    ap.add_argument("--scan", action="store_true", help="list BLE devices")
    ap.add_argument("--start", action="store_true", help="begin a set")
    ap.add_argument("--calibrate", action="store_true",
                    help="run the calibration protocol")
    ap.add_argument("--haptic", type=int, metavar="N",
                    help="fire haptic pattern N and exit")
    ap.add_argument("--duration", type=float, metavar="SEC",
                    help="stop after SEC seconds")
    ap.add_argument("--timeout", type=float, default=10.0,
                    help="scan timeout")
    ap.add_argument("--outdir", default="logs", help="log directory")
    ap.add_argument("--note", default="", help="free text stored in the manifest")

    ap.add_argument("--sim", action="store_true",
                    help="run against the simulated device, no hardware needed")
    ap.add_argument("--speed", type=float, default=1.0,
                    help="simulator time multiplier (20 = twenty times real time)")
    ap.add_argument("--sim-seconds", type=float, default=180.0,
                    metavar="SEC", help="simulated device time to generate")

    ap.add_argument("--plot", action="store_true", help="live view")
    ap.add_argument("--mqtt", action="store_true",
                    help="publish repetitions and events to the backend topics")
    ap.add_argument("--mqtt-host", default="localhost")
    ap.add_argument("--mqtt-port", type=int, default=1883)
    ap.add_argument("--device-id", default="rehabsense-01")
    ap.add_argument("--patient-id", default="demo")
    args = ap.parse_args()

    try:
        asyncio.run(run(args))
    except KeyboardInterrupt:
        print("\ninterrupted")


if __name__ == "__main__":
    main()
