/*
 * calibration.c — the six-step protocol, donning check and NVS persistence
 *                 [PRD §5.3]
 *
 * Calibration works in RAW RMS throughout. The normalised %MVC envelope every
 * other consumer sees is derived FROM these numbers, so using it here would be
 * circular — on a first calibration there is no maximum to normalise against.
 */

#include <string.h>
#include <math.h>
#include <inttypes.h>
#include "nvs_flash.h"
#include "nvs.h"
#include "esp_log.h"
#include "esp_check.h"

#include "calibration.h"
#include "rehab_config.h"
#include "rehab_time.h"

static const char *TAG = "calib";

/* Which steps a run still has to get through. */
typedef struct {
    calib_phase_t step;
    uint64_t      step_start_us;
    bool          running;

    /* Queue, for ALL and the session re-zero. */
    calib_phase_t queue[6];
    uint8_t       queue_n, queue_i;

    /* Stillness gate (steps 1 and 2). */
    uint32_t      unsettled_ms;

    /* Step 1 — rest */
    double        rest_sum[EMG_N_CHANNELS];
    double        rest_sum_sq[EMG_N_CHANNELS];
    uint32_t      rest_n;

    /* Step 2 — straight arm */
    double        q_up_sum[4], q_fo_sum[4];
    uint32_t      pose_n;

    /* Steps 3, 4 — maxima. One channel at a time. */
    uint8_t       mvc_channel;
    uint8_t       attempt;
    float         win_buf[CALIB_MVC_WINDOW_SAMPLES];
    uint32_t      win_pos;
    float         win_sum;
    bool          win_primed;
    float         attempt_best;        /* strongest window this attempt */
    float         overall_best;        /* best across attempts          */
    double        mdf_sum;
    uint32_t      mdf_n;

    /* Which steps have produced a value this run. */
    bool          have_rest, have_pose, have_biceps, have_triceps, have_sweep;

    calib_record_t rec;
} calib_ctx_t;

static calib_ctx_t c;

/* ────────────────────────────────────────────────────────────────────── */

void calibration_init(void)
{
    memset(&c, 0, sizeof(c));
    c.step = CALIB_IDLE;
}

const calib_record_t *calibration_record(void) { return &c.rec; }

bool calibration_complete(void)
{
    /* Everything the scoring path needs. Steps 3 and 4 may have come from a
     * stored profile rather than from this run. */
    if (!(c.have_rest && c.have_pose && c.have_sweep)) {
        return false;
    }
    for (int i = 0; i < EMG_N_CHANNELS; i++) {
        if (c.rec.emg_mvc[i] <= 0.0f) {
            return false;
        }
    }
    return true;
}

static void queue_set(const calib_phase_t *steps, uint8_t n)
{
    c.queue_n = (n > 6) ? 6 : n;
    c.queue_i = 0;
    memcpy(c.queue, steps, c.queue_n * sizeof(calib_phase_t));
}

static void enter_step(calib_phase_t step, uint64_t t_us)
{
    c.step          = step;
    c.step_start_us = t_us;
    c.running       = true;
    c.unsettled_ms  = 0;

    switch (step) {
    case CALIB_STEP_REST:
        memset(c.rest_sum, 0, sizeof(c.rest_sum));
        memset(c.rest_sum_sq, 0, sizeof(c.rest_sum_sq));
        c.rest_n = 0;
        fusion_bias_capture_begin();
        break;
    case CALIB_STEP_STRAIGHT:
        memset(c.q_up_sum, 0, sizeof(c.q_up_sum));
        memset(c.q_fo_sum, 0, sizeof(c.q_fo_sum));
        c.pose_n = 0;
        break;
    case CALIB_STEP_BICEPS:
    case CALIB_STEP_TRICEPS:
        c.mvc_channel  = (step == CALIB_STEP_BICEPS) ? 0 : 1;
        c.attempt      = 0;
        c.attempt_best = 0.0f;
        c.overall_best = 0.0f;
        c.win_pos      = 0;
        c.win_sum      = 0.0f;
        c.win_primed   = false;
        c.mdf_sum      = 0.0;
        c.mdf_n        = 0;
        memset(c.win_buf, 0, sizeof(c.win_buf));
        break;
    case CALIB_STEP_SWEEP:
        fusion_rom_sweep_begin();
        break;
    default:
        break;
    }
}

