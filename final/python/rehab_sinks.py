"""
rehab_sinks.py — extra destinations for frames beyond the CSV recorder.

Three things the recorder does not do:

  * MQTT. Repetition records and events go to the topics the Flutter
    application will subscribe to, so the backend is exercised before the phone
    application exists. A broker that is down must never stall the BLE link, so
    paho runs its own network thread, failures are counted rather than raised,
    and nothing here blocks.
  * A byte-exact frame log. frames.bin replays through a changed parser, so a
    protocol change is checked against real captures rather than against
    freshly generated ones. This is the file to keep from a volunteer session.
  * A manifest. Units, sample rates, the calibration record in force and the
    link statistics, written next to the CSVs so a log is still readable in
    six weeks.
"""

from __future__ import annotations

import datetime as dt
import json
import pathlib
import struct
import time

import rehab_protocol as p

# ── byte-exact frame log ───────────────────────────────────────────────
#
# Record layout: u32 ms since the session started, u8 characteristic id,
# u16 length, then the frame verbatim.
_REC = struct.Struct("<IBH")
_CHANNELS = [p.UUID_RAW, p.UUID_EVENTS, p.UUID_STATUS, p.UUID_BACKFILL,
             p.UUID_CALIB]


class FrameLog:
    def __init__(self, path: pathlib.Path) -> None:
        self._fp = open(path, "wb")
        self._t0 = time.time()
        self.frames = 0
        self.bytes = 0

    def write(self, uuid: str, data: bytes) -> None:
        cid = _CHANNELS.index(uuid) if uuid in _CHANNELS else 0xFF
        dt_ms = int((time.time() - self._t0) * 1000)
        self._fp.write(_REC.pack(dt_ms, cid, len(data)) + data)
        self.frames += 1
        self.bytes += len(data)

    def close(self) -> None:
        self._fp.close()


def replay(path) -> list:
    """Yield (dt_ms, uuid, frame) from a frames.bin, re-parsed with the
    current rehab_protocol. Status frames come back as StatusFrame; everything
    else goes through parse()."""
    out = []
    blob = pathlib.Path(path).read_bytes()
    off = 0
    while off + _REC.size <= len(blob):
        dt_ms, cid, n = _REC.unpack_from(blob, off)
        off += _REC.size
        body = blob[off:off + n]
        off += n
        uuid = _CHANNELS[cid] if cid < len(_CHANNELS) else "?"
        try:
            frame = p.parse_status(body) if uuid == p.UUID_STATUS else p.parse(body)
        except p.ProtocolError:
            continue
        out.append((dt_ms, uuid, frame))
    return out


# ── MQTT ───────────────────────────────────────────────────────────────


