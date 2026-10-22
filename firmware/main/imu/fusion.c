/*
 * fusion.c — Madgwick fusion and elbow angle
 *
 * Madgwick's IMU-only variant (gyroscope plus accelerometer, no magnetometer)
 * runs independently on each sensor. The joint angle is then the rotation
 * between the two, each measured relative to its own neutral-pose reference.
 *
 * That last part is what makes sensor mounting irrelevant: the IMUs sit
 * wherever the sleeve puts them, and the neutral pose cancels the unknown
 * sensor-to-segment alignment out of both sides.
 */

#include <string.h>
#include <math.h>
#include "esp_log.h"
#include "fusion.h"
#include "rehab_config.h"

static const char *TAG = "fusion";

#ifndef M_PI
#define M_PI 3.14159265358979323846f
#endif
#define RAD2DEG (180.0f / M_PI)
#define DEG2RAD (M_PI / 180.0f)

typedef struct {
    quat_t q;
    /* Rest detection for the gravity re-anchor. */
    uint32_t quiet_samples;
} sensor_state_t;

static sensor_state_t s_upper, s_fore;
static fusion_out_t   s_out;
static bool           s_have_calib;
static calib_record_t s_calib;
static float          s_prev_angle_deg;
static bool           s_prev_valid;

/* ROM sweep accumulation */
static bool   s_sweeping;
static float  s_sweep_axis_sum[3];
static float  s_sweep_angle_min;
static float  s_sweep_angle_max;
static uint32_t s_sweep_samples;

/* ── Quaternion helpers ──────────────────────────────────────────────── */

static quat_t q_mul(quat_t a, quat_t b)
{
    quat_t r;
    r.w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z;
    r.x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y;
    r.y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x;
    r.z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w;
    return r;
}

static quat_t q_conj(quat_t q)
{
    return (quat_t){ q.w, -q.x, -q.y, -q.z };
}

static void q_normalise(quat_t *q)
{
    const float n = sqrtf(q->w * q->w + q->x * q->x + q->y * q->y + q->z * q->z);
    if (n > 1e-9f) {
        const float inv = 1.0f / n;
        q->w *= inv; q->x *= inv; q->y *= inv; q->z *= inv;
    } else {
        *q = (quat_t){ 1.0f, 0.0f, 0.0f, 0.0f };
    }
}

/* ──────────────────────────────────────────────────────────────────────
 * Madgwick, IMU-only.
 *
 * Beta trades drift against responsiveness. Tune it on bench data against a
 * goniometer in week 1 — the acceptance target is 5-10 degrees.
 * ────────────────────────────────────────────────────────────────────── */
static void madgwick_update(quat_t *q, const float gyro_dps[3],
                            const float accel_g[3], float dt)
{
    const float gx = gyro_dps[0] * DEG2RAD;
    const float gy = gyro_dps[1] * DEG2RAD;
    const float gz = gyro_dps[2] * DEG2RAD;

    /* Rate of change from the gyroscope alone. */
    float qdot_w = 0.5f * (-q->x * gx - q->y * gy - q->z * gz);
    float qdot_x = 0.5f * ( q->w * gx + q->y * gz - q->z * gy);
    float qdot_y = 0.5f * ( q->w * gy - q->x * gz + q->z * gx);
    float qdot_z = 0.5f * ( q->w * gz + q->x * gy - q->y * gx);

    const float an = sqrtf(accel_g[0] * accel_g[0] +
                           accel_g[1] * accel_g[1] +
                           accel_g[2] * accel_g[2]);

    /* Skip the correction when the accelerometer is not measuring gravity:
     * during a fast movement it reads linear acceleration too, and trusting
     * it then actively pulls the estimate wrong. */
    if (an > 0.5f && fabsf(an - 1.0f) < 0.3f) {
        const float ax = accel_g[0] / an;
        const float ay = accel_g[1] / an;
        const float az = accel_g[2] / an;

        const float _2qw = 2.0f * q->w, _2qx = 2.0f * q->x;
        const float _2qy = 2.0f * q->y, _2qz = 2.0f * q->z;
        const float _4qw = 4.0f * q->w, _4qx = 4.0f * q->x, _4qy = 4.0f * q->y;
        const float _8qx = 8.0f * q->x, _8qy = 8.0f * q->y;
        const float qwqw = q->w * q->w, qxqx = q->x * q->x;
        const float qyqy = q->y * q->y, qzqz = q->z * q->z;

        float sw = _4qw * qyqy + _2qy * ax + _4qw * qxqx - _2qx * ay;
        float sx = _4qx * qzqz - _2qz * ax + 4.0f * qwqw * q->x - _2qw * ay
                 - _4qx + _8qx * qxqx + _8qx * qyqy + _4qx * az;
        float sy = 4.0f * qwqw * q->y + _2qw * ax + _4qy * qzqz - _2qz * ay
                 - _4qy + _8qy * qxqx + _8qy * qyqy + _4qy * az;
        float sz = 4.0f * qxqx * q->z - _2qx * ax + 4.0f * qyqy * q->z - _2qy * ay;

        const float sn = sqrtf(sw * sw + sx * sx + sy * sy + sz * sz);
        if (sn > 1e-9f) {
            const float inv = MADGWICK_BETA / sn;
            qdot_w -= sw * inv;
            qdot_x -= sx * inv;
            qdot_y -= sy * inv;
            qdot_z -= sz * inv;
        }
    }

    q->w += qdot_w * dt;
    q->x += qdot_x * dt;
    q->y += qdot_y * dt;
    q->z += qdot_z * dt;
    q_normalise(q);
}

