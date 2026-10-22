/*
 * rep_cycle.c — hold-gated repetition state machine
 *
 * Deliberately not a learned model. Band crossings held for a fixed duration
 * are a solved problem: deterministic, debuggable, and every miscount traces
 * back to a threshold you can print. There is also no training data yet —
 * these thresholds are what produce the labelled repetition boundaries any
 * future model would need.
 *
 * Bands are fractions of the patient's calibrated ROM, never absolute
 * anatomical angles. A stroke patient who cannot reach full extension still
 * gets a working detector scaled to what they can do.
 */

#include <string.h>
#include <math.h>
#include "esp_log.h"
#include "rep_cycle.h"
#include "grading.h"
#include "rehab_config.h"

static const char *TAG = "rep";

typedef struct {
    rep_state_t state;
    uint64_t    state_entered_us;
    uint64_t    hold_started_us;
    bool        hold_running;

    uint16_t    rep_count;
    uint16_t    comp_flags;

    /* Per-repetition accumulation. */
    uint64_t    rep_start_us;
    float       peak_angle;
    float       activation_sum;     /* agonist %MVC, concentric only */
    float       antagonist_sum;
    uint32_t    activation_samples;

    /* Smoothness: accumulated |jerk| of the angle trajectory, alongside the
     * accumulated speed it is normalised against. */
    float       prev_velocity;
    float       jerk_sum;
    float       speed_sum;
    uint32_t    jerk_samples;

    /* Hold steadiness: variance of angle during the two holds. */
    float       hold_sum;
    float       hold_sum_sq;
    uint32_t    hold_samples;

    /* Compensation confirmation timers. */
    uint32_t    shoulder_ticks;
    uint32_t    trunk_ticks;
    uint32_t    swing_ticks;

    /* Fatigue trend across the set. */
    float       mdf_at_rep[64];
    uint16_t    mdf_count;
    bool        fatigue_flagged;

    bool        in_set;
} rep_ctx_t;

static rep_ctx_t      s;
static calib_record_t s_calib;
static bool           s_have_calib;

/* Precomputed band edges, refreshed whenever calibration changes. */
static float s_extended_hi;   /* top of the extension band */
static float s_flexed_lo;     /* bottom of the flexion band */
static float s_hysteresis;

static void recompute_bands(void)
{
    if (!s_have_calib) {
        return;
    }
    const float rom = calib_rom(&s_calib);
    s_extended_hi = s_calib.angle_min + REP_EXTENDED_BAND_FRAC * rom;
    s_flexed_lo   = s_calib.angle_min + REP_FLEXED_BAND_FRAC   * rom;
    s_hysteresis  = 0.03f * rom;

    ESP_LOGI(TAG, "bands: extended <= %.1f, flexed >= %.1f (ROM %.1f deg)",
             s_extended_hi, s_flexed_lo, rom);
}

void rep_cycle_init(void)
{
    memset(&s, 0, sizeof(s));
    s.state = REP_WAIT_START;
    s_have_calib = false;
}

void rep_cycle_set_calibration(const calib_record_t *calib)
{
    if (!calib) {
        s_have_calib = false;
        return;
    }
    memcpy(&s_calib, calib, sizeof(s_calib));
    s_have_calib = true;
    recompute_bands();
}

void rep_cycle_begin_set(void)
{
    const bool had_calib = s_have_calib;
    memset(&s, 0, sizeof(s));
    s.state  = REP_WAIT_START;
    s.in_set = true;
    s_have_calib = had_calib;
    ESP_LOGI(TAG, "set started");
}

void rep_cycle_end_set(void)
{
    s.in_set = false;
    ESP_LOGI(TAG, "set ended: %u repetitions", s.rep_count);
}

bool rep_cycle_fatigue_flagged(void)
{
    return s.fatigue_flagged;
}

/* ────────────────────────────────────────────────────────────────────── */

static void enter(rep_state_t next, uint64_t t_us)
{
    s.state            = next;
    s.state_entered_us = t_us;
    s.hold_running     = false;
}

/* A hold means stationary, not merely inside the band. */
static bool settled(const fusion_out_t *m)
{
    return fabsf(m->elbow_velocity_dps) <= REP_HOLD_MAX_VEL_DPS;
}

static bool start_position_ok(const fusion_out_t *m)
{
    return (m->elbow_angle_deg <= s_extended_hi + s_hysteresis) &&
           (m->upper_arm_dev_deg <= START_POS_UPPER_ARM_TOL_DEG);
}

/* Compensation is evaluated only during the moving phases. Attitude
 * thresholds confirm in 30 ms; the arm-swing rate threshold needs longer
 * because a brief spike is not a swing. */
