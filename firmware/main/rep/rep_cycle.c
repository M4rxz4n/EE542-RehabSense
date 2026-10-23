/*
 * rep_cycle.c — repetition detection [PRD §5.4]
 *
 * See rep_cycle.h for the cycle and the reasoning behind counting on the
 * return rather than at the top of the curl.
 */

#include <string.h>
#include <math.h>
#include "esp_log.h"
#include "rep_cycle.h"
#include "grading.h"
#include "activation.h"
#include "rehab_config.h"

static const char *TAG = "rep";

typedef struct {
    rep_state_t state;
    uint64_t    state_entered_us;
    uint64_t    hold_started_us;
    bool        hold_running;

    uint16_t    rep_count;
    uint16_t    comp_flags;
    bool        set_complete;

    /* Per-repetition accumulation. */
    uint64_t    rep_start_us;      /* crossing the start threshold */
    uint64_t    rep_finish_us;     /* crossing the finish threshold */
    float       peak_angle;
    float       activation_sum;    /* agonist %MVC */
    float       antagonist_sum;
    float       overlap_sum;       /* antagonist while the agonist is active */
    uint32_t    activation_samples;
    uint32_t    overlap_samples;

    /* Smoothness: velocity peaks over the movement [PRD §5.5]. */
    float       vel_lp;            /* low-passed velocity */
    float       prev_vel_lp;
    float       peak_speed;
    float       peak_mag[REP_MAX_VEL_PEAKS];
    uint8_t     peak_n;
    bool        rising;

    /* Hold steadiness: variance of the angle during the confirming hold. */
    float       hold_sum;
    float       hold_sum_sq;
    uint32_t    hold_samples;

    /* Compensation confirmation timers. */
    uint32_t    shoulder_ticks;
    uint32_t    trunk_ticks;
    uint32_t    swing_ticks;
    bool        jolt_excluded;     /* a spike voided part of this rep */

    /* Fatigue trend across the set. */
    float       mdf_at_rep[64];
    uint16_t    mdf_count;
    bool        fatigue_flagged;

    bool        in_set;
} rep_ctx_t;

static rep_ctx_t           s;
static calib_record_t      s_calib;
static bool                s_have_calib;
static rehab_runtime_cfg_t s_cfg;
static activation_det_t    s_act;

/* ────────────────────────────────────────────────────────────────────── */

void rep_cycle_init(void)
{
    memset(&s, 0, sizeof(s));
    s.state      = REP_READY;
    s_have_calib = false;
    rehab_cfg_defaults(&s_cfg);
    activation_init(&s_act, 0.0f, 0.0f, 0.0f, FEATURE_RATE_HZ);
}

void rep_cycle_set_config(const rehab_runtime_cfg_t *cfg)
{
    if (cfg) {
        s_cfg = *cfg;
    } else {
        rehab_cfg_defaults(&s_cfg);
    }
}

void rep_cycle_set_calibration(const calib_record_t *calib)
{
    if (!calib) {
        s_have_calib = false;
        return;
    }
    memcpy(&s_calib, calib, sizeof(s_calib));
    s_have_calib = true;

    const uint8_t ag = (s_cfg.agonist_channel < EMG_N_CHANNELS)
                           ? s_cfg.agonist_channel : 0;

    activation_init(&s_act,
                    s_calib.emg_rest_rms[ag],
                    s_calib.emg_rest_sd[ag],
                    s_calib.emg_mvc[ag],
                    FEATURE_RATE_HZ);

    ESP_LOGI(TAG, "activation: on>%.3f off<%.3f %%MVC%s",
             s_act.on_thresh, s_act.off_thresh,
             s_act.using_fallback ? " (FALLBACK — calibration gave no sigma)"
                                  : "");
    ESP_LOGI(TAG, "angles: start %.1f finish %.1f target %.1f (peak at %.1f)",
             s_cfg.start_angle_deg, s_cfg.finish_angle_deg,
             s_cfg.target_angle_deg,
             s_cfg.target_angle_deg * REP_PEAK_FRAC);
}