/* ──────────────────────────────────────────────────────────────────────
 * Rest-phase re-anchor.
 *
 * Between repetitions the arm is briefly static. When both sensors are quiet
 * the filter re-levels to gravity, which keeps drift from accumulating over a
 * long session. With the hold-based repetition protocol this happens twice per
 * repetition by construction — the patient is standing still for a full second
 * at each end, which is an unusually good opportunity.
 * ────────────────────────────────────────────────────────────────────── */
static bool is_quiet(const imu_sample_t *s)
{
    const float gmag = fabsf(s->gyro[0]) + fabsf(s->gyro[1]) + fabsf(s->gyro[2]);
    const float amag = sqrtf(s->accel[0] * s->accel[0] +
                             s->accel[1] * s->accel[1] +
                             s->accel[2] * s->accel[2]);
    return (gmag < ZUPT_GYRO_DPS * 3.0f) &&
           (fabsf(amag - 1.0f) < ZUPT_ACCEL_TOL_G);
}

/* ────────────────────────────────────────────────────────────────────── */

void fusion_init(void)
{
    memset(&s_upper, 0, sizeof(s_upper));
    memset(&s_fore,  0, sizeof(s_fore));
    memset(&s_out,   0, sizeof(s_out));
    s_upper.q = (quat_t){ 1.0f, 0.0f, 0.0f, 0.0f };
    s_fore.q  = (quat_t){ 1.0f, 0.0f, 0.0f, 0.0f };
    s_have_calib = false;
    s_prev_valid = false;
    s_sweeping   = false;
}

void fusion_set_calibration(const calib_record_t *calib)
{
    if (!calib) {
        s_have_calib = false;
        return;
    }
    memcpy(&s_calib, calib, sizeof(s_calib));
    s_have_calib = true;
}

void fusion_get_quats(quat_t *upper, quat_t *fore)
{
    if (upper) *upper = s_upper.q;
    if (fore)  *fore  = s_fore.q;
}

/* Signed rotation about a given axis, extracted from a quaternion. */
static float angle_about_axis(quat_t q, const float axis[3])
{
    /* Project the vector part onto the axis, then recover the angle. The sign
     * follows the axis direction, which the ROM sweep fixed. */
    const float proj = q.x * axis[0] + q.y * axis[1] + q.z * axis[2];
    return 2.0f * atan2f(proj, q.w) * RAD2DEG;
}