static void check_compensation(const fusion_out_t *m)
{
    const uint32_t confirm_attitude =
        (COMP_CONFIRM_MS * FEATURE_RATE_HZ) / 1000 + 1;
    const uint32_t confirm_swing =
        (COMP_ARM_SWING_SUSTAIN_MS * FEATURE_RATE_HZ) / 1000;

    if (m->upper_arm_dev_deg > COMP_SHOULDER_HIKE_DEG) {
        if (++s.shoulder_ticks >= confirm_attitude) {
            s.comp_flags |= COMP_FLAG_SHOULDER;
        }
    } else {
        s.shoulder_ticks = 0;
    }

    /* Trunk lean shows as a common-mode attitude shift. With only two IMUs on
     * the arm this is approximated by a moderate upper-arm deviation that is
     * NOT accompanied by elbow motion — the whole body tilted rather than the
     * shoulder hiking.
     *
     * TODO(hardware): a trunk IMU would make this a direct measurement rather
     * than an inference. Flagged in the design doc as a known limitation. */
    if (m->upper_arm_dev_deg > COMP_TRUNK_LEAN_DEG &&
        fabsf(m->elbow_velocity_dps) < 5.0f) {
        if (++s.trunk_ticks >= confirm_attitude) {
            s.comp_flags |= COMP_FLAG_TRUNK;
        }
    } else {
        s.trunk_ticks = 0;
    }

    if (m->upper_arm_rate_dps > COMP_ARM_SWING_DPS) {
        if (++s.swing_ticks >= confirm_swing) {
            s.comp_flags |= COMP_FLAG_SWING;
        }
    } else {
        s.swing_ticks = 0;
    }
}

static void accumulate_motion(const fusion_out_t *m, const emg_features_t *e)
{
    if (m->elbow_angle_deg > s.peak_angle) {
        s.peak_angle = m->elbow_angle_deg;
    }

    const float dv = m->elbow_velocity_dps - s.prev_velocity;
    s.jerk_sum  += fabsf(dv);
    s.speed_sum += fabsf(m->elbow_velocity_dps);
    s.jerk_samples++;
    s.prev_velocity = m->elbow_velocity_dps;

    s.activation_sum     += e->envelope[0];   /* agonist: biceps by default */
    s.antagonist_sum     += e->envelope[1];
    s.activation_samples++;
}

static void accumulate_hold(const fusion_out_t *m)
{
    s.hold_sum    += m->elbow_angle_deg;
    s.hold_sum_sq += m->elbow_angle_deg * m->elbow_angle_deg;
    s.hold_samples++;
}

/* ──────────────────────────────────────────────────────────────────────
 * Fatigue: median frequency regressed across the set.
 * ────────────────────────────────────────────────────────────────────── */
static void update_fatigue(const emg_features_t *e)
{
    if (e->mdf[0] <= 0.0f || s.mdf_count >= 64) {
        return;
    }
    s.mdf_at_rep[s.mdf_count++] = e->mdf[0];

    if (s.mdf_count < FATIGUE_CONSEC_REPS + 1 || s.fatigue_flagged) {
        return;
    }

    /* Least-squares slope over the whole set so far, in Hz per repetition. */
    const uint16_t n = s.mdf_count;
    float sx = 0, sy = 0, sxy = 0, sxx = 0;
    for (uint16_t i = 0; i < n; i++) {
        sx  += i;
        sy  += s.mdf_at_rep[i];
        sxy += i * s.mdf_at_rep[i];
        sxx += (float)i * i;
    }
    const float denom = n * sxx - sx * sx;
    if (fabsf(denom) < 1e-6f) {
        return;
    }
    const float slope = (n * sxy - sx * sy) / denom;

    /* Require the last few repetitions to each sit below the one before, so a
     * single noisy estimate cannot trigger a rest cue. */
    bool consistently_falling = true;
    for (uint16_t i = n - FATIGUE_CONSEC_REPS; i + 1 < n; i++) {
        if (s.mdf_at_rep[i + 1] >= s.mdf_at_rep[i]) {
            consistently_falling = false;
            break;
        }
    }

    if (slope < FATIGUE_MDF_SLOPE_THRESH && consistently_falling) {
        s.fatigue_flagged = true;
        ESP_LOGI(TAG, "fatigue flagged: MDF slope %.2f Hz/rep over %u reps",
                 slope, n);
    }
}

/* ────────────────────────────────────────────────────────────────────── */

