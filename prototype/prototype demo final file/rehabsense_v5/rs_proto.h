// rs_proto.h - the team BLE wire format (final/firmware/main/ble/ble_service.h and
// final/python/rehab_protocol.py in the EE542-RehabSense repo).
//
// Pure byte packing, no hardware and no NimBLE, so it can be tested on a laptop
// against rehab_protocol.py. Everything little-endian. Single EMG channel
// (EMG_N_CHANNELS = 1), as in the repo. Taken unchanged from rehabsense_v4.
#pragma once
#include <stdint.h>
#include <stddef.h>

namespace wire {

constexpr size_t HEADER_BYTES = 14;     // type u8, seq u32, t_us u64, n u8
constexpr size_t FRAME_MAX    = 180;
constexpr size_t IMU_BATCH    = 6;      // 6 x 24 B + 14 = 158 B

enum FrameType : uint8_t { FT_EMG = 0x01, FT_IMU = 0x02, FT_FEATURES = 0x03, FT_EVENT = 0x04 };

enum Event : uint8_t {
  E_REP_START = 0x01, E_REP_COMPLETE, E_REP_ABANDONED, E_HOLD_START, E_HOLD_COMPLETE,
  E_COMP_SHOULDER, E_COMP_TRUNK, E_COMP_SWING, E_START_POS_OK, E_START_POS_BAD,
  E_FATIGUE_WARN, E_SIGNAL_DEGRADED, E_CALIB_PHASE_DONE, E_SET_COMPLETE, E_FAULT,
  E_STATE_CHANGE, E_PASSIVE_SWING,
};

enum FwState : uint8_t { S_OFF = 0, S_BOOT, S_STANDBY, S_DONNING, S_CALIBRATION, S_OPERATIONAL, S_FAULT };

enum Fault : uint8_t {
  F_NONE = 0, F_WATCHDOG, F_IMU_UNRESPONSIVE, F_EMG_UNRESPONSIVE, F_I2C, F_HAPTIC,
  F_PSRAM, F_SELFTEST, F_CONTACT_LOST, F_BATTERY_LOW,
};

enum Cmd : uint8_t {
  C_START_SESSION = 0x01, C_STOP_SESSION, C_START_CALIBRATION, C_ABORT_CALIBRATION,
  C_REQUEST_RECALIBRATION, C_ACK_SEQ, C_REQUEST_BACKFILL, C_SET_CONFIG, C_GET_CONFIG,
  C_HAPTIC_TEST, C_SET_TIME, C_POWER_OFF, C_START_TRANSFER, C_STOP_TRANSFER,
  C_TEXT = 0x20,                   // RehabSense extension: ASCII Serial-Monitor command (c, n, z, g, r, b, t110 ...)
  C_INTERNAL_CALIB_WRITE = 0xF0,   // a write to the calibration characteristic
};

enum CalibPhase : uint8_t {
  CP_IDLE = 0, CP_CONTACT, CP_REST, CP_STRAIGHT, CP_BICEPS, CP_TRICEPS, CP_SWEEP,
  CP_ALL, CP_DONE, CP_FAILED,
};

enum RepState : uint8_t { R_READY = 0, R_CONCENTRIC, R_PEAK, R_ECCENTRIC, R_EXTENDED_HOLD };

// Team haptic pattern ids (HAPTIC_TEST payload)
enum TeamPattern : uint8_t {
  TP_NONE = 0, TP_TICK, TP_REP_CLEAN, TP_REP_FLAGGED, TP_SET_COMPLETE, TP_REST, TP_FAULT,
  TP_SOFT_CLICK, TP_REP_CLEAN_THEN_SET, TP_REP_FLAGGED_THEN_SET,
};

enum CfgTag : uint8_t {
  T_HOLD_MS = 0x01, T_HOLD_VEL, T_REP_TARGET, T_SET_COUNT, T_REST_SECONDS, T_TARGET_ANGLE,
  T_START_ANGLE, T_FINISH_ANGLE, T_TEMPO, T_COMP_THRESH, T_WEIGHTS, T_DEDUCTIONS,
  T_RAW_STREAM, T_CHANNEL_ROLES,
};

constexpr uint16_t COMP_SHOULDER = 1, COMP_TRUNK = 2, COMP_SWING = 4;
constexpr uint16_t COMP_DROP = 8;      // RehabSense extension: arm dropped instead of lowered
constexpr uint16_t SIG_DEGRADED_A = 1;

struct Features {
  uint64_t t_us;
  float    envelope;     // biceps, fraction of calibrated max (1.0 = 100 %)
  float    mdf;          // Hz, 0 = not measured
  float    elbow_deg;
  float    upper_dev_deg;
  uint8_t  rep_state;    // RepState
  uint16_t rep_count;    // in the current set
  uint16_t comp_flags;
  uint16_t sig_flags;
  uint8_t  activation_on;
};

struct RepComplete {       // 16-byte REP_COMPLETE payload (rehab_protocol.py)
  uint16_t index;          // 1-based within the set
  uint8_t  score;          // 0..100
  uint8_t  rom_pct, cocon_pct, smooth_pct, hold_pct;
  int16_t  peak_dd;        // decidegrees
  uint16_t comp_flags;
  uint32_t duration_ms;
};

struct Status {            // device_status_t, packed, 29 bytes
  uint8_t  fw_state, fault, battery_pct;
  uint16_t battery_mv;
  uint8_t  signal_quality;
  uint32_t seq_oldest, seq_newest, clip_count;
  uint8_t  flags;
  uint16_t rep_count;
  int64_t  host_offset_us;
};

struct Calib {             // calib_record_t, 104 bytes
  uint32_t version, timestamp;
  float rest_rms, rest_sd, mvc, mdf_baseline;
  float gyro_bias[6];
  float q_upper0[4], q_fore0[4];
  float flexion_axis[3];
  float angle_min, angle_max;
  uint8_t flags;
};

struct Config {            // the settings carried in the TLV block
  uint8_t  rep_target, set_count;
  uint16_t rest_seconds;
  float    target_deg, start_deg, finish_deg;
  float    tempo_min, tempo_max;
  float    shoulder_deg, trunk_deg, swing_dps;
  float    ded_shoulder, ded_trunk, ded_swing;
  uint8_t  raw_stream;
};

constexpr size_t FEATURES_BYTES = HEADER_BYTES + 32;   // packed layout
constexpr size_t STATUS_BYTES   = 29;
constexpr size_t CALIB_BYTES    = 104;

size_t header(uint8_t *out, uint8_t type, uint32_t seq, uint64_t t_us, uint8_t n);
size_t features(uint8_t *out, uint32_t seq, const Features &f);
size_t event(uint8_t *out, uint64_t t_us, uint8_t id, const uint8_t *payload, uint8_t len);
size_t rep_complete(uint8_t *out16, const RepComplete &r);
// accel in g, gyro in deg/s: up[i] = {ax, ay, az, gx, gy, gz}
size_t imu(uint8_t *out, uint32_t seq, uint64_t t_us, const float up[][6], const float fo[][6], uint8_t n);
size_t status(uint8_t *out, const Status &s);
size_t calib(uint8_t *out, const Calib &c);
size_t config_tlv(uint8_t *out, size_t cap, const Config &c);
// Parse a SET_CONFIG TLV block into `c` (fields not present are left alone).
// Unknown tags are skipped; a known tag with the wrong length rejects the
// whole block (returns -1, `c` unchanged). Returns the number of tags applied.
int    config_parse(const uint8_t *tlv, size_t len, Config &c);

}  // namespace wire
