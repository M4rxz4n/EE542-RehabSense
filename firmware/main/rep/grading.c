/*
 * grading.c — repetition quality score, 0..100
 *
 * score = 100 * (w_range*range + w_act*activation + w_smooth*smoothness
 *                + w_hold*steadiness)  -  penalties
 *
 * Hold steadiness replaces the tempo term the first draft carried: the
 * hold-based protocol fixes tempo by construction, and steadiness under an
 * isometric hold is a direct motor-control measure, which is worth more
 * clinically than tempo was.
 */

#include <string.h>
#include <math.h>
#include "grading.h"
#include "rehab_config.h"

static grading_weights_t s_w = {
    .w_range                 = GRADE_W_RANGE,
    .w_activation            = GRADE_W_ACTIVATION,
    .w_smoothness            = GRADE_W_SMOOTHNESS,
    .w_hold_steady           = GRADE_W_HOLD_STEADY,
    .p_shoulder              = PENALTY_SHOULDER_HIKE,
    .p_trunk                 = PENALTY_TRUNK_LEAN,
    .p_swing                 = PENALTY_ARM_SWING,
    .p_cocontraction         = PENALTY_COCONTRACTION,
    .cocontraction_threshold = COCONTRACTION_THRESHOLD,
};

void grading_set_weights(const grading_weights_t *w)
{
    if (w) {
        s_w = *w;
    } else {
        grading_weights_t d = {
            .w_range = GRADE_W_RANGE, .w_activation = GRADE_W_ACTIVATION,
            .w_smoothness = GRADE_W_SMOOTHNESS, .w_hold_steady = GRADE_W_HOLD_STEADY,
            .p_shoulder = PENALTY_SHOULDER_HIKE, .p_trunk = PENALTY_TRUNK_LEAN,
            .p_swing = PENALTY_ARM_SWING, .p_cocontraction = PENALTY_COCONTRACTION,
            .cocontraction_threshold = COCONTRACTION_THRESHOLD,
        };
        s_w = d;
    }
}

static float clamp01(float v)
{
    if (v < 0.0f) return 0.0f;
    if (v > 1.0f) return 1.0f;
    return v;
}

void grading_evaluate(const grading_input_t *in, rep_result_t *out)
{
    memset(out, 0, sizeof(*out));

    const float rom = in->angle_max - in->angle_min;

    /* ── Range achieved, as a fraction of this patient's calibrated ROM ── */
    float range = 0.0f;
    if (rom > 1.0f) {
        range = clamp01((in->peak_angle - in->angle_min) / rom);
    }
    out->peak_angle_deg = in->peak_angle;
    out->rom_fraction   = range;

    /* ── Target-muscle activation ──────────────────────────────────────
     * Mean agonist %MVC over the repetition. A full-range curl driven by
     * momentum rather than muscle scores badly here even though its range
     * looks perfect — which is the whole point of fusing EMG with motion. */
    float activation = 0.0f;
    if (in->activation_n > 0) {
        activation = in->activation_sum / (float)in->activation_n;
    }
    out->activation = activation;

    /* Saturate at 60 %MVC: a home rehab repetition is not meant to be a
     * maximal effort, and scaling to 100 % would make every honest
     * repetition look weak. */
    const float activation_score = clamp01(activation / 0.60f);

    /* ── Co-contraction ────────────────────────────────────────────────
     * Antagonist fighting the movement. Some is normal for joint
     * stabilisation; a lot means the patient is braking themselves. */
    float cocon = 0.0f;
    if (in->activation_sum > 1e-6f) {
        cocon = in->antagonist_sum / in->activation_sum;
    }
    out->cocontraction = cocon;

    /* ── Smoothness ────────────────────────────────────────────────────
     * Dimensionless jerk: how much the velocity changes from sample to sample
     * relative to the movement's own mean speed.
     *
     * Normalising by speed is the point. Raw mean |d(velocity)| scales with
     * how fast the limb is moving, so an unnormalised metric hands a better
     * score to anyone who simply moves slower — which would reward exactly
     * the guarding behaviour this device exists to discourage.
     *
     * The 0.5 reference means "velocity changing by half the mean speed every
     * sample scores zero". Tune against volunteer data in week 1. */
    float smoothness = 0.0f;
    if (in->jerk_n > 0) {
        const float mean_jerk  = in->jerk_sum  / (float)in->jerk_n;
        const float mean_speed = in->speed_sum / (float)in->jerk_n;

        if (mean_speed > 1.0f) {
            smoothness = clamp01(1.0f - (mean_jerk / mean_speed) / 0.5f);
        }
        /* Below 1 deg/s the limb barely moved and smoothness is not
         * meaningful; leaving it at zero is honest rather than flattering. */
    }
    out->smoothness = smoothness;

    /* ── Hold steadiness ───────────────────────────────────────────────
     * Inverse standard deviation of the angle during the holds. 5 degrees of
     * wobble over a 1-second hold scores zero. */
    float steadiness = 0.0f;
    if (in->hold_n > 1) {
        const float mean = in->hold_sum / (float)in->hold_n;
        float var = in->hold_sum_sq / (float)in->hold_n - mean * mean;
        if (var < 0.0f) var = 0.0f;
        const float sd = sqrtf(var);
        steadiness = clamp01(1.0f - (sd / 5.0f));
    }
    out->hold_steadiness = steadiness;

    /* ── Weighted base ─────────────────────────────────────────────────── */
    float score = 100.0f * (s_w.w_range       * range +
                            s_w.w_activation  * activation_score +
                            s_w.w_smoothness  * smoothness +
                            s_w.w_hold_steady * steadiness);

    /* ── Penalties ─────────────────────────────────────────────────────── */
    if (in->comp_flags & COMP_FLAG_SHOULDER) score -= s_w.p_shoulder;
    if (in->comp_flags & COMP_FLAG_TRUNK)    score -= s_w.p_trunk;
    if (in->comp_flags & COMP_FLAG_SWING)    score -= s_w.p_swing;

    if (cocon > s_w.cocontraction_threshold) {
        /* Scaled: twice the threshold costs the full penalty. */
        const float over = (cocon - s_w.cocontraction_threshold)
                         / s_w.cocontraction_threshold;
        score -= s_w.p_cocontraction * clamp01(over);
    }

    if (score < 0.0f)   score = 0.0f;
    if (score > 100.0f) score = 100.0f;
    out->score = (uint8_t)(score + 0.5f);
}