void rep_cycle_tick(const fusion_out_t *motion,
                    const emg_features_t *emg,
                    uint64_t t_us,
                    rep_tick_t *out)
{
    memset(out, 0, sizeof(*out));
    out->state     = s.state;
    out->rep_count = s.rep_count;

    if (!s.in_set || !s_have_calib) {
        return;
    }

    const uint64_t hold_us    = (uint64_t)REP_HOLD_MS * 1000;
    const uint64_t timeout_us = (uint64_t)REP_PHASE_TIMEOUT_MS * 1000;

    switch (s.state) {

    case REP_WAIT_START:
        /* Counter frozen until posture is correct. Passing through the right
         * angle on the way elsewhere must not arm anything, which is what the
         * hold timer in EXTENDED_HOLD enforces. */
        if (start_position_ok(motion)) {
            out->event = REP_EVT_START_POS_OK;
            enter(REP_EXTENDED_HOLD, t_us);
        } else {
            out->event = REP_EVT_START_POS_BAD;
        }
        break;

    case REP_EXTENDED_HOLD:
        if (!start_position_ok(motion)) {
            s.hold_running = false;
            enter(REP_WAIT_START, t_us);
            out->event = REP_EVT_START_POS_BAD;
            break;
        }

        if (!settled(motion)) {
            /* In the band but still moving: the hold has not begun. */
            s.hold_running = false;
            break;
        }

        if (!s.hold_running) {
            s.hold_running    = true;
            s.hold_started_us = t_us;
            out->event        = REP_EVT_HOLD_START;
            s.hold_sum = s.hold_sum_sq = 0.0f;
            s.hold_samples = 0;
        }
        accumulate_hold(motion);

        if (t_us - s.hold_started_us >= hold_us) {
            /* Bottom hold satisfied — the repetition is now armed. */
            s.rep_start_us       = t_us;
            s.peak_angle         = motion->elbow_angle_deg;
            s.activation_sum     = 0.0f;
            s.antagonist_sum     = 0.0f;
            s.activation_samples = 0;
            s.jerk_sum           = 0.0f;
            s.speed_sum          = 0.0f;
            s.jerk_samples       = 0;
            s.prev_velocity      = 0.0f;
            s.comp_flags         = 0;
            s.shoulder_ticks = s.trunk_ticks = s.swing_ticks = 0;

            out->event = REP_EVT_REP_START;
            enter(REP_CONCENTRIC, t_us);
        }
        break;

    case REP_CONCENTRIC:
        accumulate_motion(motion, emg);
        check_compensation(motion);

        if (motion->elbow_angle_deg >= s_flexed_lo - s_hysteresis) {
            enter(REP_FLEXED_HOLD, t_us);
            s.hold_sum = s.hold_sum_sq = 0.0f;
            s.hold_samples = 0;
        } else if (t_us - s.state_entered_us > timeout_us) {
            out->event = REP_EVT_REP_ABANDONED;
            enter(REP_WAIT_START, t_us);
        }
        break;

    case REP_FLEXED_HOLD:
        if (motion->elbow_angle_deg < s_flexed_lo - s_hysteresis) {
            /* Dropped out of the band before the hold completed. Back to
             * climbing rather than counting a partial repetition. */
            s.hold_running = false;
            enter(REP_CONCENTRIC, t_us);
            break;
        }

        check_compensation(motion);

        if (motion->elbow_angle_deg > s.peak_angle) {
            s.peak_angle = motion->elbow_angle_deg;
        }

        if (!settled(motion)) {
            /* Still climbing inside the band. Waiting to settle is what keeps
             * the steadiness measure from charging a deeper curl for the
             * motion it took to get there. */
            s.hold_running = false;
            if (t_us - s.state_entered_us > timeout_us) {
                out->event = REP_EVT_REP_ABANDONED;
                enter(REP_WAIT_START, t_us);
            }
            break;
        }

        if (!s.hold_running) {
            s.hold_running    = true;
            s.hold_started_us = t_us;
            out->event        = REP_EVT_HOLD_START;
            s.hold_sum = s.hold_sum_sq = 0.0f;
            s.hold_samples = 0;
        }
        accumulate_hold(motion);

        if (t_us - s.hold_started_us >= hold_us) {
            /* Top hold satisfied: count it, grade it, fire the haptic. */
            s.rep_count++;

            grading_input_t gi = {
                .peak_angle      = s.peak_angle,
                .angle_min       = s_calib.angle_min,
                .angle_max       = s_calib.angle_max,
                .activation_sum  = s.activation_sum,
                .antagonist_sum  = s.antagonist_sum,
                .activation_n    = s.activation_samples,
                .jerk_sum        = s.jerk_sum,
                .speed_sum       = s.speed_sum,
                .jerk_n          = s.jerk_samples,
                .hold_sum        = s.hold_sum,
                .hold_sum_sq     = s.hold_sum_sq,
                .hold_n          = s.hold_samples,
                .comp_flags      = s.comp_flags,
            };
            grading_evaluate(&gi, &out->result);

            out->result.index      = s.rep_count;
            out->result.t_start_us = s.rep_start_us;
            out->result.t_end_us   = t_us;
            out->result.comp_flags = s.comp_flags;

            update_fatigue(emg);

            out->event      = REP_EVT_REP_COMPLETE;
            out->comp_flags = s.comp_flags;
            out->rep_count  = s.rep_count;

            ESP_LOGI(TAG, "rep %u: score %u, ROM %.0f%%, comp 0x%02X",
                     s.rep_count, out->result.score,
                     out->result.rom_fraction * 100.0f, s.comp_flags);

            enter(REP_ECCENTRIC, t_us);
        }
        break;

    case REP_ECCENTRIC:
        accumulate_motion(motion, emg);
        check_compensation(motion);

        if (motion->elbow_angle_deg <= s_extended_hi + s_hysteresis) {
            enter(REP_EXTENDED_HOLD, t_us);
        } else if (t_us - s.state_entered_us > timeout_us) {
            out->event = REP_EVT_REP_ABANDONED;
            enter(REP_WAIT_START, t_us);
        }
        break;
    }

    out->state      = s.state;
    out->rep_count  = s.rep_count;
    if (out->event != REP_EVT_REP_COMPLETE) {
        out->comp_flags = s.comp_flags;
    }
}
