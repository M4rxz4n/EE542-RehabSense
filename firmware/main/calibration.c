/*
 * calibration.c — calibration protocol, donning check and NVS persistence
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

static const char *TAG = "calib";

typedef struct {
    calib_phase_t phase;
    uint64_t      phase_start_us;
    uint8_t       attempt;
    bool          neutral_only;

    /* Rest accumulation */
    double rest_sum[EMG_N_CHANNELS];
    double rest_sum_sq[EMG_N_CHANNELS];
    uint32_t rest_n;

    /* MVC: peak envelope per attempt, best kept */
    float  mvc_peak[EMG_N_CHANNELS];
    float  mvc_best[EMG_N_CHANNELS];
    float  mdf_sum[EMG_N_CHANNELS];
    uint32_t mdf_n;

    /* Neutral pose averaging */
    double q_up_sum[4], q_fo_sum[4];
    uint32_t pose_n;

    calib_record_t rec;
    bool           complete;
} calib_ctx_t;

static calib_ctx_t c;

void calibration_init(void)
{
    memset(&c, 0, sizeof(c));
    c.phase = CALIB_IDLE;
}

void calibration_begin(void)
{
    const calib_record_t keep = c.rec;
    memset(&c, 0, sizeof(c));
    c.rec   = keep;
    c.phase = CALIB_REST;
    ESP_LOGI(TAG, "full calibration started");
}

void calibration_begin_neutral_only(void)
{
    const calib_record_t keep = c.rec;
    memset(&c, 0, sizeof(c));
    c.rec          = keep;
    c.neutral_only = true;
    c.phase        = CALIB_NEUTRAL;
    ESP_LOGI(TAG, "session re-zero: neutral pose only");
}

void calibration_abort(void)
{
    c.phase    = CALIB_IDLE;
    c.complete = false;
    ESP_LOGW(TAG, "calibration aborted");
}

bool calibration_complete(void) { return c.complete; }
const calib_record_t *calibration_record(void) { return &c.rec; }

static void enter_phase(calib_phase_t p, uint64_t t_us, calib_progress_t *pr)
{
    c.phase          = p;
    c.phase_start_us = t_us;
    pr->phase_changed = true;
}