void rep_cycle_begin_set(void)
{
    const bool  had_calib = s_have_calib;
    const calib_record_t keep_calib = s_calib;
    const activation_det_t keep_act = s_act;

    memset(&s, 0, sizeof(s));
    s.state  = REP_READY;
    s.in_set = true;

    s_have_calib = had_calib;
    s_calib      = keep_calib;
    s_act        = keep_act;

    /* A contraction still running from the previous set must not arm the
     * first repetition of this one. */
    activation_reset(&s_act);

    ESP_LOGI(TAG, "set started, target %u reps", s_cfg.rep_target);
}

void rep_cycle_end_set(void)
{
    s.in_set = false;
    ESP_LOGI(TAG, "set ended: %u repetitions", s.rep_count);
}

bool rep_cycle_fatigue_flagged(void) { return s.fatigue_flagged; }
bool rep_cycle_activation_on(void)   { return s_act.on; }
bool rep_cycle_set_complete(void)    { return s.set_complete; }

/* ────────────────────────────────────────────────────────────────────── */

static void enter(rep_state_t next, uint64_t t_us)
{
    s.state            = next;
    s.state_entered_us = t_us;
    s.hold_running     = false;
}

/* A hold means stationary, not merely below the finish threshold. */
static bool settled(const fusion_out_t *m)
{
    return fabsf(m->elbow_velocity_dps) <= s_cfg.hold_velocity_thresh;
}

static bool posture_ok(const fusion_out_t *m)
{
    return m->upper_arm_dev_deg <= START_POS_UPPER_ARM_TOL_DEG;
}

/* ──────────────────────────────────────────────────────────────────────
 * Compensation [PRD §5.5]. Evaluated only during the moving phases, latched
 * for the repetition, and reported at the confirming hold so feedback lands
 * at one predictable moment rather than interrupting the movement.
 * ────────────────────────────────────────────────────────────────────── */
static void check_compensation(const fusion_out_t *m)
{
    const uint32_t confirm_attitude =
        (COMP_CONFIRM_MS * FEATURE_RATE_HZ) / 1000 + 1;
    const uint32_t confirm_swing =
        (COMP_ARM_SWING_SUSTAIN_MS * FEATURE_RATE_HZ) / 1000;

    if (m->upper_arm_dev_deg > s_cfg.comp_shoulder_deg) {
        if (++s.shoulder_ticks >= confirm_attitude) {
            s.comp_flags |= COMP_FLAG_SHOULDER;
        }
    } else {
        s.shoulder_ticks = 0;
    }

    /* Common-mode rotation of BOTH IMUs — the whole arm carried by the torso.
     * fusion.c computes this with an axis-alignment gate, so a shoulder hike
     * cannot also register here. */
    if (m->common_mode_deg > s_cfg.comp_trunk_deg) {
        if (++s.trunk_ticks >= confirm_attitude) {
            s.comp_flags |= COMP_FLAG_TRUNK;
        }
    } else {
        s.trunk_ticks = 0;
    }

    if (m->upper_arm_rate_dps > s_cfg.comp_swing_dps) {
        if (++s.swing_ticks >= confirm_swing) {
            s.comp_flags |= COMP_FLAG_SWING;
        }
    } else {
        s.swing_ticks = 0;
    }

    /* A sudden jolt excludes that segment from scoring rather than being read
     * as a movement fault the patient caused [PRD §5.5]. */
    if (m->max_accel_g > COMP_JOLT_G) {
        s.jolt_excluded = true;
    }
}

/* ──────────────────────────────────────────────────────────────────────
 * Smoothness, per PRD §5.5: count velocity peaks exceeding 10 % of the
 * repetition's own peak velocity. One peak is one smooth push and scores 100;
 * each extra peak is a separate correction the patient had to make.
 *
 * Peaks are detected on a low-passed velocity so that sensor noise does not
 * read as a correction, and magnitudes are stored so the 10 % threshold can be
 * applied at the end, once the repetition's peak is actually known.
 * ────────────────────────────────────────────────────────────────────── */