void calibration_begin_step(calib_phase_t step)
{
    c.queue_n = 0;
    c.queue_i = 0;
    enter_step(step, 0);
    ESP_LOGI(TAG, "step %d started", (int)step);
}

void calibration_begin_all(void)
{
    static const calib_phase_t all[] = {
        CALIB_STEP_REST, CALIB_STEP_STRAIGHT, CALIB_STEP_BICEPS,
#if EMG_N_CHANNELS > 1
        CALIB_STEP_TRICEPS,
#endif
        CALIB_STEP_SWEEP,
    };
    memset(&c.rec, 0, sizeof(c.rec));
    c.have_rest = c.have_pose = c.have_biceps = c.have_triceps = c.have_sweep = false;
    queue_set(all, sizeof(all) / sizeof(all[0]));
    enter_step(all[0], 0);
    ESP_LOGI(TAG, "full calibration started (%u steps, ~%u s of capture)",
             (unsigned)(sizeof(all) / sizeof(all[0])),
             (unsigned)((CALIB_REST_MS + CALIB_STRAIGHT_MS + CALIB_SWEEP_MS +
                         CALIB_MVC_MS * CALIB_MVC_ATTEMPTS * EMG_N_CHANNELS)
                        / 1000));
}

void calibration_begin_session_rezero(void)
{
    /* Steps 1, 2 and 5 re-run every session: they reset gyroscope bias and IMU
     * drift and absorb day-to-day variation in sleeve placement. The maxima
     * carry over from the stored profile [PRD §5.3]. */
    static const calib_phase_t rez[] = {
        CALIB_STEP_REST, CALIB_STEP_STRAIGHT, CALIB_STEP_SWEEP,
    };
    queue_set(rez, 3);
    enter_step(rez[0], 0);
    ESP_LOGI(TAG, "session re-zero: steps 1, 2, 5");
}

void calibration_abort(void)
{
    c.running = false;
    c.queue_n = 0;
    c.step    = CALIB_IDLE;
    ESP_LOGW(TAG, "calibration aborted");
}

void calibration_set_record(const calib_record_t *rec, bool clinician_override)
{
    if (!rec) {
        return;
    }
    memcpy(&c.rec, rec, sizeof(c.rec));
    if (clinician_override) {
        c.rec.flags |= CALIB_FLAG_CLINICIAN_OVERRIDE;
        /* A clinician-supplied normalisation supersedes the measured one, so
         * the unreliable flag no longer applies [PRD §5.3]. */
        c.rec.flags &= ~CALIB_FLAG_MVC_UNRELIABLE;
        ESP_LOGI(TAG, "clinician override installed: MVC %.4f / %.4f",
                 c.rec.emg_mvc[0], c.rec.emg_mvc[1]);
    }
    c.have_rest = c.have_pose = c.have_sweep = true;
    c.have_biceps = c.have_triceps = true;
    fusion_set_calibration(&c.rec);
}

/* ────────────────────────────────────────────────────────────────────── */

/* Stillness gate for steps 1 and 2. A brief wobble is tolerated; sustained
 * movement rejects the step rather than quietly averaging it in. */
static bool still_enough(const fusion_out_t *m)
{
    const bool gyro_ok  = m->upper_arm_rate_dps <= CALIB_STILL_GYRO_DPS;
    const bool accel_ok = fabsf(m->max_accel_g - 1.0f) <= CALIB_STILL_ACCEL_TOL;
    return gyro_ok && accel_ok;
}

