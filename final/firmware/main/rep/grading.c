/*
 * grading.c — repetition quality score, 0..100 [PRD §5.5]
 *
 * score = 100 * (w_range*range + w_tempo*tempo + w_smooth*smoothness
 *                + w_cocon*cocontraction + w_hold*steadiness)  -  penalties
 *
 * The four default components carry equal weight. Steadiness is computed and
 * reported but weighted zero by default.
 */

#include <string.h>
#include <math.h>
#include "grading.h"
#include "rehab_config.h"

static rehab_runtime_cfg_t s_cfg;
static bool                s_cfg_init;

static void ensure_cfg(void)
{
    if (!s_cfg_init) {
        rehab_cfg_defaults(&s_cfg);
        s_cfg_init = true;
    }
}

void grading_set_config(const rehab_runtime_cfg_t *cfg)
{
    if (cfg) {
        s_cfg = *cfg;
    } else {
        rehab_cfg_defaults(&s_cfg);
    }
    s_cfg_init = true;
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
    ensure_cfg();

    /* ── Range of motion ───────────────────────────────────────────────
     * Peak angle divided by the therapist's TARGET angle, not by the
     * patient's measured ROM. The therapist prescribes what the patient
     * should reach; measured ROM is what they currently can. Scoring against
     * the latter would hand full marks to a shrinking range. */
    float range = 0.0f;
    const float excursion = in->peak_angle - in->angle_min;
    if (in->target_angle > 1.0f) {
        range = clamp01(excursion / in->target_angle);
    }
    out->peak_angle_deg = in->peak_angle;
    out->rom_fraction   = range;

    /* ── Tempo ─────────────────────────────────────────────────────────
     * Full credit inside the prescribed window, falling off outside it. Both
     * directions matter: too fast is momentum, too slow is usually guarding
     * or a stall mid-range. */
    float tempo = 0.0f;
    const float lo = s_cfg.tempo_min_s;
    const float hi = s_cfg.tempo_max_s;
    if (in->tempo_s > 0.0f && hi > lo) {
        if (in->tempo_s >= lo && in->tempo_s <= hi) {
            tempo = 1.0f;
        } else {
            /* Linear fall-off over one window-width either side, so a
             * repetition just outside the window is marked down rather than
             * zeroed. */
            const float width = hi - lo;
            const float dist  = (in->tempo_s < lo) ? (lo - in->tempo_s)
                                                   : (in->tempo_s - hi);
            tempo = clamp01(1.0f - dist / width);
        }
    }
    out->tempo_s = in->tempo_s;

    /* ── Smoothness ────────────────────────────────────────────────────
     * Count of velocity peaks exceeding 10 % of the repetition's own peak
     * velocity; a single peak scores 100 [PRD §5.5].
     *
     * This is directly interpretable: "this movement had four separate
     * pushes" means something to a therapist in a way that a normalised jerk
     * figure does not. Counting peaks is also naturally scale-free, which is
     * what keeps it from rewarding slow movement — the failure mode that an
     * unnormalised jerk metric has and that would reward exactly the guarding
     * behaviour this device exists to discourage. */
    float smoothness = 0.0f;
    if (in->velocity_peaks > 0) {
        const float extra = (float)(in->velocity_peaks - 1);
        smoothness = clamp01(1.0f - extra * SMOOTH_PEAK_COST);
    }
    out->smoothness     = smoothness;
    out->velocity_peaks = in->velocity_peaks;

    /* ── Co-contraction ────────────────────────────────────────────────
     * Antagonist activation as a fraction of agonist, evaluated only while
     * the agonist is active. Each channel is already normalised against its
     * OWN calibrated maximum, which is why calibration captures a separate
     * triceps maximum: scaling the triceps against whatever it happened to
     * produce during a biceps curl would make this number meaningless.
     *
     * Some co-contraction is normal joint stabilisation; a lot means the
     * patient is braking themselves. Zero overlap scores 100, and the score
     * reaches zero at COCON_ZERO_SCORE_RATIO. */
    float cocon_ratio = 0.0f;
    float cocon_score = 1.0f;

#if EMG_N_CHANNELS > 1
    if (in->overlap_n > 0 && in->activation_n > 0 && in->activation_sum > 1e-6f) {
        const float mean_antag = in->overlap_sum / (float)in->overlap_n;
        const float mean_agon  = in->activation_sum / (float)in->activation_n;
        if (mean_agon > 1e-6f) {
            cocon_ratio = mean_antag / mean_agon;
        }
    }
    if (COCON_ZERO_SCORE_RATIO > 1e-6f) {
        cocon_score = clamp01(1.0f - cocon_ratio / COCON_ZERO_SCORE_RATIO);
    }
#else
    /* Single-channel prototype: no antagonist envelope exists, so this is not
     * measured. The weight is zero, so the value never reaches the score —
     * reporting 0 rather than a fabricated ratio keeps the host from plotting
     * a number that means nothing. */
    (void)cocon_score;
#endif

    out->cocontraction = cocon_ratio;

    /* ── Mean agonist activation ───────────────────────────────────────
     * Reported for the host plot and for offline tuning. Not a scored
     * component in the PRD's four; the activation GATE in rep_cycle is what
     * enforces that the muscle did the work. */
    if (in->activation_n > 0) {
        out->activation = in->activation_sum / (float)in->activation_n;
    }

    /* ── Hold steadiness ───────────────────────────────────────────────
     * Inverse standard deviation of the angle during the confirming hold.
     * Five degrees of wobble scores zero. Reported always, scored only if the
     * host has given it a weight. */
    float steadiness = 0.0f;
    if (in->hold_n > 1) {
        const float mean = in->hold_sum / (float)in->hold_n;
        float var = in->hold_sum_sq / (float)in->hold_n - mean * mean;
        if (var < 0.0f) var = 0.0f;
        steadiness = clamp01(1.0f - (sqrtf(var) / 5.0f));
    }
    out->hold_steadiness = steadiness;

    /* ── Weighted base ─────────────────────────────────────────────────
     * Normalise by the weights actually in force, so a host that zeroes a
     * component redistributes its share rather than capping the achievable
     * score below 100. */
    const float wsum = s_cfg.w_range + s_cfg.w_tempo + s_cfg.w_smoothness +
                       s_cfg.w_cocontraction + s_cfg.w_hold_steady;

    float score = 0.0f;
    if (wsum > 1e-6f) {
        score = 100.0f * (s_cfg.w_range         * range +
                          s_cfg.w_tempo         * tempo +
                          s_cfg.w_smoothness    * smoothness +
                          s_cfg.w_cocontraction * cocon_score +
                          s_cfg.w_hold_steady   * steadiness) / wsum;
    }

    /* ── Deductions ────────────────────────────────────────────────────── */
    if (in->comp_flags & COMP_FLAG_SHOULDER) score -= s_cfg.p_shoulder;
    if (in->comp_flags & COMP_FLAG_TRUNK)    score -= s_cfg.p_trunk;
    if (in->comp_flags & COMP_FLAG_SWING)    score -= s_cfg.p_swing;

    if (score < 0.0f)   score = 0.0f;
    if (score > 100.0f) score = 100.0f;
    out->score = (uint8_t)(score + 0.5f);
}