static void accumulate_motion(const fusion_out_t *m, const emg_features_t *e)
{
    if (m->elbow_angle_deg > s.peak_angle) {
        s.peak_angle = m->elbow_angle_deg;
    }

    /* One-pole low pass at REP_VEL_LPF_HZ. */
    const float dt    = 1.0f / (float)FEATURE_RATE_HZ;
    const float rc    = 1.0f / (2.0f * 3.14159265f * REP_VEL_LPF_HZ);
    const float alpha = dt / (rc + dt);
    s.vel_lp += alpha * (m->elbow_velocity_dps - s.vel_lp);

    const float speed = fabsf(s.vel_lp);
    if (speed > s.peak_speed) {
        s.peak_speed = speed;
    }

    /* A local maximum in speed is a push. */
    const float prev = fabsf(s.prev_vel_lp);
    if (speed > prev) {
        s.rising = true;
    } else if (s.rising && speed < prev) {
        if (s.peak_n < REP_MAX_VEL_PEAKS) {
            s.peak_mag[s.peak_n++] = prev;
        }
        s.rising = false;
    }
    s.prev_vel_lp = s.vel_lp;

    const uint8_t ag = (s_cfg.agonist_channel < EMG_N_CHANNELS)
                           ? s_cfg.agonist_channel : 0;

    s.activation_sum += e->envelope[ag];
    s.activation_samples++;

#if EMG_N_CHANNELS > 1
    const uint8_t an = ag ? 0 : 1;
    s.antagonist_sum += e->envelope[an];

    /* Co-contraction is evaluated only while the agonist is active
     * [PRD §5.5]: antagonist activity during a rest phase is not the patient
     * braking themselves, it is just a quiet muscle. */
    if (s_act.on) {
        s.overlap_sum += e->envelope[an];
        s.overlap_samples++;
    }
#endif
}

static void accumulate_hold(const fusion_out_t *m)
{
    s.hold_sum    += m->elbow_angle_deg;
    s.hold_sum_sq += m->elbow_angle_deg * m->elbow_angle_deg;
    s.hold_samples++;
}

static void begin_repetition(const fusion_out_t *m, uint64_t t_us)
{
    s.rep_start_us       = t_us;
    s.rep_finish_us      = 0;
    s.peak_angle         = m->elbow_angle_deg;
    s.activation_sum     = 0.0f;
    s.antagonist_sum     = 0.0f;
    s.overlap_sum        = 0.0f;
    s.activation_samples = 0;
    s.overlap_samples    = 0;
    s.vel_lp             = 0.0f;
    s.prev_vel_lp        = 0.0f;
    s.peak_speed         = 0.0f;
    s.peak_n             = 0;
    s.rising             = false;
    s.hold_sum           = 0.0f;
    s.hold_sum_sq        = 0.0f;
    s.hold_samples       = 0;
    s.comp_flags         = 0;
    s.jolt_excluded      = false;
    s.shoulder_ticks = s.trunk_ticks = s.swing_ticks = 0;
}

/* ──────────────────────────────────────────────────────────────────────
 * Fatigue: median frequency regressed across the set [PRD §5.8].
 * ────────────────────────────────────────────────────────────────────── */