static void finish_step(calib_progress_t *pr, bool ok, calib_reject_t why,
                        const char *msg, uint64_t t_us)
{
    c.running = false;
    pr->reject = why;
    pr->message = msg;

    if (!ok) {
        c.step        = CALIB_FAILED;
        pr->phase     = CALIB_FAILED;
        pr->phase_changed = true;
        ESP_LOGW(TAG, "step rejected: %s", msg ? msg : "");
        return;
    }

    pr->step_complete = true;
    pr->phase_changed = true;

    /* Advance the queue, if one is running. */
    if (c.queue_n > 0 && c.queue_i + 1 < c.queue_n) {
        c.queue_i++;
        enter_step(c.queue[c.queue_i], t_us);
        pr->phase = c.step;
        return;
    }

    c.queue_n = 0;
    c.step    = CALIB_DONE;
    pr->phase = CALIB_DONE;

    if (calibration_complete()) {
        c.rec.version = CALIB_RECORD_VERSION;
        fusion_set_calibration(&c.rec);
        ESP_LOGI(TAG, "calibration complete: ROM %.1f-%.1f deg, "
                      "MVC %.4f / %.4f, rest sd %.5f / %.5f",
                 c.rec.angle_min, c.rec.angle_max,
                 c.rec.emg_mvc[0], c.rec.emg_mvc[1],
                 c.rec.emg_rest_sd[0], c.rec.emg_rest_sd[1]);
    }
}

/* Sliding RMS window used by the maximum-contraction steps: the measurement is
 * the strongest CALIB_MVC_WINDOW_MS of the attempt, not its single loudest
 * sample, which would be noise [PRD §5.3]. */
static void window_push(float v)
{
    const float old = c.win_buf[c.win_pos];
    c.win_buf[c.win_pos] = v;
    c.win_sum += v - old;
    c.win_pos = (c.win_pos + 1) % CALIB_MVC_WINDOW_SAMPLES;
    if (c.win_pos == 0) {
        c.win_primed = true;
    }
    if (c.win_primed) {
        const float mean = c.win_sum / (float)CALIB_MVC_WINDOW_SAMPLES;
        if (mean > c.attempt_best) {
            c.attempt_best = mean;
        }
    }
}

