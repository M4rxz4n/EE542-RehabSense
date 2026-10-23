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
    FAULT_CONTACT_LOST,            /* electrode lifted mid-session */
    FAULT_BATTERY_LOW,
} fault_code_t;

/* Which faults the patient must be TOLD about by vibration before haptics are
 * cut [PRD §5.2].
 *
 * A runaway motor is muted first and asked questions later. A lifted electrode
 * is the opposite case: the cue IS the information, and muting first means the
 * fault state silences its own warning. The distinction is which fault code was
 * raised, so it lives here rather than in the state machine. */
static inline bool fault_warrants_cue(fault_code_t f)
{
    return f == FAULT_CONTACT_LOST      ||
           f == FAULT_BATTERY_LOW       ||
           f == FAULT_EMG_UNRESPONSIVE  ||
           f == FAULT_IMU_UNRESPONSIVE;
}

/* ── Repetition cycle [PRD §5.4] ─────────────────────────────────────── */

typedef enum {
    REP_READY = 0,        /* at rest, agonist quiet                       */
    REP_CONCENTRIC,       /* angle rising, agonist live                   */
    REP_PEAK,             /* at or past 80 % of the target angle          */
    REP_ECCENTRIC,        /* angle falling                                */
    REP_EXTENDED_HOLD,    /* still at extension; counts at hold_duration  */
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
    uint8_t  activation_on;             /* agonist above threshold */
} features_t;

/* ── Repetition result ───────────────────────────────────────────────── */

typedef struct {
    uint16_t index;                /* 1-based within the set */
    uint64_t t_start_us;
    uint64_t t_end_us;
    float    peak_angle_deg;
    float    rom_fraction;         /* peak / target angle [PRD §5.5] */
    float    tempo_s;              /* start threshold to finish threshold */
    float    activation;           /* mean agonist %MVC over the rep */
    float    cocontraction;        /* normalised antagonist/agonist overlap */
    float    smoothness;           /* 0..1, from the velocity-peak count */
    uint8_t  velocity_peaks;       /* raw count, reported for interpretation */
    float    hold_steadiness;      /* 0..1; reported, not scored by default */
    uint16_t comp_flags;
    uint8_t  score;                /* 0..100 */
} rep_result_t;

/* ── Calibration record, persisted to NVS ────────────────────────────── */

#define CALIB_FLAG_MVC_UNRELIABLE     (1u << 0)
#define CALIB_FLAG_CLINICIAN_OVERRIDE (1u << 1)

/* Version 2 adds emg_rest_sd[] and gyro_bias[], which the activation detector
 * and the joint angle respectively depend on. The load path checks the
 * version, so a stored v1 profile is rejected cleanly rather than being
 * reinterpreted field by field. */
#define CALIB_RECORD_VERSION 2

typedef struct {
    uint32_t version;
    uint32_t timestamp;                  /* host epoch seconds at capture */
    float    emg_rest_rms[EMG_N_CHANNELS];
    float    emg_rest_sd[EMG_N_CHANNELS];  /* σ, for the activation detector */
    float    emg_mvc[EMG_N_CHANNELS];      /* per channel, own maximum       */
    float    mdf_baseline[EMG_N_CHANNELS];
    float    gyro_bias[2][3];            /* upper, forearm — deg/s */
    float    q_upper0[4];                /* reference pose, upper arm */
    float    q_fore0[4];                 /* reference pose, forearm   */
    float    flexion_axis[3];            /* principal axis from the ROM sweep */
    float    angle_min;                  /* this patient's real extension   */
    float    angle_max;                  /* this patient's real flexion     */
    uint8_t  flags;
} calib_record_t;

/* The record crosses BLE whole on characteristic 0x0007, so the host's
 * struct.Struct layout in rehab_protocol.py must agree with this one. Pinning
 * the size here means a field added on one side and forgotten on the other
 * fails the build rather than silently misreading every value after it. */
