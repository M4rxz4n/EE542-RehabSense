"""
Round-trip the wire format against synthetic frames built the way the
firmware builds them. No hardware needed.

    python3 test_protocol.py
"""

import struct
import sys

import rehab_protocol as p

failures = 0


def check(cond, label):
    global failures
    if cond:
        print(f"  ok:   {label}")
    else:
        print(f"  FAIL: {label}")
        failures += 1


def header(ftype, seq, t_us, n):
    return p.HEADER.pack(ftype, seq, t_us, n)


print("[1] header size and layout")
check(p.HEADER.size == 14, "header is 14 bytes")
h = header(p.FrameType.EMG, 0x11223344, 0xAABBCCDDEEFF0011, 40)
ftype, seq, t_us, n = p.HEADER.unpack(h)
check(ftype == 1 and seq == 0x11223344 and n == 40, "header round-trips")
check(t_us == 0xAABBCCDDEEFF0011, "64-bit timestamp survives")

print("\n[2] EMG frame")
samples = [(i * 10 - 200, -i * 7 + 100) for i in range(40)]
body = b"".join(struct.pack("<hh", a, b) for a, b in samples)
frame = header(p.FrameType.EMG, 7, 1234567, 40) + body
check(len(frame) == 174, f"40-sample frame is {len(frame)} B (expect 174)")
check(len(frame) <= 180, "fits the 180-byte budget for macOS MTU")
got = p.parse(frame)
check(isinstance(got, p.EmgFrame), "decodes as EmgFrame")
check(got.samples == samples, "all 40 sample pairs match")
check(got.seq == 7, "sequence preserved")

print("\n[3] IMU frame")
imu_raw = []
for i in range(6):
    for d in range(2):
        imu_raw += [100 * (i + 1) + d, 200, -300]      # accel, 1/1000 g
        imu_raw += [10 * (i + 1), -20, 30]             # gyro,  1/10 deg/s
body = struct.pack(f"<{len(imu_raw)}h", *imu_raw)
frame = header(p.FrameType.IMU, 3, 99, 6) + body
check(len(frame) == 158, f"6-sample frame is {len(frame)} B (expect 158)")
got = p.parse(frame)
check(isinstance(got, p.ImuFrame), "decodes as ImuFrame")
check(len(got.samples) == 6, "six samples")
accel0, gyro0 = got.samples[0][0]
check(abs(accel0[0] - 0.100) < 1e-6, f"accel scaling: {accel0[0]} g")
check(abs(gyro0[0] - 1.0) < 1e-6, f"gyro scaling: {gyro0[0]} deg/s")

print("\n[4] feature frame")
fmt = struct.Struct("<Q4f2fBHHH")
body = fmt.pack(555, 0.42, 0.08, 148.5, 151.0, 97.5, 4.2,
                int(p.RepState.FLEXED_HOLD), 7, p.COMP_SHOULDER, 0)
frame = header(p.FrameType.FEATURES, 11, 555, 1) + body
got = p.parse(frame)
check(isinstance(got, p.FeatureFrame), "decodes as FeatureFrame")
check(abs(got.envelope[0] - 0.42) < 1e-5, "envelope value")
check(abs(got.elbow_angle_deg - 97.5) < 1e-4, "elbow angle")
check(got.rep_state == p.RepState.FLEXED_HOLD, "rep state")
check(got.rep_count == 7, "rep count")
check(p.comp_names(got.comp_flags) == ["shoulder hike"], "compensation names")

print("\n[5] event frame")
payload = struct.pack("<HB", 3, 88)
frame = header(p.FrameType.EVENT, 0, 777, 1) + bytes(
    [p.Event.REP_COMPLETE, len(payload)]) + payload
got = p.parse(frame)
check(isinstance(got, p.EventFrame), "decodes as EventFrame")
check(got.name == "REP_COMPLETE", f"event name is {got.name}")
check(got.payload == payload, "payload preserved")

print("\n[6] malformed frames are rejected, not silently mis-parsed")
for label, bad in [
    ("truncated header", b"\x01\x02\x03"),
    ("EMG claims more samples than it carries",
     header(p.FrameType.EMG, 1, 1, 40) + b"\x00" * 10),
    ("IMU body too short", header(p.FrameType.IMU, 1, 1, 6) + b"\x00" * 10),
    ("unknown frame type", header(0x7F, 1, 1, 1) + b"\x00" * 4),
]:
    try:
        p.parse(bad)
        check(False, f"{label} -> raised")
    except p.ProtocolError:
        check(True, f"{label} -> raised")

print("\n[7] command builders")
check(p.cmd_start(2) == b"\x01\x02", "START_SESSION")
check(p.cmd_stop() == b"\x02", "STOP_SESSION")
check(p.cmd_ack(0xDEADBEEF) == b"\x06" + struct.pack("<I", 0xDEADBEEF),
      "ACK_SEQ little-endian")
check(p.cmd_backfill(10, 20) == b"\x07" + struct.pack("<II", 10, 20),
      "REQUEST_BACKFILL")

print("\n[8] sustained throughput fits the link")
emg_bps = p.EMG_SAMPLE_RATE_HZ * p.EMG_CHANNELS * 2
imu_bps = p.IMU_SAMPLE_RATE_HZ * 24
total = emg_bps + imu_bps
check(total < 15000, f"{total/1000:.1f} kB/s total, well inside BLE 5 2M PHY")
frames_per_s = p.EMG_SAMPLE_RATE_HZ / 40
check(abs(frames_per_s - 50) < 0.1, f"{frames_per_s:.0f} EMG frames/s")

print(f"\n{'FAILURES PRESENT' if failures else 'all checks passed'} "
      f"({failures} failure{'' if failures == 1 else 's'})")
sys.exit(1 if failures else 0)
