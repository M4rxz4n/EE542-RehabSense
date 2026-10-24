"""
test_session.py — pin the downloaded-session layout.

These tests build records from the C struct definitions in
firmware/main/storage/session_format.h, compile them with the host compiler,
and parse the result with rehab_session.py. The point is that Python is tested
against C's idea of the bytes rather than against itself — a parser validated
only on data it generated will agree with its own mistakes.

The IMU test is the one that matters most. rec_imu_t is

    int16_t accel[2][3];
    int16_t gyro[2][3];

so the bytes are grouped by KIND first and sensor second. Reading them as
[sample, sensor, kind, axis] without a transpose swaps the forearm's
accelerometer for the upper arm's gyroscope — and still produces a smooth,
plausible-looking trace, which is how a bug like that survives a demo and
surfaces weeks later as "the compensation detection seems off". This test
caught exactly that during development.

Runs with no hardware, no ESP-IDF and no device. Needs a C compiler and NumPy.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import rehab_session as rs  # noqa: E402

# Mirrors session_format.h. Kept here verbatim rather than #included so the
# test fails if the header changes and this file does not — which is the
# notification you want.
GENERATOR_C = r"""
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct __attribute__((packed)) { int16_t ch[2]; } rec_emg_t;
typedef struct __attribute__((packed)) { int16_t accel[2][3], gyro[2][3]; } rec_imu_t;
typedef struct __attribute__((packed)) {
    uint32_t t_ms; int16_t envelope[2], mdf[2], elbow_angle, upper_arm_dev;
    uint16_t rep_count; uint8_t rep_state, comp_flags, sig_flags, activation_on;
} rec_feature_t;
typedef struct __attribute__((packed)) {
    uint32_t t_ms; uint8_t id, payload_len, payload[16];
} rec_event_t;
typedef struct __attribute__((packed)) {
    uint32_t t_start_ms, t_end_ms; uint16_t index;
    int16_t peak_angle, rom_fraction, tempo_ms, activation,
            cocontraction, smoothness, hold_steadiness;
    uint16_t comp_flags; uint8_t velocity_peaks, score;
} rec_rep_t;

/* The sizes the firmware asserts. If the host compiler disagrees the layout
   is not what either side thinks it is. */
_Static_assert(sizeof(rec_emg_t)     ==  4, "rec_emg_t");
_Static_assert(sizeof(rec_imu_t)     == 24, "rec_imu_t");
_Static_assert(sizeof(rec_feature_t) == 22, "rec_feature_t");
_Static_assert(sizeof(rec_event_t)   == 22, "rec_event_t");
_Static_assert(sizeof(rec_rep_t)     == 28, "rec_rep_t");