void calibration_tick(const emg_features_t *emg, const fusion_out_t *motion,
                      uint64_t t_us, calib_progress_t *pr)
{
    memset(pr, 0, sizeof(*pr));
    pr->phase   = c.step;
    pr->attempt = c.attempt;

    if (!c.running || c.step == CALIB_IDLE ||
        c.step == CALIB_DONE || c.step == CALIB_FAILED) {
        return;
    }

    if (c.step_start_us == 0) {
        c.step_start_us = t_us;
    }
    const uint32_t elapsed_ms = (uint32_t)((t_us - c.step_start_us) / 1000);

    /* Raw RMS, not the normalised envelope: on a first calibration there is no
     * maximum to normalise against. */
    float raw[EMG_N_CHANNELS];
    emg_dsp_raw_rms(raw);

    switch (c.step) {

    /* ── Step 1: rest baseline, sigma, gyroscope bias ─────────────────── */
    case CALIB_STEP_REST:
        pr->message = "Relax your arm at your side and keep it still";
        pr->percent = (uint8_t)((elapsed_ms * 100) / CALIB_REST_MS);

        if (!still_enough(motion)) {
            c.unsettled_ms += ANALYSIS_PERIOD_MS;
            if (c.unsettled_ms > CALIB_STILL_GRACE_MS) {
                finish_step(pr, false, CALIB_REJECT_MOVED,
                            "Your arm moved — let it rest completely still "
                            "and we'll try that step again", t_us);
                return;
            }
        }

        for (int i = 0; i < EMG_N_CHANNELS; i++) {
            c.rest_sum[i]    += raw[i];
            c.rest_sum_sq[i] += (double)raw[i] * raw[i];
        }
        c.rest_n++;

        if (elapsed_ms >= CALIB_REST_MS) {
            if (c.rest_n < 2) {
                finish_step(pr, false, CALIB_REJECT_MOVED,
                            "Not enough data captured", t_us);
                return;
            }
            for (int i = 0; i < EMG_N_CHANNELS; i++) {
                const double n    = (double)c.rest_n;
                const double mean = c.rest_sum[i] / n;
                double var = c.rest_sum_sq[i] / n - mean * mean;
                if (var < 0.0) var = 0.0;

                c.rec.emg_rest_rms[i] = (float)mean;
                c.rec.emg_rest_sd[i]  = (float)sqrt(var);
            }

            /* Gyroscope bias. Movement here corrupts the joint angle for the
             * whole session with no obvious symptom, which is what the
             * stillness gate above exists to prevent. */
            if (fusion_bias_capture_end(c.rec.gyro_bias) != ESP_OK) {
                finish_step(pr, false, CALIB_REJECT_MOVED,
                            "Could not measure sensor bias — try that step "
                            "again", t_us);
                return;
            }

            c.have_rest = true;
            ESP_LOGI(TAG, "rest: mean %.5f/%.5f sd %.5f/%.5f",
                     c.rec.emg_rest_rms[0], c.rec.emg_rest_rms[1],
                     c.rec.emg_rest_sd[0],  c.rec.emg_rest_sd[1]);
            finish_step(pr, true, CALIB_REJECT_NONE, "Rest captured", t_us);
        }
        break;

    /* ── Step 2: comfortable-straight reference pose ──────────────────── */
    case CALIB_STEP_STRAIGHT: {
        /* "Comfortable straight", never "locked straight" [PRD §5.3]:
         * calibrating against a hyperextended pose makes returns finish short
         * of the finish threshold, so repetitions never complete. */
        pr->message = "Straighten your arm as far as is comfortable — not "
                      "locked — and hold still";
        pr->percent = (uint8_t)((elapsed_ms * 100) / CALIB_STRAIGHT_MS);

        if (!still_enough(motion)) {
            c.unsettled_ms += ANALYSIS_PERIOD_MS;
            if (c.unsettled_ms > CALIB_STILL_GRACE_MS) {
                finish_step(pr, false, CALIB_REJECT_MOVED,
                            "Hold your arm still for this step", t_us);
                return;
            }
        }

        quat_t qu, qf;
        fusion_get_quats(&qu, &qf);
        const float *u = &qu.w, *f = &qf.w;
        for (int i = 0; i < 4; i++) {
            c.q_up_sum[i] += u[i];
            c.q_fo_sum[i] += f[i];
        }
        c.pose_n++;

        if (elapsed_ms >= CALIB_STRAIGHT_MS) {
            if (c.pose_n == 0) {
                finish_step(pr, false, CALIB_REJECT_MOVED, "No pose captured",
                            t_us);
                return;
            }
            const double n = (double)c.pose_n;
            for (int i = 0; i < 4; i++) {
                c.rec.q_upper0[i] = (float)(c.q_up_sum[i] / n);
                c.rec.q_fore0[i]  = (float)(c.q_fo_sum[i] / n);
            }
            /* Renormalise: averaging unit quaternions does not preserve unit
             * length. */
            for (int s = 0; s < 2; s++) {
                float *q = s ? c.rec.q_fore0 : c.rec.q_upper0;
                const float nn = sqrtf(q[0]*q[0] + q[1]*q[1] +
                                       q[2]*q[2] + q[3]*q[3]);
                if (nn > 1e-6f) {
                    for (int i = 0; i < 4; i++) q[i] /= nn;
                }
            }
            c.have_pose = true;
            fusion_set_calibration(&c.rec);
            finish_step(pr, true, CALIB_REJECT_NONE, "Reference pose captured",
                        t_us);
        }
        break;
    }

    /* ── Steps 3 and 4: maxima, best of three ─────────────────────────── */
    case CALIB_STEP_BICEPS:
    case CALIB_STEP_TRICEPS: {
        const bool biceps = (c.step == CALIB_STEP_BICEPS);
        pr->message = biceps
            ? "Elbow at about 90 degrees — push UP against the table"
            : "Same position — now push DOWN against the table";

        const uint32_t per = CALIB_MVC_MS;
        c.attempt   = (uint8_t)(elapsed_ms / per);
        pr->attempt = c.attempt;
        pr->percent = (uint8_t)((elapsed_ms * 100) / (per * CALIB_MVC_ATTEMPTS));

        window_push(raw[c.mvc_channel]);

        if (emg->mdf[c.mvc_channel] > 0.0f) {
            c.mdf_sum += emg->mdf[c.mvc_channel];
            c.mdf_n++;
        }

        /* End of an attempt: keep it if it beat the others, then reset. */
        static uint8_t last_attempt;
        if (c.attempt != last_attempt) {
            if (c.attempt_best > c.overall_best) {
                c.overall_best = c.attempt_best;
            }
            c.attempt_best = 0.0f;
            c.win_primed   = false;
            c.win_pos      = 0;
            c.win_sum      = 0.0f;
            memset(c.win_buf, 0, sizeof(c.win_buf));
            last_attempt = c.attempt;
        }

        if (c.attempt >= CALIB_MVC_ATTEMPTS) {
            if (c.attempt_best > c.overall_best) {
                c.overall_best = c.attempt_best;
            }
            last_attempt = 0;

            const int ch = c.mvc_channel;
            c.rec.emg_mvc[ch] = c.overall_best;
            if (c.mdf_n > 0) {
                c.rec.mdf_baseline[ch] = (float)(c.mdf_sum / (double)c.mdf_n);
            }

            /* A maximum that barely exceeds the noise floor is not a maximum.
             * Flag it rather than scaling everything against a meaningless
             * number; the device then scales against the patient's own stored
             * history instead [PRD §5.3]. */
            const float floor_v = c.rec.emg_rest_rms[ch];
            if (floor_v <= 0.0f ||
                c.rec.emg_mvc[ch] < floor_v * CALIB_MVC_MIN_SNR) {
                c.rec.flags |= CALIB_FLAG_MVC_UNRELIABLE;
                ESP_LOGW(TAG, "channel %d MVC %.5f not credible against a "
                              "%.5f noise floor — flagged unreliable",
                         ch, c.rec.emg_mvc[ch], floor_v);
            }

            if (biceps) c.have_biceps  = true;
            else        c.have_triceps = true;

            ESP_LOGI(TAG, "%s maximum: %.5f",
                     biceps ? "biceps" : "triceps", c.rec.emg_mvc[ch]);
            finish_step(pr, true, CALIB_REJECT_NONE,
                        biceps ? "Biceps maximum captured"
                               : "Triceps maximum captured", t_us);
        }
        break;
    }

    /* ── Step 5: range sweep ──────────────────────────────────────────── */
    case CALIB_STEP_SWEEP: {
        pr->message = "Slowly curl all the way up and back down, twice";
        pr->percent = (uint8_t)((elapsed_ms * 100) / CALIB_SWEEP_MS);

        if (elapsed_ms >= CALIB_SWEEP_MS) {
            float axis[3], amin, amax;
            if (fusion_rom_sweep_end(axis, &amin, &amax) != ESP_OK) {
                finish_step(pr, false, CALIB_REJECT_NO_RANGE,
                            "Not enough movement to measure your range — try "
                            "the sweep again", t_us);
                return;
            }
            memcpy(c.rec.flexion_axis, axis, sizeof(axis));
            c.rec.angle_min = amin;
            c.rec.angle_max = amax;
            c.have_sweep    = true;
            finish_step(pr, true, CALIB_REJECT_NONE, "Range captured", t_us);
        }
        break;
    }

    default:
        break;
    }

    pr->phase = c.step;
}