_Static_assert(sizeof(calib_record_t) ==
                   8 + 4 * (4 * EMG_N_CHANNELS + 6 + 8 + 3 + 2) + 4,
               "calib_record_t layout changed — update CALIB in "
               "host/rehab_protocol.py to match");

static inline float calib_rom(const calib_record_t *c)
{
    return c->angle_max - c->angle_min;
}

/* ── Runtime configuration [PRD §5.9.1] ──────────────────────────────────
 *
 * Every field below is settable over BLE, may be changed during a session,
 * takes effect from the next repetition, and is stored in NVS and read back
 * for confirmation.
 *
 * This struct is internal, not a wire format. SET_CONFIG carries tagged
 * fields (config.h) so a newer host can talk to older firmware without the
 * two having to agree on a layout.
 * ──────────────────────────────────────────────────────────────────────── */

typedef struct {
    /* Repetition geometry and timing */
    float    target_angle_deg;
    float    start_angle_deg;
    float    finish_angle_deg;
    uint16_t hold_duration_ms;
    float    hold_velocity_thresh;
    float    tempo_min_s, tempo_max_s;

    /* Session structure */
    uint8_t  rep_target;
    uint8_t  set_count;
    uint16_t rest_seconds;

    /* Compensation sensitivity */
    float    comp_shoulder_deg;
    float    comp_trunk_deg;
    float    comp_swing_dps;

    /* Grading */
    float    w_range, w_tempo, w_smoothness, w_cocontraction, w_hold_steady;
    float    p_shoulder, p_trunk, p_swing;

    /* Streaming and channel roles */
    uint8_t  raw_stream_enable;
    uint8_t  agonist_channel;      /* 0 or 1; the other is the antagonist */
} rehab_runtime_cfg_t;

/* Inline so the host-side test build gets defaults without linking the
 * firmware's NVS layer. */
static inline void rehab_cfg_defaults(rehab_runtime_cfg_t *c)
{
    c->target_angle_deg     = REP_TARGET_ANGLE_DEG;
    c->start_angle_deg      = REP_START_ANGLE_DEG;
    c->finish_angle_deg     = REP_FINISH_ANGLE_DEG;
    c->hold_duration_ms     = REP_HOLD_MS;
    c->hold_velocity_thresh = REP_HOLD_MAX_VEL_DPS;
    c->tempo_min_s          = REP_TEMPO_MIN_S;
    c->tempo_max_s          = REP_TEMPO_MAX_S;

    c->rep_target           = REP_TARGET_DEFAULT;
    c->set_count            = SET_COUNT_DEFAULT;
    c->rest_seconds         = REST_SECONDS_DEFAULT;

    c->comp_shoulder_deg    = COMP_SHOULDER_HIKE_DEG;
    c->comp_trunk_deg       = COMP_TRUNK_LEAN_DEG;
    c->comp_swing_dps       = COMP_ARM_SWING_DPS;

    c->w_range              = GRADE_W_RANGE;
    c->w_tempo              = GRADE_W_TEMPO;
    c->w_smoothness         = GRADE_W_SMOOTHNESS;
    c->w_cocontraction      = GRADE_W_COCONTRACTION;
    c->w_hold_steady        = GRADE_W_HOLD_STEADY;

    c->p_shoulder           = PENALTY_SHOULDER_HIKE;
    c->p_trunk              = PENALTY_TRUNK_LEAN;
    c->p_swing              = PENALTY_ARM_SWING;

    c->raw_stream_enable    = 1;
    c->agonist_channel      = 0;
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
    EVT_PASSIVE_SWING,     /* angle rose with the agonist quiet; not counted */
} event_id_t;

typedef struct {
    uint64_t t_us;
    uint8_t  id;                   /* event_id_t */
    uint8_t  payload[16];
    uint8_t  payload_len;
} rehab_event_t;

#endif /* REHAB_TYPES_H */
