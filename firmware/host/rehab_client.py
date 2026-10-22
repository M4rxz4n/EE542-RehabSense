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

try:
    from bleak import BleakClient, BleakScanner
except ImportError:
    sys.exit("bleak is not installed.  pip install bleak")

import rehab_protocol as p


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

    def close(self):
        for f in self._files.values():
            f.close()


class Session:
    def __init__(self, rec: Recorder):
        self.rec = rec
        self.queue: asyncio.Queue = asyncio.Queue(maxsize=4096)
        self.highest_seq = 0
        self.gaps = 0
        self.counts = {"emg": 0, "imu": 0, "features": 0, "events": 0}
        self.bad_frames = 0
        self._expect_seq = None
        self.rep_count = 0

    def on_notify(self, _sender, data: bytearray):
        """Runs on the event loop — keep it to an enqueue."""
        try:
            self.queue.put_nowait(bytes(data))
        except asyncio.QueueFull:
            self.gaps += 1

    async def drain(self, client: BleakClient):
        while True:
            raw = await self.queue.get()
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
                self._print_live(fr)

            elif isinstance(fr, p.EventFrame):
                self.counts["events"] += 1
                self.rec.event(fr)
                self._print_event(fr)

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
        for d in await BleakScanner.discover(timeout=args.timeout):
            print(f"  {d.address}  {d.name or '(no name)'}")
        return

    device = await find_device(args.timeout)
    if device is None:
        sys.exit(f"no {p.DEVICE_NAME} found. Is it powered and advertising?")

    rec = Recorder(pathlib.Path(args.outdir))
    sess = Session(rec)

    async with BleakClient(device) as client:
        print(f"connected (MTU {getattr(client, 'mtu_size', '?')})")

        await client.start_notify(p.UUID_RAW, sess.on_notify)
        await client.start_notify(p.UUID_EVENTS, sess.on_notify)
        await client.start_notify(p.UUID_BACKFILL, sess.on_notify)

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
        elif args.start:
            await client.write_gatt_char(p.UUID_CONTROL, p.cmd_start(0),
                                         response=False)
            print("set started")

        drain = asyncio.create_task(sess.drain(client))
        try:
            if args.duration:
                await asyncio.sleep(args.duration)
            else:
                print("streaming — Ctrl-C to stop\n")
                while client.is_connected:
                    await asyncio.sleep(0.5)
        except asyncio.CancelledError:
            pass
        finally:
            drain.cancel()
            try:
                await client.write_gatt_char(p.UUID_CONTROL, p.cmd_stop(),
                                             response=False)
            except Exception:
                pass
            rec.close()
            sess.summary()


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
    args = ap.parse_args()

    try:
        asyncio.run(run(args))
    except KeyboardInterrupt:
        print("\ninterrupted")


if __name__ == "__main__":
    main()
