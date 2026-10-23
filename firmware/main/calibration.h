/*
 * calibration.h — the six-step protocol and its persistence [PRD §5.3]
 *
 *   0. Setup / contact check  —        saturation, mains pickup, both IMUs
 *   1. Rest                   5 s      EMG mean AND sigma, gyroscope bias
 *   2. Straight arm           2 s      0 deg reference pose, both quaternions
 *   3. Biceps maximum         3 s      agonist 100 % reference
 *   4. Triceps maximum        3 s      antagonist 100 % reference
 *   5. Range sweep            ~6 s     flexion axis, angle_min/max, MDF base
 *
 * Capture totals about nineteen seconds, roughly thirty including prompts,
 * against a Must of "under 30 s" in PRD §3.2.
 *
 * Deterministic statistics over a fixed protocol, not a learned model. The
 * output is a set of numbers each of which is a noise floor, a maximum, a
 * reference orientation or a range.
 *
 * STEPS ARE INDIVIDUALLY COMMANDED. A failed step is repeated on its own
 * rather than restarting the protocol, which matters because the step most
 * likely to fail — a maximum contraction on a paretic limb — is also the one
 * a patient least wants to repeat four others to get back to.
 */

#ifndef CALIBRATION_H
#define CALIBRATION_H

#include "esp_err.h"
#include "rehab_types.h"
#include "emg_dsp.h"
#include "fusion.h"

/* Wire values: CMD_START_CALIBRATION carries one of these as its uint8
 * argument. Keep in step with host/rehab_protocol.py. */
typedef enum {
    CALIB_IDLE          = 0,
    CALIB_STEP_CONTACT  = 1,   /* step 0 — donning and contact check */
    CALIB_STEP_REST     = 2,
    CALIB_STEP_STRAIGHT = 3,
    CALIB_STEP_BICEPS   = 4,
    CALIB_STEP_TRICEPS  = 5,
    CALIB_STEP_SWEEP    = 6,
    CALIB_STEP_ALL      = 7,   /* run 1..5 back to back */
    CALIB_DONE          = 8,
    CALIB_FAILED        = 9,
} calib_phase_t;

/* Why a step was rejected, so the app can say something specific rather than
 * "calibration failed" [PRD §5.3]. */
typedef enum {
    CALIB_REJECT_NONE = 0,
    CALIB_REJECT_MOVED,         /* stillness gate: steps 1 and 2 */
    CALIB_REJECT_TOO_WEAK,      /* MVC did not clear the noise floor */
    CALIB_REJECT_NO_RANGE,      /* sweep did not cover enough motion */
    CALIB_REJECT_SATURATED,     /* a channel is clipping */
    CALIB_REJECT_MAINS,         /* 60 Hz pickup above the limit */
} calib_reject_t;

typedef struct {
    calib_phase_t  phase;
    uint8_t        attempt;        /* within a maximum-contraction step */
    uint8_t        percent;        /* progress through the current step */
    bool           phase_changed;
    bool           step_complete;  /* this step finished successfully */
    calib_reject_t reject;
    const char    *message;        /* what to tell the patient to do */
} calib_progress_t;

void calibration_init(void);

/* Run one step. The protocol is a sequence of these; the host drives it, and
 * may repeat any step on its own. */
void calibration_begin_step(calib_phase_t step);

/* Run steps 1..5 back to back — the first-time path. */
void calibration_begin_all(void);

/* Session re-zero: steps 1, 2 and 5, which reset gyroscope bias and IMU drift
 * and absorb day-to-day variation in how the sleeve was put on. Steps 3 and 4
 * are reused from the stored profile [PRD §5.3]. */
void calibration_begin_session_rezero(void);

void calibration_abort(void);

/* Drive at FEATURE_RATE_HZ while in FW_STATE_CALIBRATION. */
void calibration_tick(const emg_features_t *emg, const fusion_out_t *motion,
                      uint64_t t_us, calib_progress_t *progress);

/* True once every step the profile needs has been captured. */
bool calibration_complete(void);
const calib_record_t *calibration_record(void);

/* Install a record from the host — this is how a clinician-supplied
 * normalisation value supersedes a measured one [PRD §5.3]. Sets
 * CALIB_FLAG_CLINICIAN_OVERRIDE so the device can report that it is not
 * scoring against its own measurement. */
void calibration_set_record(const calib_record_t *rec, bool clinician_override);

/* ── Persistence ─────────────────────────────────────────────────────── */

esp_err_t calibration_load_nvs(calib_record_t *out);
esp_err_t calibration_save_nvs(const calib_record_t *rec);
bool      calibration_is_stale(const calib_record_t *rec, uint32_t now_epoch_s);

/* ── Donning check ───────────────────────────────────────────────────── */

typedef enum {
    DON_PASS = 0,
    DON_IMU_DEAD,
    DON_EMG_DEAD,
    DON_CHANNELS_SWAPPED,   /* sleeve on backwards, or leads crossed */
    DON_SATURATED,          /* a channel is clipping */
    DON_MAINS,              /* 60 Hz pickup above the limit */
    DON_PENDING,
} donning_result_t;

void             donning_check_begin(void);
donning_result_t donning_check_tick(const emg_features_t *emg,
                                    const fusion_out_t *motion,
                                    uint64_t t_us,
                                    const char **message);

#endif /* CALIBRATION_H */
