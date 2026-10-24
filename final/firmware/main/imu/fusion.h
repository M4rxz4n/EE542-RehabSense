/*
 * fusion.h — orientation fusion and elbow angle
 *
 * Elbow angle comes from the RELATIVE orientation of the two IMUs, never from
 * either one's absolute heading. With no magnetometer in the system absolute
 * yaw is unobservable and drifts without bound; the relative formulation plus
 * a per-session neutral pose sidesteps that entirely.
 */

#ifndef FUSION_H
#define FUSION_H

#include "esp_err.h"
#include "rehab_types.h"
#include "bmi270.h"

typedef struct {
    float elbow_angle_deg;      /* flexion about the calibrated axis */
    float upper_arm_dev_deg;    /* total rotation from calibrated neutral */
    float fore_arm_dev_deg;     /* same, forearm — needed for common mode */
    float common_mode_deg;      /* rotation BOTH sensors share [PRD §5.5] */
    float elbow_velocity_dps;   /* signed, for smoothness and swing checks */
    float upper_arm_rate_dps;   /* magnitude, for arm-swing detection */
    float max_accel_g;          /* larger of the two |accel|, for jolt detect */
    bool  anchored;             /* true just after a rest-phase re-anchor */
} fusion_out_t;

void fusion_init(void);

/* Feed one sample per IMU. Call at IMU_SAMPLE_RATE_HZ. */
void fusion_update(const imu_sample_t *upper, const imu_sample_t *fore);

/* Latest derived values. */
void fusion_get(fusion_out_t *out);

/* Raw current orientations — calibration stores these as the neutral pose. */
void fusion_get_quats(quat_t *upper, quat_t *fore);

/* Neutral pose, flexion axis and ROM come from here. Call after calibration
 * and after every session re-zero. */
void fusion_set_calibration(const calib_record_t *calib);

/* ── Gyroscope bias capture [PRD §5.3, step 1] ───────────────────────────
 *
 * The rest step establishes gyroscope bias as well as the EMG noise floor.
 * Bias is accumulated here rather than in calibration.c because fusion is
 * where the raw samples arrive; calibration only sees derived values.
 *
 * Movement during the capture corrupts the bias and therefore the joint angle
 * for the whole session, with no obvious symptom — which is why the step is
 * gated on stillness. */
void fusion_bias_capture_begin(void);

/* Writes [upper][xyz] and [fore][xyz] in deg/s. Returns ESP_FAIL if too few
 * samples were collected to form an average. */
esp_err_t fusion_bias_capture_end(float bias_out[2][3]);

/* Apply a stored bias. Called after calibration and on load from NVS. */
void fusion_set_gyro_bias(const float bias[2][3]);

/* ── ROM sweep support ───────────────────────────────────────────────── */

/* Begin accumulating relative rotations to find this patient's flexion axis. */
void fusion_rom_sweep_begin(void);

/* Finish the sweep. Writes the dominant rotation axis and the angular range
 * observed. Returns ESP_FAIL if the sweep did not cover enough motion to
 * identify an axis, which means the patient barely moved. */
esp_err_t fusion_rom_sweep_end(float axis_out[3],
                               float *angle_min_out, float *angle_max_out);

#endif /* FUSION_H */