int main(void) {
    FILE *f;

    f = fopen("emg.bin", "wb");
    for (int i = 0; i < 200; i++) {
        rec_emg_t r = { { (int16_t)(i * 7 - 500), (int16_t)(-i * 3) } };
        fwrite(&r, sizeof r, 1, f);
    }
    fclose(f);

    /* Distinct per sensor AND per kind, so a transposed read cannot
       accidentally agree: accel is ~1000×(sensor+1), gyro is ~10×. */
    f = fopen("imu.bin", "wb");
    for (int i = 0; i < 10; i++) {
        rec_imu_t r;
        for (int d = 0; d < 2; d++)
            for (int a = 0; a < 3; a++) {
                r.accel[d][a] = (int16_t)(1000 * (d + 1) + a);
                r.gyro[d][a]  = (int16_t)(10 * (i + 1) + a + d);
            }
        fwrite(&r, sizeof r, 1, f);
    }
    fclose(f);

    f = fopen("features.bin", "wb");
    for (int i = 0; i < 5; i++) {
        rec_feature_t r = { 0 };
        r.t_ms          = (uint32_t)(i * 20);
        r.envelope[0]   = (int16_t)(i * 250);
        r.envelope[1]   = (int16_t)(i * 100);
        r.mdf[0]        = (int16_t)(900 - i * 10);
        r.mdf[1]        = (int16_t)(850 - i * 5);
        r.elbow_angle   = (int16_t)(i * 150);
        r.upper_arm_dev = (int16_t)(i * 20);
        r.rep_count     = (uint16_t)i;
        r.rep_state     = (uint8_t)(i % 5);
        r.comp_flags    = (uint8_t)(i == 3 ? 0x01 : 0);
        r.activation_on = (uint8_t)(i > 1);
        fwrite(&r, sizeof r, 1, f);
    }
    fclose(f);

    f = fopen("events.bin", "wb");
    {
        rec_event_t a = { 0 };
        a.t_ms = 1234; a.id = 0x02; a.payload_len = 3;
        memcpy(a.payload, "\x01\x02\x03", 3);
        fwrite(&a, sizeof a, 1, f);
        rec_event_t b = { 0 };
        b.t_ms = 5678; b.id = 0x06;
        fwrite(&b, sizeof b, 1, f);
    }
    fclose(f);

    f = fopen("reps.bin", "wb");
    {
        rec_rep_t r = { 0 };
        r.t_start_ms = 1000; r.t_end_ms = 3500; r.index = 1;
        r.peak_angle = 1120; r.rom_fraction = 940; r.tempo_ms = 2500;
        r.activation = 620;  r.cocontraction = 180;
        r.smoothness = 870;  r.hold_steadiness = 910;
        r.comp_flags = 0x01; r.velocity_peaks = 2; r.score = 83;
        fwrite(&r, sizeof r, 1, f);
    }
    fclose(f);
    return 0;
}
"""

MANIFEST = {
    "format_version": rs.SESSION_FORMAT_VERSION,
    "sealed": True, "gap_occurred": False, "psram_backed": True,
    "start_us": 1_000_000, "end_us": 11_000_000,
    "emg_sample_rate_hz": 2000, "imu_sample_rate_hz": 100,
    "feature_rate_hz": 50, "emg_channels": 2,
    "scales": {"envelope": 1000.0, "mdf": 10.0, "angle": 10.0,
               "accel": 1000.0, "gyro": 10.0, "fraction": 1000.0,
               "seconds": 1000.0},
    "streams": {
        "emg":      {"path": "/emg.bin",      "record_bytes": 4,  "count": 200, "first": 0},
        "imu":      {"path": "/imu.bin",      "record_bytes": 24, "count": 10,  "first": 0},
        "features": {"path": "/features.bin", "record_bytes": 22, "count": 5,   "first": 0},
        "events":   {"path": "/events.bin",   "record_bytes": 22, "count": 2,   "first": 0},
        "reps":     {"path": "/reps.bin",     "record_bytes": 28, "count": 1,   "first": 0},
    },
}


def _build_session(dest: Path) -> None:
    src = dest / "gen.c"
    src.write_text(GENERATOR_C)
    exe = dest / "gen"
    subprocess.run(["cc", "-std=c11", "-Wall", "-Werror", "-o", str(exe), str(src)],
                   check=True, capture_output=True)
    subprocess.run([str(exe)], cwd=dest, check=True)
    (dest / "manifest.json").write_text(json.dumps(MANIFEST, indent=2))


class SessionLayout(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.mkdtemp()
        cls.dir = Path(cls._tmp) / "session"
        cls.dir.mkdir()
        _build_session(cls.dir)
        cls.s = rs.load(cls.dir)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls._tmp, ignore_errors=True)

    def test_record_sizes_match_the_header(self):
        self.assertEqual(rs.EMG_REC.size, 4)
        self.assertEqual(rs.IMU_REC.size, 24)
        self.assertEqual(rs.FEATURE_REC.size, 22)
        self.assertEqual(rs.EVENT_REC.size, 22)
        self.assertEqual(rs.REP_REC.size, 28)

    def test_features_decode_with_scale_factors(self):
        f = self.s.features[3]
        self.assertAlmostEqual(f.t_s, 0.060)
        self.assertEqual(f.envelope, (0.75, 0.30))
        self.assertEqual(f.mdf, (87.0, 83.5))
        self.assertAlmostEqual(f.elbow_angle_deg, 45.0)
        self.assertAlmostEqual(f.upper_arm_dev_deg, 6.0)
        self.assertEqual(f.rep_state_name, "ECCENTRIC")
        self.assertEqual(rs.comp_flags_to_names(f.comp_flags), ["SHOULDER"])
        self.assertTrue(f.activation_on)

    def test_reps_decode(self):
        r = self.s.reps[0]
        self.assertEqual(r.index, 1)
        self.assertAlmostEqual(r.peak_angle_deg, 112.0)
        self.assertAlmostEqual(r.rom_fraction, 0.94)
        self.assertAlmostEqual(r.tempo_s, 2.5)
        self.assertAlmostEqual(r.duration_s, 2.5)
        self.assertEqual(r.score, 83)
        self.assertEqual(r.compensations, ["SHOULDER"])

    def test_events_decode_with_truncated_payload(self):
        self.assertEqual(self.s.events[0].name, "REP_COMPLETE")
        self.assertEqual(self.s.events[0].payload, b"\x01\x02\x03")
        self.assertEqual(self.s.events[1].name, "COMPENSATION_SHOULDER")
        self.assertEqual(self.s.events[1].payload, b"")

    def test_emg_is_channel_interleaved(self):
        e = self.s.emg_array()
        self.assertEqual(e.shape, (200, 2))
        self.assertEqual(e[0].tolist(), [-500, 0])
        self.assertEqual(e[1].tolist(), [-493, -3])

    def test_imu_sensor_and_kind_are_not_transposed(self):
        """The regression this whole file is really for.

        accel[2][3] then gyro[2][3] means the bytes run accel-sensor0,
        accel-sensor1, gyro-sensor0, gyro-sensor1. An untransposed read
        returns the gyro where the accelerometer should be, at 1/100 the
        magnitude, which looks like a quiet sensor rather than a wrong one.
        """
        import numpy as np
        i = self.s.imu_array()           # [sample, sensor, kind, axis]
        self.assertEqual(i.shape, (10, 2, 2, 3))

        # Upper arm (0) accel ≈ 1.000–1.002 g; forearm (1) accel ≈ 2.000 g.
        self.assertTrue(np.allclose(i[0, 0, 0], [1.000, 1.001, 1.002]))
        self.assertTrue(np.allclose(i[0, 1, 0], [2.000, 2.001, 2.002]))

        # Gyros are an order of magnitude smaller, and differ by sensor.
        self.assertTrue(np.allclose(i[0, 0, 1], [1.0, 1.1, 1.2]))
        self.assertTrue(np.allclose(i[0, 1, 1], [1.1, 1.2, 1.3]))

        # A check that does not depend on knowing the fixture's exact values:
        # every accelerometer reading here is between 1 and 2 g. Under a
        # transpose one of those slots holds gyro counts divided by the
        # accelerometer scale — a hundred times smaller — so the range check
        # fails even if someone later changes the numbers above.
        accel = i[:, :, 0, :]
        self.assertGreaterEqual(float(accel.min()), 0.9)
        self.assertLessEqual(float(accel.max()), 2.1)

    def test_timebases(self):
        import numpy as np
        self.assertTrue(np.allclose(self.s.emg_time()[:3], [0, 1 / 2000, 2 / 2000]))
        self.assertTrue(np.allclose(self.s.imu_time()[:3], [0, 0.01, 0.02]))

    def test_summary_mentions_counts(self):
        text = self.s.summary()
        self.assertIn("1 repetitions counted", text)
        self.assertIn("1 flagged", text)


class FormatGuards(unittest.TestCase):
    """A file this parser cannot read must say so, not read it anyway."""

    def setUp(self):
        self._tmp = tempfile.mkdtemp()
        self.dir = Path(self._tmp) / "session"
        self.dir.mkdir()
        _build_session(self.dir)

    def tearDown(self):
        shutil.rmtree(self._tmp, ignore_errors=True)

    def _rewrite_manifest(self, **changes):
        m = json.loads((self.dir / "manifest.json").read_text())
        m.update(changes)
        (self.dir / "manifest.json").write_text(json.dumps(m))

    def test_future_format_version_is_refused(self):
        self._rewrite_manifest(format_version=rs.SESSION_FORMAT_VERSION + 1)
        with self.assertRaises(ValueError) as cm:
            rs.load(self.dir)
        self.assertIn("format", str(cm.exception))

    def test_record_size_disagreement_is_refused(self):
        m = json.loads((self.dir / "manifest.json").read_text())
        m["streams"]["features"]["record_bytes"] = 24
        (self.dir / "manifest.json").write_text(json.dumps(m))
        with self.assertRaises(ValueError) as cm:
            rs.load(self.dir)
        self.assertIn("disagree", str(cm.exception))

    def test_gap_flag_is_surfaced(self):
        self._rewrite_manifest(gap_occurred=True)
        s = rs.load(self.dir)
        self.assertTrue(s.has_gap)
        self.assertIn("incomplete", s.summary())


if __name__ == "__main__":
    unittest.main(verbosity=2)