void fusion_update(const imu_sample_t *upper, const imu_sample_t *fore)
{
    const float dt = 1.0f / (float)IMU_SAMPLE_RATE_HZ;

    madgwick_update(&s_upper.q, upper->gyro, upper->accel, dt);
    madgwick_update(&s_fore.q,  fore->gyro,  fore->accel,  dt);

    /* Rest detection on both sensors together. */
    if (is_quiet(upper) && is_quiet(fore)) {
        s_upper.quiet_samples++;
        s_fore.quiet_samples++;
    } else {
        s_upper.quiet_samples = 0;
        s_fore.quiet_samples  = 0;
    }

    const uint32_t quiet_needed = (ZUPT_HOLD_MS * IMU_SAMPLE_RATE_HZ) / 1000;
    s_out.anchored = (s_upper.quiet_samples >= quiet_needed);

    s_out.upper_arm_rate_dps = sqrtf(upper->gyro[0] * upper->gyro[0] +
                                     upper->gyro[1] * upper->gyro[1] +
                                     upper->gyro[2] * upper->gyro[2]);

    if (!s_have_calib) {
        /* Before calibration there is no neutral reference, so the absolute
         * angle is meaningless. Report zero rather than a plausible lie. */
        s_out.elbow_angle_deg   = 0.0f;
        s_out.upper_arm_dev_deg = 0.0f;
        return;
    }

    const quat_t q_u0 = { s_calib.q_upper0[0], s_calib.q_upper0[1],
                          s_calib.q_upper0[2], s_calib.q_upper0[3] };
    const quat_t q_f0 = { s_calib.q_fore0[0],  s_calib.q_fore0[1],
                          s_calib.q_fore0[2],  s_calib.q_fore0[3] };

    /* Each sensor's rotation since its own neutral pose. */
    const quat_t rel_u = q_mul(q_conj(q_u0), s_upper.q);
    const quat_t rel_f = q_mul(q_conj(q_f0), s_fore.q);

    /* The joint rotation: forearm relative to upper arm. */
    const quat_t q_joint = q_mul(q_conj(rel_u), rel_f);

    const float raw_angle = angle_about_axis(q_joint, s_calib.flexion_axis);

    /* Express as an absolute angle on the patient's own scale, so the bands in
     * rep_cycle can be fractions of their real ROM. */
    s_out.elbow_angle_deg = s_calib.angle_min + fabsf(raw_angle);

    /* How far the upper arm has moved from neutral — the shoulder-hike and
     * trunk-lean signal. */
    float w = fabsf(rel_u.w);
    if (w > 1.0f) w = 1.0f;
    s_out.upper_arm_dev_deg = 2.0f * acosf(w) * RAD2DEG;

    if (s_prev_valid) {
        s_out.elbow_velocity_dps =
            (s_out.elbow_angle_deg - s_prev_angle_deg) * (float)IMU_SAMPLE_RATE_HZ;
    }
    s_prev_angle_deg = s_out.elbow_angle_deg;
    s_prev_valid     = true;

    if (s_sweeping) {
        /* Accumulate the joint rotation axis, sign-aligned so opposing sweep
         * directions reinforce instead of cancelling. */
        const float vn = sqrtf(q_joint.x * q_joint.x +
                               q_joint.y * q_joint.y +
                               q_joint.z * q_joint.z);
        if (vn > 1e-4f) {
            const float sign = (q_joint.w >= 0.0f) ? 1.0f : -1.0f;
            s_sweep_axis_sum[0] += sign * q_joint.x / vn;
            s_sweep_axis_sum[1] += sign * q_joint.y / vn;
            s_sweep_axis_sum[2] += sign * q_joint.z / vn;
            s_sweep_samples++;
        }

        float wq = fabsf(q_joint.w);
        if (wq > 1.0f) wq = 1.0f;
        const float total = 2.0f * acosf(wq) * RAD2DEG;
        if (total < s_sweep_angle_min) s_sweep_angle_min = total;
        if (total > s_sweep_angle_max) s_sweep_angle_max = total;
    }
}

void fusion_get(fusion_out_t *out)
{
    *out = s_out;
}

/* ── ROM sweep ───────────────────────────────────────────────────────── */

void fusion_rom_sweep_begin(void)
{
    memset(s_sweep_axis_sum, 0, sizeof(s_sweep_axis_sum));
    s_sweep_angle_min = 1e9f;
    s_sweep_angle_max = -1e9f;
    s_sweep_samples   = 0;
    s_sweeping        = true;
    ESP_LOGI(TAG, "ROM sweep started");
}

esp_err_t fusion_rom_sweep_end(float axis_out[3],
                               float *angle_min_out, float *angle_max_out)
{
    s_sweeping = false;

    const float n = sqrtf(s_sweep_axis_sum[0] * s_sweep_axis_sum[0] +
                          s_sweep_axis_sum[1] * s_sweep_axis_sum[1] +
                          s_sweep_axis_sum[2] * s_sweep_axis_sum[2]);

    if (s_sweep_samples < (uint32_t)IMU_SAMPLE_RATE_HZ || n < 1e-3f) {
        ESP_LOGE(TAG, "ROM sweep saw too little motion to find a flexion axis");
        return ESP_FAIL;
    }

    axis_out[0] = s_sweep_axis_sum[0] / n;
    axis_out[1] = s_sweep_axis_sum[1] / n;
    axis_out[2] = s_sweep_axis_sum[2] / n;

    *angle_min_out = 0.0f;                 /* neutral pose is the origin */
    *angle_max_out = s_sweep_angle_max;

    if (s_sweep_angle_max < 20.0f) {
        ESP_LOGW(TAG, "ROM sweep spanned only %.1f degrees — the patient may "
                      "not have moved through their full range",
                 s_sweep_angle_max);
    }

    ESP_LOGI(TAG, "flexion axis [%.3f %.3f %.3f], range 0-%.1f deg",
             axis_out[0], axis_out[1], axis_out[2], s_sweep_angle_max);
    return ESP_OK;
}
