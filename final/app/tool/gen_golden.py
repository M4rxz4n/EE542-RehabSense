"""Regenerate the golden wire vectors in test/protocol_golden_test.dart.

    python3 tool/gen_golden.py

Prints JSON. The expectations in the Dart test come from rehab_protocol.py
itself, so the port is checked against the implementation the firmware was
validated against rather than against a re-reading of the header comments.

Run this after any DELIBERATE change to the wire format, paste the new byte
strings into the test, and change the firmware in the same commit. If it
produces different bytes and you did not mean to change the format, something
drifted and the test is doing its job.
"""
import os
import sys
import json

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "..", "python"))

import rehab_protocol as P  # noqa: E402


def hexs(b: bytes) -> str:
    return b.hex()


out = {}

out["sizes"] = {
    "EMG_N_CHANNELS": P.EMG_N_CHANNELS,
    "HEADER": P.HEADER.size,
    "FEATURES_PADDED": P.FEATURES_PADDED.size,
    "FEATURES_PACKED": P.FEATURES_PACKED.size,
    "STATUS": P.STATUS.size,
    "CALIB": P.CALIB.size,
    "XFER": P.XFER.size,
    "REP_COMPLETE_PAYLOAD": P.REP_COMPLETE_PAYLOAD.size,
    "FRAME_MAX_BYTES": P.FRAME_MAX_BYTES,
    "BLE_EMG_BATCH": P.BLE_EMG_BATCH,
    "BLE_IMU_BATCH": P.BLE_IMU_BATCH,
    "EMG_FRAME_BYTES": P.EMG_FRAME_BYTES,
}

# ── EMG frame ──────────────────────────────────────────────────────────
emg_samples = [(v,) for v in
               (0, 1, -1, 32767, -32768, 1234, -4321, 999, -17, 5)]
out["emg"] = {
    "seq": 7,
    "t_us": 1234567890123,
    "samples": [list(s) for s in emg_samples],
    "bytes": hexs(P.build_emg(7, 1234567890123, emg_samples)),
}

# ── IMU frame ──────────────────────────────────────────────────────────
imu_samples = [
    (((0.01, -0.02, 0.98), (1.5, -2.5, 0.0)),
     ((0.5, 0.5, 0.7), (-10.0, 20.0, 30.0))),
    (((0.0, 0.0, 1.0), (0.0, 0.0, 0.0)),
     ((-0.25, 0.125, 0.5), (100.0, -100.0, 0.5))),
]
out["imu"] = {
    "seq": 11,
    "t_us": 42,
    "bytes": hexs(P.build_imu(11, 42, imu_samples)),
}

# ── Feature frame, both layouts ────────────────────────────────────────
feat_args = dict(
    envelope=[0.42],
    mdf=[88.5],
    elbow_angle_deg=97.25,
    upper_arm_dev_deg=-3.5,
    rep_state=int(P.RepState.ECCENTRIC),
    rep_count=13,
    comp_flags=P.COMP_SHOULDER | P.COMP_SWING,
    sig_flags=P.SIG_MVC_UNRELIABLE,
    activation_on=True,
)
out["features_padded"] = {
    "seq": 3,
    "t_us": 777777,
    **{k: v for k, v in feat_args.items()},
    "bytes": hexs(P.build_features(3, 777777, **feat_args, padded=True)),
}
out["features_packed"] = {
    "bytes": hexs(P.build_features(3, 777777, **feat_args, padded=False)),
}

# ── Event frame ────────────────────────────────────────────────────────
rc = P.RepComplete(index=4, score=82, rom_fraction=0.91, cocontraction=0.17,
                   smoothness=0.64, hold_steadiness=0.55,
                   peak_angle_deg=104.3,
                   comp_flags=P.COMP_TRUNK, duration_ms=2450)
out["rep_complete"] = {
    "payload": hexs(rc.pack()),
    "frame": hexs(P.build_event(5555, P.Event.REP_COMPLETE, rc.pack())),
    "fields": {
        "index": rc.index, "score": rc.score,
        "rom_fraction": rc.rom_fraction, "cocontraction": rc.cocontraction,
        "smoothness": rc.smoothness, "hold_steadiness": rc.hold_steadiness,
        "peak_angle_deg": rc.peak_angle_deg, "comp_flags": rc.comp_flags,
        "duration_ms": rc.duration_ms,
    },
}
out["event_empty"] = {
    "frame": hexs(P.build_event(9, P.Event.SET_COMPLETE, b"")),
}