class MqttPublisher:
    """Publishes to rehabsense/<device_id>/{rep,event,status,online}.

    The topic names and payload shape are a proposal, not a decision — they
    need to match whatever the Flutter client ends up subscribing to. Nothing
    else in the host depends on them, so changing them is a change to this
    file alone.
    """

    def __init__(self, host: str = "localhost", port: int = 1883,
                 device_id: str = "rehabsense-01", patient_id: str = "demo",
                 base: str = "rehabsense", qos: int = 1) -> None:
        self.base = f"{base}/{device_id}"
        self.device_id = device_id
        self.patient_id = patient_id
        self.qos = qos
        self.published = 0
        self.failed = 0
        self.connected = False
        self.session_id = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        self._client = None
        try:
            import paho.mqtt.client as mqtt
        except ImportError:
            print("  mqtt: paho-mqtt not installed, publishing disabled")
            return
        try:
            self._client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2,
                                       client_id=f"rehab-host-{self.session_id}")
            self._client.will_set(f"{self.base}/online", "0", qos=1, retain=True)
            self._client.on_connect = self._on_connect
            self._client.on_disconnect = lambda *a, **k: setattr(self, "connected", False)
            self._client.connect_async(host, port, keepalive=30)
            self._client.loop_start()
            print(f"  mqtt: connecting to {host}:{port}, base topic {self.base}")
        except Exception as exc:                      # noqa: BLE001
            print(f"  mqtt: disabled ({exc})")
            self._client = None

    def _on_connect(self, _c, _u, _f, rc, _props=None) -> None:
        self.connected = int(rc) == 0
        if self.connected:
            self._raw(f"{self.base}/online", "1", retain=True)

    def _raw(self, topic: str, payload: str, retain: bool = False) -> None:
        if self._client is None:
            return
        try:
            info = self._client.publish(topic, payload, qos=self.qos, retain=retain)
            if info.rc == 0:
                self.published += 1
            else:
                self.failed += 1
        except Exception:                             # noqa: BLE001
            self.failed += 1

    def _publish(self, leaf: str, body: dict, retain: bool = False) -> None:
        body.setdefault("device_id", self.device_id)
        body.setdefault("patient_id", self.patient_id)
        body.setdefault("session_id", self.session_id)
        body.setdefault("ts_host", round(time.time(), 3))
        self._raw(f"{self.base}/{leaf}", json.dumps(body, separators=(",", ":")),
                  retain)

    # The device is authoritative: everything published here is what it
    # reported, never something the host worked out from the raw stream.
    def rep(self, rc: p.RepComplete, t_us: int) -> None:
        self._publish("rep", {
            "t_device_us": t_us, "index": rc.index, "score": rc.score,
            "rom_fraction": round(rc.rom_fraction, 3),
            "cocontraction": round(rc.cocontraction, 3),
            "smoothness": round(rc.smoothness, 3),
            "hold_steadiness": round(rc.hold_steadiness, 3),
            "peak_angle_deg": rc.peak_angle_deg,
            "duration_ms": rc.duration_ms,
            "compensation": rc.comp,
        })

    def event(self, fr: p.EventFrame) -> None:
        self._publish("event", {"t_device_us": fr.t_us, "event": fr.name,
                                "payload_hex": fr.payload.hex()})

    def status(self, st: p.StatusFrame) -> None:
        self._publish("status", {
            "state": st.state_name, "fault": st.fault_name,
            "battery_pct": st.battery_pct, "battery_mv": st.battery_mv,
            "rep_count": st.rep_count, "clipping": list(st.clip_count),
            "buffered_seq": [st.seq_oldest, st.seq_newest],
            "gap_occurred": st.gap_occurred,
        }, retain=True)

    def close(self) -> None:
        if self._client is None:
            return
        self._raw(f"{self.base}/online", "0", retain=True)
        try:
            self._client.loop_stop()
            self._client.disconnect()
        except Exception:                             # noqa: BLE001
            pass


# ── manifest ───────────────────────────────────────────────────────────


def write_manifest(outdir: pathlib.Path, *, started: float, counts: dict,
                   gaps: int, bad_frames: int, device: str,
                   calib: p.CalibRecord | None = None, note: str = "",
                   extra: dict | None = None) -> pathlib.Path:
    body = {
        "schema": "rehabsense-session/1",
        "started_utc": dt.datetime.fromtimestamp(started, dt.timezone.utc)
                         .isoformat(timespec="seconds"),
        "ended_utc": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "duration_s": round(time.time() - started, 1),
        "device": device,
        "note": note,
        "frames": dict(counts),
        "gaps": gaps,
        "bad_frames": bad_frames,
        "sample_rates_hz": {
            "emg": p.EMG_SAMPLE_RATE_HZ, "imu": p.IMU_SAMPLE_RATE_HZ,
            "features": p.FEATURE_RATE_HZ,
        },
        "units": {
            "emg": "signed ADC counts, 20-450 Hz band-limited, 60 Hz notched",
            "imu_accel": "g", "imu_gyro": "deg/s",
            "envelope": "fraction of calibrated MVC",
            "mdf": "Hz, zero below the activation floor",
            "angle": "degrees", "t_us": "monotonic device clock, microseconds",
        },
        "batching": {"emg_per_frame": p.BLE_EMG_BATCH,
                     "imu_per_frame": p.BLE_IMU_BATCH,
                     "frame_max_bytes": p.FRAME_MAX_BYTES},
    }
    if calib is not None:
        body["calibration"] = {
            "version": calib.version, "timestamp": calib.timestamp,
            "emg_rest_rms": list(calib.emg_rest_rms),
            "emg_mvc": list(calib.emg_mvc),
            "mdf_baseline": list(calib.mdf_baseline),
            "angle_min": calib.angle_min, "angle_max": calib.angle_max,
            "rom": calib.rom, "mvc_unreliable": calib.mvc_unreliable,
        }
    if extra:
        body.update(extra)
    path = outdir / "manifest.json"
    path.write_text(json.dumps(body, indent=2))
    return path