/* ── NVS ─────────────────────────────────────────────────────────────── */

esp_err_t calibration_load_nvs(calib_record_t *out)
{
    nvs_handle_t h;
    ESP_RETURN_ON_ERROR(nvs_open(NVS_NAMESPACE, NVS_READONLY, &h),
                        TAG, "nvs open");

    size_t len = sizeof(*out);
    esp_err_t err = nvs_get_blob(h, NVS_KEY_CALIB, out, &len);
    nvs_close(h);

    if (err != ESP_OK) {
        return err;
    }
    if (len != sizeof(*out) || out->version != CALIB_RECORD_VERSION) {
        ESP_LOGW(TAG, "stored profile has version %" PRIu32 ", expected %d — "
                      "ignoring", out->version, CALIB_RECORD_VERSION);
        return ESP_ERR_INVALID_VERSION;
    }

    memcpy(&c.rec, out, sizeof(*out));
    c.have_rest = c.have_pose = c.have_sweep = true;
    c.have_biceps = c.have_triceps = true;
    ESP_LOGI(TAG, "loaded profile: ROM %.1f-%.1f deg, captured at epoch %" PRIu32,
             out->angle_min, out->angle_max, out->timestamp);
    return ESP_OK;
}

esp_err_t calibration_save_nvs(const calib_record_t *rec)
{
    calib_record_t r = *rec;
    r.version = CALIB_RECORD_VERSION;

    /* Stamp the record at save time. Without this the staleness check reads an
     * always-zero timestamp, treats every stored profile as expired, and makes
     * a returning patient repeat the full protocol every session. */
    r.timestamp = rehab_now_epoch_s();

    nvs_handle_t h;
    ESP_RETURN_ON_ERROR(nvs_open(NVS_NAMESPACE, NVS_READWRITE, &h),
                        TAG, "nvs open");
    esp_err_t err = nvs_set_blob(h, NVS_KEY_CALIB, &r, sizeof(r));
    if (err == ESP_OK) {
        err = nvs_commit(h);
    }
    nvs_close(h);

    if (err == ESP_OK) {
        c.rec.timestamp = r.timestamp;
        ESP_LOGI(TAG, "profile saved, timestamp %" PRIu32, r.timestamp);
    }
    return err;
}