void calibration_tick(const emg_features_t *emg, const fusion_out_t *motion,
                      uint64_t t_us, calib_progress_t *pr)
{
    memset(pr, 0, sizeof(*pr));
    pr->phase   = c.phase;
    pr->attempt = c.attempt;

    if (c.phase == CALIB_IDLE || c.phase == CALIB_DONE ||
        c.phase == CALIB_FAILED) {
        return;
    }

    if (c.phase_start_us == 0) {
        c.phase_start_us = t_us;
    }
    const uint64_t elapsed_ms = (t_us - c.phase_start_us) / 1000;

    switch (c.phase) {

    case CALIB_REST:
        pr->message = "Relax your arm and keep it still";
        pr->percent = (uint8_t)((elapsed_ms * 100) / CALIB_REST_MS);

        for (int i = 0; i < EMG_N_CHANNELS; i++) {
            c.rest_sum[i]    += emg->envelope[i];
            c.rest_sum_sq[i] += (double)emg->envelope[i] * emg->envelope[i];
        }
        c.rest_n++;

        if (elapsed_ms >= CALIB_REST_MS) {
            for (int i = 0; i < EMG_N_CHANNELS; i++) {
                c.rec.emg_rest_rms[i] =
                    (float)(c.rest_sum[i] / (c.rest_n ? c.rest_n : 1));
            }
            ESP_LOGI(TAG, "rest baseline: %.4f / %.4f",
                     c.rec.emg_rest_rms[0], c.rec.emg_rest_rms[1]);
            c.attempt = 0;
            memset(c.mvc_peak, 0, sizeof(c.mvc_peak));
            enter_phase(CALIB_MVC, t_us, pr);
        }
        break;

    case CALIB_MVC: {
        /* Best of three attempts. Paretic-limb effort is inconsistent, and a
         * single bad trial would permanently mis-scale every subsequent
         * measurement. */
        const uint32_t cycle = CALIB_MVC_HOLD_MS + CALIB_MVC_REST_MS;
        const uint32_t in_cycle = elapsed_ms % cycle;
        const bool contracting = in_cycle < CALIB_MVC_HOLD_MS;

        pr->message = contracting ? "Curl as hard as you comfortably can"
                                  : "Rest";
        pr->attempt = (uint8_t)(elapsed_ms / cycle);
        pr->percent = (uint8_t)((elapsed_ms * 100) /
                                (cycle * CALIB_MVC_ATTEMPTS));

        if (contracting) {
            for (int i = 0; i < EMG_N_CHANNELS; i++) {
                if (emg->envelope[i] > c.mvc_peak[i]) {
                    c.mvc_peak[i] = emg->envelope[i];
                }
                if (emg->mdf[i] > 0.0f) {
                    c.mdf_sum[i] += emg->mdf[i];
                }
            }
            if (emg->mdf[0] > 0.0f) c.mdf_n++;
        } else if (in_cycle < CALIB_MVC_HOLD_MS + 100) {
            /* Just finished an attempt — keep it if it beat the others. */
            for (int i = 0; i < EMG_N_CHANNELS; i++) {
                if (c.mvc_peak[i] > c.mvc_best[i]) {
                    c.mvc_best[i] = c.mvc_peak[i];
                }
                c.mvc_peak[i] = 0.0f;
            }
        }

        if (pr->attempt >= CALIB_MVC_ATTEMPTS) {
            for (int i = 0; i < EMG_N_CHANNELS; i++) {
                if (c.mvc_peak[i] > c.mvc_best[i]) {
                    c.mvc_best[i] = c.mvc_peak[i];
                }
                c.rec.emg_mvc[i] = c.mvc_best[i];
                c.rec.mdf_baseline[i] =
                    c.mdf_n ? (c.mdf_sum[i] / c.mdf_n) : 0.0f;
            }

            /* Plausibility: a maximum that barely exceeds the noise floor is
             * not a maximum. Flag it rather than scaling everything against
             * a meaningless number. */
            c.rec.flags &= ~CALIB_FLAG_MVC_UNRELIABLE;
            for (int i = 0; i < EMG_N_CHANNELS; i++) {
                const float floor_v = c.rec.emg_rest_rms[i];
                if (floor_v <= 0.0f ||
                    c.rec.emg_mvc[i] < floor_v * CALIB_MVC_MIN_SNR) {
                    c.rec.flags |= CALIB_FLAG_MVC_UNRELIABLE;
                    ESP_LOGW(TAG, "channel %d MVC %.4f is not credible against "
                                  "a %.4f noise floor — flagged unreliable",
                             i, c.rec.emg_mvc[i], floor_v);
                }
            }
            ESP_LOGI(TAG, "MVC: %.4f / %.4f", c.rec.emg_mvc[0], c.rec.emg_mvc[1]);
            enter_phase(CALIB_NEUTRAL, t_us, pr);
        }
        break;
    }

    case CALIB_NEUTRAL: {
        pr->message = "Let your arm hang straight down and hold still";
        pr->percent = (uint8_t)((elapsed_ms * 100) / CALIB_NEUTRAL_MS);

        quat_t qu, qf;
        fusion_get_quats(&qu, &qf);
        const float *u = &qu.w, *f = &qf.w;
        for (int i = 0; i < 4; i++) {
            c.q_up_sum[i] += u[i];
            c.q_fo_sum[i] += f[i];
        }
        c.pose_n++;

        if (elapsed_ms >= CALIB_NEUTRAL_MS) {
            const double nu = c.pose_n ? c.pose_n : 1;
            for (int i = 0; i < 4; i++) {
                c.rec.q_upper0[i] = (float)(c.q_up_sum[i] / nu);
                c.rec.q_fore0[i]  = (float)(c.q_fo_sum[i] / nu);
            }
            /* Renormalise: averaging quaternions does not preserve unit
             * length. */
            for (int s = 0; s < 2; s++) {
                float *q = s ? c.rec.q_fore0 : c.rec.q_upper0;
                const float n = sqrtf(q[0]*q[0] + q[1]*q[1] + q[2]*q[2] + q[3]*q[3]);
                if (n > 1e-6f) {
                    for (int i = 0; i < 4; i++) q[i] /= n;
                }
            }

            if (c.neutral_only) {
                /* Session re-zero: everything else came from NVS. */
                c.complete = true;
                c.phase    = CALIB_DONE;
                ESP_LOGI(TAG, "neutral pose recaptured");
                break;
            }

            fusion_set_calibration(&c.rec);
            fusion_rom_sweep_begin();
            enter_phase(CALIB_ROM_SWEEP, t_us, pr);
        }
        break;
    }

    case CALIB_ROM_SWEEP: {
        pr->message = "Slowly curl all the way up and back down, twice";
        /* No fixed duration: the patient sets the pace. Allow generous time
         * and end on a timeout rather than rushing them. */
        const uint32_t budget_ms = 20000;
        pr->percent = (uint8_t)((elapsed_ms * 100) / budget_ms);

        if (elapsed_ms >= budget_ms) {
            float axis[3], amin, amax;
            if (fusion_rom_sweep_end(axis, &amin, &amax) != ESP_OK) {
                c.phase = CALIB_FAILED;
                pr->message = "Not enough movement to measure your range";
                ESP_LOGE(TAG, "ROM sweep failed");
                break;
            }
            memcpy(c.rec.flexion_axis, axis, sizeof(axis));
            c.rec.angle_min = amin;
            c.rec.angle_max = amax;
            c.rec.version   = CALIB_RECORD_VERSION;

            c.complete  = true;
            c.phase     = CALIB_DONE;
            pr->message = "Calibration complete";
            ESP_LOGI(TAG, "calibration done: ROM %.1f-%.1f deg",
                     c.rec.angle_min, c.rec.angle_max);
        }
        break;
    }

    default:
        break;
    }

    pr->phase = c.phase;
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
    ESP_LOGI(TAG, "loaded profile: ROM %.1f-%.1f deg",
             out->angle_min, out->angle_max);
    return ESP_OK;
}

