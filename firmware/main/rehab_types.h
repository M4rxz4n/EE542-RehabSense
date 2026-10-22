/*
 * rehab_types.h — types shared across the firmware
 *
 * Wire-format structs (anything crossing BLE) are packed and little-endian.
 * Internal structs are not packed.
 */

#ifndef REHAB_TYPES_H
#define REHAB_TYPES_H

#include <stdint.h>
#include <stdbool.h>
#include "rehab_config.h"

/* ── Firmware state ──────────────────────────────────────────────────── */

typedef enum {
    FW_STATE_OFF = 0,
    FW_STATE_BOOT,
    FW_STATE_STANDBY,
    FW_STATE_DONNING_CHECK,
    FW_STATE_CALIBRATION,
    FW_STATE_OPERATIONAL,
    FW_STATE_FAULT,
} fw_state_t;

typedef enum {
    FAULT_NONE = 0,
    FAULT_WATCHDOG,
    FAULT_IMU_UNRESPONSIVE,
    FAULT_EMG_UNRESPONSIVE,
    FAULT_I2C_UNRECOVERABLE,
    FAULT_HAPTIC_CALIB_FAILED,
    FAULT_PSRAM_MISSING,
    FAULT_SELFTEST,
} fault_code_t;

/* ── Repetition cycle ────────────────────────────────────────────────── */

typedef enum {
    REP_WAIT_START = 0,   /* posture outside tolerance, counter frozen */
    REP_EXTENDED_HOLD,    /* holding at extension, arming               */
    REP_CONCENTRIC,       /* angle rising                               */
    REP_FLEXED_HOLD,      /* holding at the top; rep counts at 1.0 s    */
    REP_ECCENTRIC,        /* angle falling                              */
} rep_state_t;

/* ── Sample frames ───────────────────────────────────────────────────── */

#define EMG_FLAG_CLIP_A    (1u << 0)
#define EMG_FLAG_CLIP_B    (1u << 1)
#define EMG_FLAG_OVERRUN   (1u << 2)
#define EMG_FLAG_STALE     (1u << 3)

typedef struct {
    int32_t  ch[EMG_N_CHANNELS];  /* signed, driver-normalised, zero-centred */
    uint64_t t_us;                /* shared monotonic timebase               */
    uint8_t  flags;
} emg_frame_t;

typedef struct {
    float    accel[3];            /* g      */
    float    gyro[3];             /* deg/s  */
    uint64_t t_us;
} imu_sample_t;

typedef struct {
    float w, x, y, z;
} quat_t;

/* ── Derived features, produced at FEATURE_RATE_HZ ───────────────────── */

#define SIG_FLAG_DEGRADED_A  (1u << 0)
#define SIG_FLAG_DEGRADED_B  (1u << 1)
#define SIG_FLAG_MVC_UNRELIABLE (1u << 2)

#define COMP_FLAG_SHOULDER   (1u << 0)
#define COMP_FLAG_TRUNK      (1u << 1)
#define COMP_FLAG_SWING      (1u << 2)

typedef struct {
    uint64_t t_us;
    float    envelope[EMG_N_CHANNELS];  /* %MVC, 0..1+ */
    float    mdf[EMG_N_CHANNELS];       /* Hz, 0 when below activation */
    float    elbow_angle_deg;
    float    upper_arm_dev_deg;         /* from calibrated neutral */
    uint8_t  rep_state;                 /* rep_state_t */
    uint16_t rep_count;
    uint16_t comp_flags;
    uint16_t sig_flags;
} features_t;

/* ── Repetition result ───────────────────────────────────────────────── */

typedef struct {
    uint16_t index;                /* 1-based within the set */
    uint64_t t_start_us;
    uint64_t t_end_us;
    float    peak_angle_deg;
    float    rom_fraction;         /* of calibrated ROM */
    float    activation;           /* integrated agonist %MVC, concentric */
    float    cocontraction;        /* antagonist/agonist ratio */
    float    smoothness;           /* 0..1, inverse normalised jerk */
    float    hold_steadiness;      /* 0..1, inverse angle variance */
    uint16_t comp_flags;
    uint8_t  score;                /* 0..100 */
} rep_result_t;

/* ── Calibration record, persisted to NVS ────────────────────────────── */

#define CALIB_FLAG_MVC_UNRELIABLE   (1u << 0)
#define CALIB_FLAG_CLINICIAN_OVERRIDE (1u << 1)

#define CALIB_RECORD_VERSION 1

typedef struct {
    uint32_t version;
    uint32_t timestamp;                  /* host epoch seconds at capture */
    float    emg_rest_rms[EMG_N_CHANNELS];
    float    emg_mvc[EMG_N_CHANNELS];
    float    mdf_baseline[EMG_N_CHANNELS];
    float    q_upper0[4];                /* neutral pose, upper arm */
    float    q_fore0[4];                 /* neutral pose, forearm   */
    float    flexion_axis[3];            /* principal axis from the ROM sweep */
    float    angle_min;                  /* this patient's real extension   */
    float    angle_max;                  /* this patient's real flexion     */
    uint8_t  flags;
} calib_record_t;

static inline float calib_rom(const calib_record_t *c)
{
    return c->angle_max - c->angle_min;
}

/* ── Events ──────────────────────────────────────────────────────────── */

typedef enum {
    EVT_REP_START = 0x01,
    EVT_REP_COMPLETE,
    EVT_REP_ABANDONED,
    EVT_HOLD_START,
    EVT_HOLD_COMPLETE,
    EVT_COMPENSATION_SHOULDER,
    EVT_COMPENSATION_TRUNK,
    EVT_COMPENSATION_SWING,
    EVT_START_POS_OK,
    EVT_START_POS_BAD,
    EVT_FATIGUE_WARN,
    EVT_SIGNAL_DEGRADED,
    EVT_CALIB_PHASE_DONE,
    EVT_SET_COMPLETE,
    EVT_FAULT,
    EVT_STATE_CHANGE,
} event_id_t;

typedef struct {
    uint64_t t_us;
    uint8_t  id;                   /* event_id_t */
    uint8_t  payload[16];
    uint8_t  payload_len;
} rehab_event_t;

#endif /* REHAB_TYPES_H */
