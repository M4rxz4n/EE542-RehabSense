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
    float elbow_velocity_dps;   /* signed, for smoothness and swing checks */
    float upper_arm_rate_dps;   /* magnitude, for arm-swing detection */
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

/* ── ROM sweep support ───────────────────────────────────────────────── */

/* Begin accumulating relative rotations to find this patient's flexion axis. */
void fusion_rom_sweep_begin(void);

/* Finish the sweep. Writes the dominant rotation axis and the angular range
 * observed. Returns ESP_FAIL if the sweep did not cover enough motion to
 * identify an axis, which means the patient barely moved. */
esp_err_t fusion_rom_sweep_end(float axis_out[3],
                               float *angle_min_out, float *angle_max_out);

#endif /* FUSION_H */