esp_err_t calibration_save_nvs(const calib_record_t *rec)
{
    nvs_handle_t h;
    ESP_RETURN_ON_ERROR(nvs_open(NVS_NAMESPACE, NVS_READWRITE, &h),
                        TAG, "nvs open");
    esp_err_t err = nvs_set_blob(h, NVS_KEY_CALIB, rec, sizeof(*rec));
    if (err == ESP_OK) {
        err = nvs_commit(h);
    }
    nvs_close(h);
    return err;
}

bool calibration_is_stale(const calib_record_t *rec, uint32_t now_epoch_s)
{
    if (rec->timestamp == 0 || now_epoch_s == 0) {
        return true;   /* unknown age: treat as stale rather than trusting it */
    }
    const uint32_t age_days = (now_epoch_s - rec->timestamp) / 86400;
    return age_days > CALIB_PROFILE_STALE_DAYS;
}

/* ──────────────────────────────────────────────────────────────────────
 * Donning check
 *
 * None of this needs a classifier. Correct donning is directly observable:
 * gravity is where it should be, both channels show life, and during a test
 * curl the biceps must exceed the triceps while the forearm rotates and the
 * upper arm stays comparatively still.
 * ────────────────────────────────────────────────────────────────────── */

static struct {
    uint64_t start_us;
    float    bicep_sum, tricep_sum;
    float    fore_motion, upper_motion;
    uint32_t n;
    bool     running;
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
    }

    const uint64_t elapsed_ms = (t_us - d.start_us) / 1000;
    *message = "Curl your arm once, then relax";

    d.bicep_sum   += emg->envelope[0];
    d.tricep_sum  += emg->envelope[1];
    d.fore_motion += fabsf(motion->elbow_velocity_dps);
    d.upper_motion += motion->upper_arm_rate_dps;
    d.n++;

    if (elapsed_ms < 4000) {
        return DON_PENDING;
    }

    d.running = false;

    if (d.n == 0) {
        *message = "No sensor data";
        return DON_IMU_DEAD;
    }

    const float bicep  = d.bicep_sum  / d.n;
    const float tricep = d.tricep_sum / d.n;

    if (bicep < 1e-4f && tricep < 1e-4f) {
        *message = "Neither EMG channel is reading — check electrode contact "
                   "and that both MyoWare sensors have power";
        return DON_EMG_DEAD;
    }

    if (d.fore_motion / d.n < 2.0f) {
        *message = "No elbow movement detected — the forearm sensor may not "
                   "be reading";
        return DON_IMU_DEAD;
    }

    /* The orientation test. If the triceps channel dominated during a curl,
     * the sleeve is on backwards or the leads are crossed. Saying which is
     * more useful than a generic failure. */
    if (tricep > bicep * 1.3f) {
        *message = "The sleeve appears to be on backwards, or the biceps and "
                   "triceps leads are swapped";
        return DON_CHANNELS_SWAPPED;
    }

    *message = "Sleeve is on correctly";
    return DON_PASS;
}