bool calibration_is_stale(const calib_record_t *rec, uint32_t now_epoch_s)
{
    if (rec->timestamp == 0) {
        return true;   /* never stamped: cannot vouch for it */
    }
    if (now_epoch_s == 0 || now_epoch_s < rec->timestamp) {
        /* No wall clock yet, or one that predates the record. Age is unknown,
         * which is not the same as expired: the profile is still internally
         * consistent, and forcing a full recalibration on every boot because
         * the host has not sent SET_TIME yet is worse than using it. */
        ESP_LOGW(TAG, "no host time; treating stored profile as current");
        return false;
    }
    const uint32_t age_days = (now_epoch_s - rec->timestamp) / 86400;
    return age_days > CALIB_PROFILE_STALE_DAYS;
}

/* ──────────────────────────────────────────────────────────────────────
 * Donning check — step 0 [PRD §5.3]
 *
 * None of this needs a classifier. Correct donning is directly observable:
 * gravity is where it should be, both channels show life, neither is
 * saturated, mains pickup is within limits, and during a test curl the biceps
 * must exceed the triceps while the forearm rotates and the upper arm stays
 * comparatively still.
 * ────────────────────────────────────────────────────────────────────── */

static struct {
    uint64_t start_us;
    float    bicep_sum, tricep_sum;
    float    active_sum, quiet_sum;      /* envelope while moving / still */
    uint32_t active_n, quiet_n;
    float    fore_motion, upper_motion;
    float    mains_max;
    uint32_t clip_start[EMG_N_CHANNELS];
    uint32_t n;
    bool     running;
    bool     clip_latched;
} d;

void donning_check_begin(void)
{
    memset(&d, 0, sizeof(d));
    d.running = true;
}

