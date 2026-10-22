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

print("\n[9] features_t padding")
# ble_notify_features() memcpy's features_t, which is not packed and leads with
# a uint64_t, so the compiler puts a pad byte after rep_state and sizeof() is
# 40. Reading it as 39 does not fail — it quietly shifts rep_count, comp_flags
# and sig_flags one byte left.
check(p.FEATURES_PADDED.size == 40, "padded layout is 40 B (what firmware sends)")
check(p.FEATURES_PACKED.size == 39, "packed layout would be 39 B")
padded = p.build_features(5, 555, (0.42, 0.08), (148.5, 151.0), 97.5, 4.2,
                          p.RepState.FLEXED_HOLD, 7, p.COMP_SHOULDER, 0)
got = p.parse(padded)
check(got.rep_count == 7, f"rep_count survives the pad (got {got.rep_count})")
check(got.comp_flags == p.COMP_SHOULDER, "comp_flags survives the pad")
check(got.sig_flags == 0, "sig_flags survives the pad")
check(abs(got.elbow_angle_deg - 97.5) < 1e-4, "angle unaffected")

mis = p.FEATURES_PACKED.unpack_from(padded[p.HEADER.size:], 0)
check(mis[8] != 7, "reading the padded frame as packed would give a wrong "
                   f"rep_count ({mis[8]}) — which is why this matters")

packed = p.build_features(5, 555, (0.42, 0.08), (148.5, 151.0), 97.5, 4.2,
                          p.RepState.FLEXED_HOLD, 7, p.COMP_SHOULDER, 0,
                          padded=False)
check(p.parse(packed).rep_count == 7,
      "a packed features_t would still decode, if the firmware is changed")

print("\n[10] frame builders match hand-built frames")
hand = header(p.FrameType.EMG, 7, 1234567, 40) + b"".join(
    struct.pack("<hh", a, b) for a, b in samples)
check(p.build_emg(7, 1234567, samples) == hand, "build_emg matches")
check(len(p.build_emg(7, 0, samples)) == 174, "EMG frame is 174 B")
check(len(p.build_imu(0, 0, [(((0.1, 0.2, -0.3), (1.0, -2.0, 3.0)),) * 2] * 6))
      == 158, "IMU frame is 158 B")
for label, frame in [("EMG", p.build_emg(0, 0, samples)),
                     ("IMU", p.build_imu(0, 0, [(((0.1, 0.2, -0.3),
                                                  (1.0, -2.0, 3.0)),) * 2] * 6)),
                     ("features", padded),
                     ("event", p.build_event(0, p.Event.REP_COMPLETE, b"\x00" * 16))]:
    check(len(frame) <= p.FRAME_MAX_BYTES, f"{label} fits the 180 B budget")

over = False
try:
    p.build_event(0, p.Event.REP_COMPLETE, b"\x00" * 17)
except p.ProtocolError:
    over = True
check(over, "an oversize event payload is refused, not truncated")

print("\n[11] device status")
raw = p.build_status(fw_state=p.FwState.OPERATIONAL, fault_code=p.Fault.NONE,
                     battery_pct=14, battery_mv=3620, signal_quality=(1, 0),
                     seq_oldest=1000, seq_newest=98000, clip_count=(5, 0),
                     flags=p.STATUS_FLAG_GAP_OCCURRED, rep_count=12,
                     host_time_offset_us=-1761100000123456)
check(p.STATUS.size == 40, "device_status_t is 40 B with its padding")
st = p.parse_status(raw)
check(st.state_name == "OPERATIONAL", f"state is {st.state_name}")
check(st.battery_pct == 14 and st.battery_mv == 3620, "battery survives")
check(st.seq_newest == 98000 and st.clip_count == (5, 0), "counters survive")
check(st.gap_occurred, "gap flag is read, not inferred")
check(st.host_time_offset_us == -1761100000123456,
      "64-bit clock offset survives sign and magnitude")

print("\n[12] calibration record")
rec = p.CalibRecord(timestamp=1761100000, emg_rest_rms=(0.004, 0.005),
                    emg_mvc=(0.82, 0.77), mdf_baseline=(96.0, 94.0),
                    angle_min=8.0, angle_max=100.0,
                    flags=p.CALIB_FLAG_MVC_UNRELIABLE)
check(p.CALIB.size == 88, "calib_record_t is 88 B with its padding")
back = p.parse_calib(rec.pack())
check(abs(back.angle_max - 100.0) < 1e-4 and abs(back.rom - 92.0) < 1e-4,
      "ROM round-trips — every band is a fraction of this")
check(back.mvc_unreliable, "unreliable-MVC flag survives")
check(abs(back.emg_mvc[1] - 0.77) < 1e-6, "per-channel MVC survives")

print("\n[13] repetition record inside EVT_REP_COMPLETE")
# Proposed, not yet emitted by the firmware — see rehab_protocol.
rc = p.RepComplete(index=7, score=83, rom_fraction=0.93, cocontraction=0.13,
                   smoothness=0.90, hold_steadiness=0.93, peak_angle_deg=93.3,
                   comp_flags=p.COMP_SHOULDER, duration_ms=2740)
check(len(rc.pack()) == 16, "fits the 16 payload bytes rehab_event_t allows")
back = p.parse_rep_complete(rc.pack())
check(back.index == 7 and back.score == 83, "index and score survive")
check(abs(back.peak_angle_deg - 93.3) < 0.05, "peak angle to a decidegree")
check(back.duration_ms == 2740, "duration survives")
check(back.comp == ["shoulder hike"], "compensation names survive")
evt = p.parse(p.build_event(999, p.Event.REP_COMPLETE, rc.pack()))
check(p.parse_rep_complete(evt.payload).score == 83,
      "survives a round trip through a real event frame")

print("\n[14] command builders added for the full opcode set")
check(p.cmd_calibrate(p.CalibPhase.NEUTRAL) == b"\x03\x03",
      "a single calibration phase can be re-run on its own")
check(p.cmd_abort_calibration() == b"\x04", "ABORT_CALIBRATION")
check(p.cmd_recalibrate() == b"\x05", "REQUEST_RECALIBRATION")
check(p.cmd_get_config() == b"\x09", "GET_CONFIG")
check(p.cmd_set_config(p.tlv(1, b"\x10\x27")) == b"\x08\x01\x02\x10\x27",
      "SET_CONFIG carries TLV")
check(p.cmd_set_time(1761100000123456)[0] == p.Cmd.SET_TIME, "SET_TIME opcode")

print(f"\n{'FAILURES PRESENT' if failures else 'all checks passed'} "
      f"({failures} failure{'' if failures == 1 else 's'})")
sys.exit(1 if failures else 0)