static void update_fatigue(const emg_features_t *e)
{
    const uint8_t ag = (s_cfg.agonist_channel < EMG_N_CHANNELS)
                           ? s_cfg.agonist_channel : 0;

    if (e->mdf[ag] <= 0.0f || s.mdf_count >= 64) {
        return;
    }
    s.mdf_at_rep[s.mdf_count++] = e->mdf[ag];

    if (s.mdf_count < FATIGUE_CONSEC_REPS + 1 || s.fatigue_flagged) {
        return;
    }

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
     * single noisy estimate cannot fire a rest cue at a patient. */
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

/* Count the stored velocity peaks that clear 10 % of the repetition's own
 * peak speed. Done at the end because the reference is not known until then. */
static uint8_t significant_peaks(void)
{
    if (s.peak_speed <= 0.0f) {
        return 0;
    }
    const float floor_v = s.peak_speed * SMOOTH_PEAK_FRAC;
    uint8_t n = 0;
    for (uint8_t i = 0; i < s.peak_n; i++) {
        if (s.peak_mag[i] >= floor_v) {
            n++;
        }
    }
    return n;
}

static void complete_repetition(const fusion_out_t *m, const emg_features_t *e,
                                uint64_t t_us, rep_tick_t *out)
{
    s.rep_count++;

    const float tempo_s = (s.rep_finish_us > s.rep_start_us)
        ? (float)(s.rep_finish_us - s.rep_start_us) / 1e6f
        : 0.0f;

    grading_input_t gi = {
        .peak_angle        = s.peak_angle,
        .angle_min         = s_calib.angle_min,
        .target_angle      = s_cfg.target_angle_deg,
        .tempo_s           = tempo_s,
        .activation_sum    = s.activation_sum,
        .antagonist_sum    = s.antagonist_sum,
        .overlap_sum       = s.overlap_sum,
        .activation_n      = s.activation_samples,
        .overlap_n         = s.overlap_samples,
        .velocity_peaks    = significant_peaks(),
        .hold_sum          = s.hold_sum,
        .hold_sum_sq       = s.hold_sum_sq,
        .hold_n            = s.hold_samples,
        .comp_flags        = s.comp_flags,
        .jolt_excluded     = s.jolt_excluded,
    };
    grading_evaluate(&gi, &out->result);

    out->result.index      = s.rep_count;
    out->result.t_start_us = s.rep_start_us;
    out->result.t_end_us   = t_us;
    out->result.tempo_s    = tempo_s;
    out->result.comp_flags = s.comp_flags;

    update_fatigue(e);

    /* Reaching the target ends the set [PRD §5.6]: the set-complete pattern
     * follows the per-repetition cue after a gap, so the patient gets both the
     * quality result and confirmation that the set is finished. A flagged
     * repetition still counts toward the target — quality lives in the score,
     * not in the counter [PRD §5.5]. */
    bool reached_now = false;
    if (s_cfg.rep_target > 0 && s.rep_count >= s_cfg.rep_target &&
        !s.set_complete) {
        s.set_complete = true;
        reached_now    = true;
    }

    out->event      = REP_EVT_REP_COMPLETE;
    out->comp_flags = s.comp_flags;
    out->rep_count  = s.rep_count;

    /* An EDGE, not the latched state: the set-complete cue must fire on the
     * repetition that reaches the target and not on every one after it. The
     * latched value is available through rep_cycle_set_complete() for anyone
     * who needs to ask. */
    out->set_complete = reached_now;

    ESP_LOGI(TAG, "rep %u: score %u, range %.0f%%, tempo %.1fs, peaks %u, "
                  "comp 0x%02X%s",
             s.rep_count, out->result.score,
             out->result.rom_fraction * 100.0f, tempo_s,
             out->result.velocity_peaks, s.comp_flags,
             s.set_complete ? " [SET COMPLETE]" : "");
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

    const uint8_t ag = (s_cfg.agonist_channel < EMG_N_CHANNELS)
                           ? s_cfg.agonist_channel : 0;

    const bool act = activation_update(&s_act, emg->envelope[ag]);
    out->activation_on = act;

    const uint64_t hold_us    = (uint64_t)s_cfg.hold_duration_ms * 1000;
    const uint64_t timeout_us = (uint64_t)REP_PHASE_TIMEOUT_MS * 1000;

    const float angle = motion->elbow_angle_deg;
    const float start_th  = s_calib.angle_min + s_cfg.start_angle_deg;
    const float finish_th = s_calib.angle_min + s_cfg.finish_angle_deg;
    const float peak_th   = s_calib.angle_min +
                            s_cfg.target_angle_deg * REP_PEAK_FRAC;

    switch (s.state) {

    case REP_READY:
        /* THE GATE [PRD §5.4]. Posture alone is not enough: an arm somebody
         * else is moving satisfies every geometric condition. */
        if (angle > start_th) {
            if (!act) {
                /* The arm is rising and the agonist is quiet. This is the
                 * passive swing the whole device exists to catch. Report it,
                 * do not count it, and do not arm. */
                out->event = REP_EVT_PASSIVE_SWING;
                break;
            }
            if (!posture_ok(motion)) {
                out->event = REP_EVT_START_POS_BAD;
                break;
            }
            begin_repetition(motion, t_us);
            out->event = REP_EVT_REP_START;
            enter(REP_CONCENTRIC, t_us);
        } else {
            out->event = REP_EVT_START_POS_OK;
        }
        break;

    case REP_CONCENTRIC:
        accumulate_motion(motion, emg);
        check_compensation(motion);

        if (angle >= peak_th) {
            /* Soft click: "you may begin the return." The one cue that fires
             * mid-movement rather than at a stationary moment, which is why
             * it is the shortest and lightest in the set. */
            out->event = REP_EVT_PEAK_REACHED;
            enter(REP_PEAK, t_us);
        } else if (angle < finish_th) {
            /* Fell back below the finish threshold without reaching the
             * target: a partial, reported and not counted. */
            out->event = REP_EVT_REP_ABANDONED;
            enter(REP_READY, t_us);
        } else if (t_us - s.state_entered_us > timeout_us) {
            out->event = REP_EVT_REP_ABANDONED;
            enter(REP_READY, t_us);
        }
        break;

    case REP_PEAK:
        accumulate_motion(motion, emg);
        check_compensation(motion);

        /* Reversal on the low-passed velocity rather than a fixed negative
         * rate, which jitters at the top of a slow curl. */
        if (s.vel_lp < 0.0f) {
            enter(REP_ECCENTRIC, t_us);
        } else if (t_us - s.state_entered_us > timeout_us) {
            out->event = REP_EVT_REP_ABANDONED;
            enter(REP_READY, t_us);
        }
        break;

    case REP_ECCENTRIC:
        accumulate_motion(motion, emg);
        check_compensation(motion);

        if (angle <= finish_th) {
            /* Tempo is measured start threshold to finish threshold and
             * excludes the confirming hold [PRD §5.4]. */
            s.rep_finish_us = t_us;
            enter(REP_EXTENDED_HOLD, t_us);
            s.hold_sum = s.hold_sum_sq = 0.0f;
            s.hold_samples = 0;
        } else if (t_us - s.state_entered_us > timeout_us) {
            out->event = REP_EVT_REP_ABANDONED;
            enter(REP_READY, t_us);
        }
        break;

    case REP_EXTENDED_HOLD:
        if (angle > start_th) {
            /* Left the extended position before the hold completed — started
             * the next curl early. Nothing counts; back to READY, where the
             * gate will arm again if the agonist is live. */
            s.hold_running = false;
            out->event     = REP_EVT_REP_ABANDONED;
            enter(REP_READY, t_us);
            break;
        }

        if (!settled(motion)) {
            /* Inside the band but still moving: the hold has not begun.
             * Waiting to settle is what makes "hold for one second" mean a
             * second of stillness rather than a second of anything at all. */
            s.hold_running = false;
            if (t_us - s.state_entered_us > timeout_us) {
                out->event = REP_EVT_REP_ABANDONED;
                enter(REP_READY, t_us);
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
            complete_repetition(motion, emg, t_us, out);
            enter(REP_READY, t_us);
        }
        break;
    }

    out->state     = s.state;
    out->rep_count = s.rep_count;
    if (out->event != REP_EVT_REP_COMPLETE) {
        out->comp_flags = s.comp_flags;
    }
}
