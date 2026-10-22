/*
 * calibration.h — the four-phase protocol and its persistence
 *
 *   Rest baseline       10 s        noise floor per channel
 *   Maximum contraction 3 x 5 s     best of three, for %MVC scaling
 *   Neutral pose        5 s         q_upper0, q_fore0
 *   ROM sweep           2 slow reps flexion axis, angle_min, angle_max
 *
 * Deterministic statistics over a fixed protocol, not a learned model. The
 * output is eleven numbers, each of which is a noise floor, a maximum, a
 * reference orientation or a range.
 */

#ifndef CALIBRATION_H
#define CALIBRATION_H

#include "esp_err.h"
#include "rehab_types.h"
#include "emg_dsp.h"
#include "fusion.h"

typedef enum {
    CALIB_IDLE = 0,
    CALIB_REST,
    CALIB_MVC,
    CALIB_NEUTRAL,
    CALIB_ROM_SWEEP,
    CALIB_DONE,
    CALIB_FAILED,
} calib_phase_t;

typedef struct {
    calib_phase_t phase;
    uint8_t       attempt;        /* within the MVC phase */
    uint8_t       percent;        /* progress through the current phase */
    bool          phase_changed;
    const char   *message;        /* what to tell the patient to do */
} calib_progress_t;

void calibration_init(void);

/* Full protocol. */
void calibration_begin(void);

/* Session re-zero only: the 5 s neutral pose, which resets IMU drift and
 * absorbs day-to-day variation in how the sleeve was put on. A returning
 * patient with a stored profile takes this path instead of the full 90 s. */
void calibration_begin_neutral_only(void);

void calibration_abort(void);

/* Drive at FEATURE_RATE_HZ while in FW_STATE_CALIBRATION. */
void calibration_tick(const emg_features_t *emg, const fusion_out_t *motion,
                      uint64_t t_us, calib_progress_t *progress);

bool calibration_complete(void);
const calib_record_t *calibration_record(void);

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
    DON_PENDING,
} donning_result_t;

void             donning_check_begin(void);
donning_result_t donning_check_tick(const emg_features_t *emg,
                                    const fusion_out_t *motion,
                                    uint64_t t_us,
                                    const char **message);

#endif /* CALIBRATION_H */
