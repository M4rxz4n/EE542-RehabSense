/*
 * config.c — runtime configuration over BLE [PRD §5.9.1]
 */

#include <string.h>
#include <math.h>
#include "nvs_flash.h"
#include "nvs.h"
#include "esp_log.h"

#include "config.h"
#include "rep_cycle.h"
#include "grading.h"
#include "rehab_config.h"

static const char *TAG = "cfg";

static rehab_runtime_cfg_t s_cfg;

/* ── helpers ─────────────────────────────────────────────────────────── */

static float clampf(float v, float lo, float hi)
{
    if (!(v == v)) return lo;          /* NaN from a malformed float */
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

static uint16_t clampu16(uint32_t v, uint16_t lo, uint16_t hi)
{
    if (v < lo) return lo;
    if (v > hi) return hi;
    return (uint16_t)v;
}

static float rd_f32(const uint8_t *p)
{
    float f;
    memcpy(&f, p, sizeof(f));          /* little-endian on both ends */
    return f;
}

static uint16_t rd_u16(const uint8_t *p)
{
    return (uint16_t)(p[0] | ((uint16_t)p[1] << 8));
}

static void wr_f32(uint8_t *p, float v) { memcpy(p, &v, sizeof(v)); }
static void wr_u16(uint8_t *p, uint16_t v) { p[0] = v & 0xFF; p[1] = v >> 8; }

/* ── validation ──────────────────────────────────────────────────────── */

/* Every value a host can set is clamped to a range the device can actually
 * honour. A configuration that cannot produce a countable repetition is worse
 * than a rejected write, because the failure shows up as a device that has
 * stopped counting rather than as an error. */
static void validate(rehab_runtime_cfg_t *c)
{
    c->hold_duration_ms = clampu16(c->hold_duration_ms,
                                   REP_HOLD_MS_MIN, REP_HOLD_MS_MAX);
    c->hold_velocity_thresh = clampf(c->hold_velocity_thresh, 1.0f, 90.0f);

    c->rep_target   = (uint8_t)clampu16(c->rep_target,
                                        REP_TARGET_MIN, REP_TARGET_MAX);
    c->set_count    = (uint8_t)clampu16(c->set_count, 1, 20);
    c->rest_seconds = clampu16(c->rest_seconds, 0, 600);

    c->target_angle_deg = clampf(c->target_angle_deg, 20.0f, 160.0f);
    c->start_angle_deg  = clampf(c->start_angle_deg,  0.0f, 90.0f);
    c->finish_angle_deg = clampf(c->finish_angle_deg, 0.0f, 90.0f);

    /* The finish threshold must sit below the start threshold or the cycle
     * has no hysteresis and will chatter between READY and CONCENTRIC. */
    if (c->finish_angle_deg >= c->start_angle_deg) {
        c->finish_angle_deg = c->start_angle_deg - 5.0f;
        if (c->finish_angle_deg < 0.0f) {
            c->finish_angle_deg = 0.0f;
            c->start_angle_deg  = 5.0f;
        }
    }

    /* The peak criterion must be reachable from the start threshold. */
    if (c->target_angle_deg * REP_PEAK_FRAC <= c->start_angle_deg) {
        c->target_angle_deg = (c->start_angle_deg + 10.0f) / REP_PEAK_FRAC;
    }

    c->tempo_min_s = clampf(c->tempo_min_s, 0.2f, 30.0f);
    c->tempo_max_s = clampf(c->tempo_max_s, 0.3f, 60.0f);
    if (c->tempo_max_s <= c->tempo_min_s) {
        c->tempo_max_s = c->tempo_min_s + 0.5f;
    }

    c->comp_shoulder_deg = clampf(c->comp_shoulder_deg, 2.0f, 90.0f);
    c->comp_trunk_deg    = clampf(c->comp_trunk_deg,    2.0f, 90.0f);
    c->comp_swing_dps    = clampf(c->comp_swing_dps,    5.0f, 500.0f);

    c->w_range         = clampf(c->w_range,         0.0f, 1.0f);
    c->w_tempo         = clampf(c->w_tempo,         0.0f, 1.0f);
    c->w_smoothness    = clampf(c->w_smoothness,    0.0f, 1.0f);
    c->w_cocontraction = clampf(c->w_cocontraction, 0.0f, 1.0f);
    c->w_hold_steady   = clampf(c->w_hold_steady,   0.0f, 1.0f);

    /* All-zero weights would make every repetition score zero regardless of
     * performance. Fall back rather than report nonsense. */
    const float wsum = c->w_range + c->w_tempo + c->w_smoothness +
                       c->w_cocontraction + c->w_hold_steady;
    if (wsum < 1e-6f) {
        ESP_LOGW(TAG, "all grading weights zero — restoring defaults");
        c->w_range         = GRADE_W_RANGE;
        c->w_tempo         = GRADE_W_TEMPO;
        c->w_smoothness    = GRADE_W_SMOOTHNESS;
        c->w_cocontraction = GRADE_W_COCONTRACTION;
        c->w_hold_steady   = GRADE_W_HOLD_STEADY;
    }

    c->p_shoulder = clampf(c->p_shoulder, 0.0f, 100.0f);
    c->p_trunk    = clampf(c->p_trunk,    0.0f, 100.0f);
    c->p_swing    = clampf(c->p_swing,    0.0f, 100.0f);

    c->raw_stream_enable = c->raw_stream_enable ? 1 : 0;
    if (c->agonist_channel >= EMG_N_CHANNELS) {
        c->agonist_channel = 0;
    }
}

/* ── NVS ─────────────────────────────────────────────────────────────── */

static void save_nvs(void)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NAMESPACE, NVS_READWRITE, &h) != ESP_OK) {
        ESP_LOGW(TAG, "nvs open failed; config not persisted");
        return;
    }
    if (nvs_set_blob(h, NVS_KEY_CONFIG, &s_cfg, sizeof(s_cfg)) == ESP_OK) {
        nvs_commit(h);
    }
    nvs_close(h);
}