donning_result_t donning_check_tick(const emg_features_t *emg,
                                    const fusion_out_t *motion,
                                    uint64_t t_us, const char **message)
{
    if (!d.running) {
        return DON_PENDING;
    }
    if (d.start_us == 0) {
        d.start_us = t_us;
        for (int i = 0; i < EMG_N_CHANNELS; i++) {
            d.clip_start[i] = emg->clip_count[i];
        }
    }

    const uint64_t elapsed_ms = (t_us - d.start_us) / 1000;
    *message = "Curl your arm once, then relax";

    d.bicep_sum    += emg->envelope[EMG_CH_AGONIST];
#if EMG_N_CHANNELS > 1
    d.tricep_sum   += emg->envelope[EMG_CH_ANTAGONIST];
#endif
    d.fore_motion  += fabsf(motion->elbow_velocity_dps);
    d.upper_motion += motion->upper_arm_rate_dps;
    d.n++;

    /* Split the capture by whether the elbow is moving, so the single-channel
     * placement test can ask whether the muscle responded to the movement. */
    if (fabsf(motion->elbow_velocity_dps) > DON_MOVING_DPS) {
        d.active_sum += emg->envelope[EMG_CH_AGONIST];
        d.active_n++;
    } else {
        d.quiet_sum += emg->envelope[EMG_CH_AGONIST];
        d.quiet_n++;
    }

    for (int i = 0; i < EMG_N_CHANNELS; i++) {
        if (emg->mains_frac[i] > d.mains_max) {
            d.mains_max = emg->mains_frac[i];
        }
        if (emg->clip_count[i] - d.clip_start[i] > CALIB_MAX_CLIP_COUNT) {
            d.clip_latched = true;
        }
    }

    if (elapsed_ms < CALIB_CONTACT_MS) {
        return DON_PENDING;
    }

    d.running = false;

    if (d.n == 0) {
        *message = "No sensor data";
        return DON_IMU_DEAD;
    }

    /* Saturation first: a clipping channel makes every other measurement
     * below untrustworthy, and clipping destroys the median-frequency
     * estimate while leaving the envelope looking plausible. */
    if (d.clip_latched) {
        *message = "A sensor is saturating — turn the MyoWare gain down until "
                   "the clipping counter stays at zero";
        return DON_SATURATED;
    }

    if (d.mains_max > CALIB_MAX_MAINS_FRAC) {
        *message = "Too much mains interference — move away from chargers and "
                   "mains leads, and keep the electrode leads short";
        return DON_MAINS;
    }

    const float bicep = d.bicep_sum / d.n;

    if (bicep < 1e-4f) {
#if EMG_N_CHANNELS > 1
        if (d.tricep_sum / d.n < 1e-4f) {
            *message = "Neither EMG channel is reading — check electrode "
                       "contact and that both sensors have power";
            return DON_EMG_DEAD;
        }
#else
        *message = "The EMG channel is not reading — check that both biceps "
                   "electrodes and the elbow reference are making contact, "
                   "and that the sensor has power";
        return DON_EMG_DEAD;
#endif
    }

    if (d.fore_motion / d.n < 2.0f) {
        *message = "No elbow movement detected — the forearm sensor may not "
                   "be reading";
        return DON_IMU_DEAD;
    }

#if EMG_N_CHANNELS > 1
    /* Two-channel orientation test. If the triceps channel dominated during a
     * curl, the sleeve is on backwards or the leads are crossed. Saying which
     * is more useful than a generic failure. */
    if ((d.tricep_sum / d.n) > bicep * 1.3f) {
        *message = "The sleeve appears to be on backwards, or the biceps and "
                   "triceps leads are swapped";
        return DON_CHANNELS_SWAPPED;
    }
#else
    /* Single-channel placement test.
     *
     * With one channel there is nothing to compare against, so the backwards
     * sleeve cannot be detected as such. What CAN be checked is that the
     * channel responds to the movement it is supposed to measure: a biceps
     * electrode pair on the muscle belly produces a clear rise during a curl,
     * while a pair on the triceps, off the belly, or lifted does not.
     *
     * This catches a dead, misplaced or badly-contacted electrode. It does
     * not distinguish "on the wrong muscle" from "on the right muscle but not
     * contracting", and the message says so rather than claiming more. */
    const float mean_active = d.active_n ? (d.active_sum / d.active_n) : 0.0f;
    const float mean_quiet  = d.quiet_n  ? (d.quiet_sum  / d.quiet_n)  : 0.0f;

    if (d.active_n < (uint32_t)(FEATURE_RATE_HZ / 4) ||
        mean_active <= mean_quiet * DON_MIN_ACTIVE_RATIO) {
        *message = "The biceps channel did not respond while your arm moved — "
                   "check the two electrodes are on the muscle belly about "
                   "20 mm apart and the reference is on the elbow";
        return DON_CHANNELS_SWAPPED;
    }
#endif

    *message = "Sleeve is on correctly";
    return DON_PASS;
}