# ── Device status ──────────────────────────────────────────────────────
status_args = dict(fw_state=int(P.FwState.OPERATIONAL), fault_code=0,
                   battery_pct=73, battery_mv=3812,
                   signal_quality=(91,), seq_oldest=100, seq_newest=4096,
                   clip_count=(7,),
                   flags=P.STATUS_FLAG_PSRAM_BACKED | P.STATUS_FLAG_GAP_OCCURRED,
                   rep_count=13, host_time_offset_us=-123456789)
out["status"] = {**status_args,
                 "signal_quality": list(status_args["signal_quality"]),
                 "clip_count": list(status_args["clip_count"]),
                 "bytes": hexs(P.build_status(**status_args))}

# ── Calibration record ─────────────────────────────────────────────────
cal = P.CalibRecord(
    version=P.CALIB_RECORD_VERSION, timestamp=1792814300,
    emg_rest_rms=(0.012,), emg_rest_sd=(0.003,), emg_mvc=(0.84,),
    mdf_baseline=(95.5,),
    gyro_bias=(0.1, -0.2, 0.3, -0.4, 0.5, -0.6),
    q_upper0=(0.9239, 0.0, 0.3827, 0.0),
    q_fore0=(1.0, 0.0, 0.0, 0.0),
    flexion_axis=(0.0, 0.0, 1.0),
    angle_min=8.5, angle_max=118.25,
    flags=P.CALIB_FLAG_MVC_UNRELIABLE)
out["calib"] = {"bytes": hexs(cal.pack()), "rom": cal.rom}

# ── Transfer info ──────────────────────────────────────────────────────
xf = P.XFER.pack(int(P.XferState.READY), 1, 240,
                 # 192.168.4.1 as the device stores it (little-endian octets)
                 int.from_bytes(bytes([192, 168, 4, 1]), "little"),
                 8080, 1048576,
                 b"RehabSense-7A3F", b"curl-ankle-92")
out["xfer"] = {"bytes": hexs(xf), "expect_ipv4": "192.168.4.1",
               "expect_ssid": "RehabSense-7A3F",
               "expect_password": "curl-ankle-92"}

# ── Commands ───────────────────────────────────────────────────────────
out["commands"] = {
    "start": hexs(P.cmd_start(0)),
    "stop": hexs(P.cmd_stop()),
    "calibrate_all": hexs(P.cmd_calibrate(P.CalibPhase.ALL)),
    "calibrate_biceps": hexs(P.cmd_calibrate(P.CalibPhase.BICEPS)),
    "abort_calibration": hexs(P.cmd_abort_calibration()),
    "get_config": hexs(P.cmd_get_config()),
    "recalibrate": hexs(P.cmd_recalibrate()),
    "ack_4096": hexs(P.cmd_ack(4096)),
    "backfill_100_200": hexs(P.cmd_backfill(100, 200)),
    "haptic_test_rest": hexs(P.cmd_haptic_test(P.HapticPattern.REST)),
    "set_time": hexs(P.cmd_set_time(1792814300123456)),
    "power_off": hexs(P.cmd_power_off()),
}

# ── Config TLV ─────────────────────────────────────────────────────────
tlv_block = (P.cfg_u16(P.CfgTag.HOLD_MS, 1500)
             + P.cfg_u8(P.CfgTag.REP_TARGET, 12)
             + P.cfg_f32(P.CfgTag.TARGET_ANGLE, 105.0)
             + P.cfg_f32(P.CfgTag.TEMPO, 1.25, 3.0)
             + P.cfg_f32(P.CfgTag.COMP_THRESH, 20.0, 10.0, 30.0)
             + P.cfg_f32(P.CfgTag.WEIGHTS, 0.2, 0.2, 0.2, 0.2, 0.2)
             + P.cfg_u8(P.CfgTag.RAW_STREAM, 0))
out["config_tlv"] = {
    "block": hexs(tlv_block),
    "set_config_cmd": hexs(P.cmd_set_config(tlv_block)),
    "tags": {str(k): hexs(v) for k, v in P.parse_config_tlv(tlv_block).items()},
}

print(json.dumps(out, indent=1))