static bool load_nvs(void)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NAMESPACE, NVS_READONLY, &h) != ESP_OK) {
        return false;
    }
    size_t len = sizeof(s_cfg);
    const esp_err_t err = nvs_get_blob(h, NVS_KEY_CONFIG, &s_cfg, &len);
    nvs_close(h);

    if (err != ESP_OK || len != sizeof(s_cfg)) {
        return false;
    }
    validate(&s_cfg);   /* a struct layout change must not resurrect junk */
    return true;
}

/* ── API ─────────────────────────────────────────────────────────────── */

void config_publish(void)
{
    grading_set_config(&s_cfg);
    rep_cycle_set_config(&s_cfg);
}

void config_init(void)
{
    if (!load_nvs()) {
        rehab_cfg_defaults(&s_cfg);
        ESP_LOGI(TAG, "no stored config; using defaults");
    } else {
        ESP_LOGI(TAG, "config loaded: hold %u ms, target %u reps, angle %.0f deg",
                 s_cfg.hold_duration_ms, s_cfg.rep_target,
                 s_cfg.target_angle_deg);
    }
    config_publish();
}

const rehab_runtime_cfg_t *config_get(void) { return &s_cfg; }

void config_reset_defaults(void)
{
    rehab_cfg_defaults(&s_cfg);
    save_nvs();
    config_publish();
}

esp_err_t config_apply_tlv(const uint8_t *tlv, size_t len)
{
    if (!tlv) {
        return ESP_ERR_INVALID_ARG;
    }

    rehab_runtime_cfg_t next = s_cfg;
    size_t i = 0;
    unsigned applied = 0, skipped = 0;

    while (i + 2 <= len) {
        const uint8_t tag = tlv[i];
        const uint8_t vl  = tlv[i + 1];
        const uint8_t *v  = &tlv[i + 2];

        if (i + 2 + vl > len) {
            ESP_LOGW(TAG, "truncated TLV at tag 0x%02X", tag);
            return ESP_ERR_INVALID_SIZE;
        }

        /* A recognised tag with the wrong length means the two sides disagree
         * about what it means. Guessing would write a plausible wrong value
         * into a live session. */
        #define NEED(n) do {                                            \
            if (vl != (n)) {                                            \
                ESP_LOGW(TAG, "tag 0x%02X: expected %d bytes, got %u",  \
                         tag, (n), vl);                                 \
                return ESP_ERR_INVALID_SIZE;                            \
            }                                                           \
        } while (0)

        switch (tag) {
        case CFG_TAG_HOLD_MS:
            NEED(2); next.hold_duration_ms = rd_u16(v); applied++; break;
        case CFG_TAG_HOLD_VEL:
            NEED(4); next.hold_velocity_thresh = rd_f32(v); applied++; break;
        case CFG_TAG_REP_TARGET:
            NEED(1); next.rep_target = v[0]; applied++; break;
        case CFG_TAG_SET_COUNT:
            NEED(1); next.set_count = v[0]; applied++; break;
        case CFG_TAG_REST_SECONDS:
            NEED(2); next.rest_seconds = rd_u16(v); applied++; break;
        case CFG_TAG_TARGET_ANGLE:
            NEED(4); next.target_angle_deg = rd_f32(v); applied++; break;
        case CFG_TAG_START_ANGLE:
            NEED(4); next.start_angle_deg = rd_f32(v); applied++; break;
        case CFG_TAG_FINISH_ANGLE:
            NEED(4); next.finish_angle_deg = rd_f32(v); applied++; break;
        case CFG_TAG_TEMPO:
            NEED(8);
            next.tempo_min_s = rd_f32(v);
            next.tempo_max_s = rd_f32(v + 4);
            applied++; break;
        case CFG_TAG_COMP_THRESH:
            NEED(12);
            next.comp_shoulder_deg = rd_f32(v);
            next.comp_trunk_deg    = rd_f32(v + 4);
            next.comp_swing_dps    = rd_f32(v + 8);
            applied++; break;
        case CFG_TAG_WEIGHTS:
            NEED(20);
            next.w_range         = rd_f32(v);
            next.w_tempo         = rd_f32(v + 4);
            next.w_smoothness    = rd_f32(v + 8);
            next.w_cocontraction = rd_f32(v + 12);
            next.w_hold_steady   = rd_f32(v + 16);
            applied++; break;
        case CFG_TAG_DEDUCTIONS:
            NEED(12);
            next.p_shoulder = rd_f32(v);
            next.p_trunk    = rd_f32(v + 4);
            next.p_swing    = rd_f32(v + 8);
            applied++; break;
        case CFG_TAG_RAW_STREAM:
            NEED(1); next.raw_stream_enable = v[0]; applied++; break;
        case CFG_TAG_CHANNEL_ROLES:
            NEED(2); next.agonist_channel = v[1]; applied++; break;
        default:
            /* Forward compatibility: a newer host may send tags this build
             * has never heard of. Skipping lets the rest of the block land. */
            skipped++;
            break;
        }
        #undef NEED

        i += 2u + vl;
    }

    validate(&next);
    s_cfg = next;
    save_nvs();
    config_publish();

    ESP_LOGI(TAG, "config: %u applied, %u unknown tags skipped", applied, skipped);
    return ESP_OK;
}

size_t config_serialise(uint8_t *out, size_t max)
{
    size_t n = 0;

    #define PUT(tag, len)                         \
        if (n + 2 + (len) > max) return n;        \
        out[n++] = (tag); out[n++] = (len);

    PUT(CFG_TAG_HOLD_MS, 2);      wr_u16(&out[n], s_cfg.hold_duration_ms); n += 2;
    PUT(CFG_TAG_HOLD_VEL, 4);     wr_f32(&out[n], s_cfg.hold_velocity_thresh); n += 4;
    PUT(CFG_TAG_REP_TARGET, 1);   out[n++] = s_cfg.rep_target;
    PUT(CFG_TAG_SET_COUNT, 1);    out[n++] = s_cfg.set_count;
    PUT(CFG_TAG_REST_SECONDS, 2); wr_u16(&out[n], s_cfg.rest_seconds); n += 2;
    PUT(CFG_TAG_TARGET_ANGLE, 4); wr_f32(&out[n], s_cfg.target_angle_deg); n += 4;
    PUT(CFG_TAG_START_ANGLE, 4);  wr_f32(&out[n], s_cfg.start_angle_deg); n += 4;
    PUT(CFG_TAG_FINISH_ANGLE, 4); wr_f32(&out[n], s_cfg.finish_angle_deg); n += 4;

    PUT(CFG_TAG_TEMPO, 8);
    wr_f32(&out[n], s_cfg.tempo_min_s); n += 4;
    wr_f32(&out[n], s_cfg.tempo_max_s); n += 4;

    PUT(CFG_TAG_COMP_THRESH, 12);
    wr_f32(&out[n], s_cfg.comp_shoulder_deg); n += 4;
    wr_f32(&out[n], s_cfg.comp_trunk_deg);    n += 4;
    wr_f32(&out[n], s_cfg.comp_swing_dps);    n += 4;

    PUT(CFG_TAG_WEIGHTS, 20);
    wr_f32(&out[n], s_cfg.w_range);         n += 4;
    wr_f32(&out[n], s_cfg.w_tempo);         n += 4;
    wr_f32(&out[n], s_cfg.w_smoothness);    n += 4;
    wr_f32(&out[n], s_cfg.w_cocontraction); n += 4;
    wr_f32(&out[n], s_cfg.w_hold_steady);   n += 4;

    PUT(CFG_TAG_DEDUCTIONS, 12);
    wr_f32(&out[n], s_cfg.p_shoulder); n += 4;
    wr_f32(&out[n], s_cfg.p_trunk);    n += 4;
    wr_f32(&out[n], s_cfg.p_swing);    n += 4;

    PUT(CFG_TAG_RAW_STREAM, 1);    out[n++] = s_cfg.raw_stream_enable;
    PUT(CFG_TAG_CHANNEL_ROLES, 2); out[n++] = 0; out[n++] = s_cfg.agonist_channel;

    #undef PUT
    return n;
}
