/*
 * session_buffer.c — tiered buffer
 *
 * Samples are stored packed (int16 per channel) rather than as emg_frame_t:
 * the struct carries a 64-bit timestamp per sample, which at 2 kSPS would
 * triple the memory for information that is entirely derivable from the
 * sequence number and the set's start time.
 */

#include <string.h>
#include <stdlib.h>
#include <inttypes.h>
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_timer.h"

#include "session_buffer.h"
#include "rehab_config.h"
#include "ble_service.h"

static const char *TAG = "sessbuf";

/* The packed record layouts live in session_format.h, because the host parses
 * exactly these bytes off the wire. Keeping one definition means the download
 * format cannot drift from what is in memory. */
typedef rec_emg_t     packed_emg_t;
typedef rec_imu_t     packed_imu_t;

static packed_emg_t   *s_emg;
static packed_imu_t   *s_imu;
static rec_feature_t  *s_feat;
static rec_event_t    *s_evt;
static rec_rep_t      *s_rep;

static size_t s_emg_cap;
static size_t s_imu_cap;
static size_t s_feat_cap;
static size_t s_evt_cap;
static size_t s_rep_cap;

static uint32_t s_emg_seq;      /* next sequence to assign */
static uint32_t s_imu_seq;
static uint32_t s_feat_seq;
static uint32_t s_evt_seq;
static uint32_t s_rep_seq;
static uint32_t s_acked;
static uint64_t s_set_start_us;
static uint64_t s_set_end_us;
static bool     s_gap;
static bool     s_psram;
static bool     s_active;

/* Milliseconds since the session began. Every derived record is timestamped
 * this way: it keeps the field in 32 bits and makes a downloaded file
 * independent of when the device happened to boot. */
static inline uint32_t rel_ms(uint64_t t_us)
{
    return (t_us > s_set_start_us)
         ? (uint32_t)((t_us - s_set_start_us) / 1000ULL) : 0u;
}

/* Saturating float-to-int16 with a scale factor. Clamping rather than
 * wrapping matters: a quantity that overruns its range should read as
 * "at the limit", not as a large negative number. */
static inline int16_t q16(float v, float scale)
{
    const float s = v * scale;
    if (s >  32767.0f) return  32767;
    if (s < -32768.0f) return -32768;
    return (int16_t)s;
}

esp_err_t session_buffer_init(void)
{
    s_emg_cap  = TIER2_EMG_SAMPLES;
    s_imu_cap  = TIER2_IMU_SAMPLES;
    s_feat_cap = TIER2_FEATURE_SAMPLES;
    s_evt_cap  = TIER2_EVENT_RECORDS;
    s_rep_cap  = TIER2_REP_RECORDS;

    s_emg  = heap_caps_malloc(s_emg_cap  * sizeof(packed_emg_t),  MALLOC_CAP_SPIRAM);
    s_imu  = heap_caps_malloc(s_imu_cap  * sizeof(packed_imu_t),  MALLOC_CAP_SPIRAM);
    s_feat = heap_caps_malloc(s_feat_cap * sizeof(rec_feature_t), MALLOC_CAP_SPIRAM);
    s_evt  = heap_caps_malloc(s_evt_cap  * sizeof(rec_event_t),   MALLOC_CAP_SPIRAM);
    s_rep  = heap_caps_malloc(s_rep_cap  * sizeof(rec_rep_t),     MALLOC_CAP_SPIRAM);

    if (s_emg && s_imu && s_feat && s_evt && s_rep) {
        s_psram = true;
        const size_t total = s_emg_cap  * sizeof(packed_emg_t)
                           + s_imu_cap  * sizeof(packed_imu_t)
                           + s_feat_cap * sizeof(rec_feature_t)
                           + s_evt_cap  * sizeof(rec_event_t)
                           + s_rep_cap  * sizeof(rec_rep_t);
        ESP_LOGI(TAG, "tier 2 in PSRAM: %u s, %u kB total "
                      "(EMG %u + IMU %u + features %u + events/reps %u)",
                 (unsigned)TIER2_SECONDS, (unsigned)(total / 1024),
                 (unsigned)(s_emg_cap  * sizeof(packed_emg_t)  / 1024),
                 (unsigned)(s_imu_cap  * sizeof(packed_imu_t)  / 1024),
                 (unsigned)(s_feat_cap * sizeof(rec_feature_t) / 1024),
                 (unsigned)((s_evt_cap * sizeof(rec_event_t)
                           + s_rep_cap * sizeof(rec_rep_t)) / 1024));
        ESP_LOGI(TAG, "PSRAM free after tier 2: %u kB",
                 (unsigned)(heap_caps_get_free_size(MALLOC_CAP_SPIRAM) / 1024));
        return ESP_OK;
    }

    /* ── Degraded path ────────────────────────────────────────────────
     * No PSRAM. Almost always CONFIG_SPIRAM_MODE_OCT left unset rather than
     * absent hardware — an N8R8 module in quad mode reports zero PSRAM.
     *
     * Fall back to tier 1 only: raw EMG is no longer persisted through a
     * dropout, but the envelope, IMU stream and event log still are, so rep
     * counts, scores and fatigue trends survive intact. The gap is marked so
     * offline analysis cannot mistake it for clean data. */
    free(s_emg);
    free(s_imu);
    free(s_feat);
    free(s_evt);
    free(s_rep);

    s_emg_cap  = TIER1_EMG_SAMPLES;
    s_imu_cap  = TIER1_IMU_SAMPLES;
    s_feat_cap = TIER1_FEATURE_SAMPLES;
    /* The event and repetition logs are kept at full size even here. Together
     * they are under 40 kB, and they are the records a therapist actually
     * reads — losing the raw waveform to a misconfigured module is tolerable,
     * losing the rep scores is not. */
    s_evt_cap  = TIER2_EVENT_RECORDS;
    s_rep_cap  = TIER2_REP_RECORDS;

    s_emg  = calloc(s_emg_cap,  sizeof(packed_emg_t));
    s_imu  = calloc(s_imu_cap,  sizeof(packed_imu_t));
    s_feat = calloc(s_feat_cap, sizeof(rec_feature_t));
    s_evt  = calloc(s_evt_cap,  sizeof(rec_event_t));
    s_rep  = calloc(s_rep_cap,  sizeof(rec_rep_t));
    s_psram = false;

    if (!s_emg || !s_imu || !s_feat || !s_evt || !s_rep) {
        ESP_LOGE(TAG, "no memory for even tier 1");
        return ESP_ERR_NO_MEM;
    }

    ESP_LOGW(TAG, "PSRAM unavailable — tier 2 disabled, holding only %u s. "
                  "Check CONFIG_SPIRAM_MODE_OCT is set for the N8R8 module.",
             (unsigned)TIER1_SECONDS);
    return ESP_OK;
}

void session_buffer_begin(void)
{
    s_emg_seq      = 0;
    s_imu_seq      = 0;
    s_feat_seq     = 0;
    s_evt_seq      = 0;
    s_rep_seq      = 0;
    s_acked        = 0;
    s_gap          = false;
    s_set_start_us = esp_timer_get_time();
    s_set_end_us   = 0;
    s_active       = true;
    ESP_LOGI(TAG, "set buffer reset");
}

void session_buffer_end(void)
{
    if (!s_active) {
        return;             /* already sealed; don't move the end timestamp */
    }
    s_active     = false;
    s_set_end_us = esp_timer_get_time();
    ESP_LOGI(TAG, "set sealed: %" PRIu32 " EMG, %" PRIu32 " IMU, "
                  "%" PRIu32 " features, %" PRIu32 " events, %" PRIu32 " reps",
             s_emg_seq, s_imu_seq, s_feat_seq, s_evt_seq, s_rep_seq);
}

uint32_t session_buffer_push_emg(const emg_frame_t *frames, size_t n)
{
    if (!s_active || !s_emg) {
        return s_emg_seq;
    }

    /* The index of the first sample in this batch, which is what the caller
     * labels its BLE frame with. Returning the post-increment value here is
     * what made the stream's sequence numbers and the ring's disagree. */
    const uint32_t first = s_emg_seq;

    for (size_t i = 0; i < n; i++) {
        const size_t slot = s_emg_seq % s_emg_cap;

        /* Overwriting data the host has not acknowledged is real loss, so
         * record it rather than letting it pass unnoticed. */
        if (s_emg_seq >= s_emg_cap &&
            (s_emg_seq - s_emg_cap) >= s_acked && s_acked > 0) {
            s_gap = true;
        }

        for (int c = 0; c < EMG_N_CHANNELS; c++) {
            int32_t v = frames[i].ch[c];
            if (v >  32767) v =  32767;
            if (v < -32768) v = -32768;
            s_emg[slot].ch[c] = (int16_t)v;
        }
        s_emg_seq++;
    }
    return first;
}

uint32_t session_buffer_push_imu(const imu_sample_t *upper,
                                 const imu_sample_t *fore)
{
    if (!s_active || !s_imu) {
        return s_imu_seq;
    }

    const size_t slot = s_imu_seq % s_imu_cap;
    const imu_sample_t *src[2] = { upper, fore };

    for (int d = 0; d < 2; d++) {
        for (int a = 0; a < 3; a++) {
            /* Fixed point: accel in 1/1000 g, gyro in 1/10 deg/s. Both fit
             * int16 across the configured ranges with margin. */
            s_imu[slot].accel[d][a] = (int16_t)(src[d]->accel[a] * 1000.0f);
            s_imu[slot].gyro[d][a]  = (int16_t)(src[d]->gyro[a]  * 10.0f);
        }
    }
    s_imu_seq++;
    return s_imu_seq;
}

/* ── Derived streams ─────────────────────────────────────────────────────
 *
 * These are the device's own conclusions, not the measurement. They are
 * recorded because the physician view must show what the firmware decided —
 * the same rep counts, scores and compensation flags the patient felt through
 * the haptics. Recomputing them on the host would produce a second opinion,
 * and the two disagreeing is a firmware bug to find, not a UI question.
 * ──────────────────────────────────────────────────────────────────────── */

void session_buffer_push_features(const features_t *f)
{
    if (!s_active || !s_feat) {
        return;
    }

    rec_feature_t *r = &s_feat[s_feat_seq % s_feat_cap];
    r->t_ms = rel_ms(f->t_us);
    for (int c = 0; c < EMG_N_CHANNELS; c++) {
        r->envelope[c] = q16(f->envelope[c], SCALE_ENVELOPE);
        r->mdf[c]      = q16(f->mdf[c],      SCALE_MDF);
    }
    r->elbow_angle   = q16(f->elbow_angle_deg,   SCALE_ANGLE);
    r->upper_arm_dev = q16(f->upper_arm_dev_deg, SCALE_ANGLE);
    r->rep_count     = f->rep_count;
    r->rep_state     = f->rep_state;
    r->comp_flags    = (uint8_t)f->comp_flags;
    r->sig_flags     = (uint8_t)f->sig_flags;
    r->activation_on = f->activation_on;

    if (s_feat_seq >= s_feat_cap) {
        s_gap = true;
    }
    s_feat_seq++;
}

void session_buffer_push_event(const rehab_event_t *evt)
{
    if (!s_active || !s_evt) {
        return;
    }

    rec_event_t *r = &s_evt[s_evt_seq % s_evt_cap];
    memset(r, 0, sizeof(*r));
    r->t_ms        = rel_ms(evt->t_us);
    r->id          = evt->id;
    r->payload_len = (evt->payload_len > sizeof(r->payload))
                   ? (uint8_t)sizeof(r->payload) : evt->payload_len;
    memcpy(r->payload, evt->payload, r->payload_len);

    if (s_evt_seq >= s_evt_cap) {
        s_gap = true;
    }
    s_evt_seq++;
}

void session_buffer_push_rep(const rep_result_t *rep)
{
    if (!s_active || !s_rep) {
        return;
    }

    rec_rep_t *r = &s_rep[s_rep_seq % s_rep_cap];
    r->t_start_ms      = rel_ms(rep->t_start_us);
    r->t_end_ms        = rel_ms(rep->t_end_us);
    r->index           = rep->index;
    r->peak_angle      = q16(rep->peak_angle_deg, SCALE_ANGLE);
    r->rom_fraction    = q16(rep->rom_fraction,   SCALE_FRACTION);
    r->tempo_ms        = q16(rep->tempo_s,        SCALE_SECONDS);
    r->activation      = q16(rep->activation,     SCALE_ENVELOPE);
    r->cocontraction   = q16(rep->cocontraction,  SCALE_FRACTION);
    r->smoothness      = q16(rep->smoothness,     SCALE_FRACTION);
    r->hold_steadiness = q16(rep->hold_steadiness, SCALE_FRACTION);
    r->comp_flags      = rep->comp_flags;
    r->velocity_peaks  = rep->velocity_peaks;
    r->score           = rep->score;

    if (s_rep_seq >= s_rep_cap) {
        s_gap = true;
        ESP_LOGW(TAG, "repetition log wrapped at %u records — a set this long "
                      "was not anticipated", (unsigned)s_rep_cap);
    }
    s_rep_seq++;
}

void session_buffer_ack(uint32_t seq)
{
    if (seq > s_acked && seq <= s_emg_seq) {
        s_acked = seq;
    }
}

size_t session_buffer_read_emg(uint32_t from_seq, emg_frame_t *out, size_t max)
{
    if (!s_emg || from_seq >= s_emg_seq) {
        return 0;
    }

    /* Anything older than one full wrap is gone. Serving a short range as if
     * it were complete would corrupt the host's reconstruction silently. */
    const uint32_t oldest = (s_emg_seq > s_emg_cap)
                          ? (uint32_t)(s_emg_seq - s_emg_cap) : 0;
    if (from_seq < oldest) {
        from_seq = oldest;
    }

    const uint64_t us_per_sample = 1000000ULL / EMG_SAMPLE_RATE_HZ;
    size_t n = 0;

    while (n < max && (from_seq + n) < s_emg_seq) {
        const size_t slot = (from_seq + n) % s_emg_cap;
        for (int c = 0; c < EMG_N_CHANNELS; c++) {
            out[n].ch[c] = s_emg[slot].ch[c];
        }
        out[n].t_us = s_set_start_us + (uint64_t)(from_seq + n) * us_per_sample;
        out[n].flags = 0;
        n++;
    }
    return n;
}

/* ── Bulk read for the Wi-Fi transfer ────────────────────────────────────
 *
 * One generic reader over all five rings. The alternative — five
 * near-identical handlers in the HTTP layer — is five places to get the wrap
 * arithmetic subtly wrong.
 * ──────────────────────────────────────────────────────────────────────── */

typedef struct {
    void   **base;
    size_t  *cap;
    uint32_t *written;
    size_t   rec_size;
} stream_desc_t;

static stream_desc_t stream_desc(session_stream_t s)
{
    switch (s) {
    case SESSION_STREAM_EMG:
        return (stream_desc_t){ (void **)&s_emg,  &s_emg_cap,  &s_emg_seq,
                                sizeof(packed_emg_t) };
    case SESSION_STREAM_IMU:
        return (stream_desc_t){ (void **)&s_imu,  &s_imu_cap,  &s_imu_seq,
                                sizeof(packed_imu_t) };
    case SESSION_STREAM_FEATURES:
        return (stream_desc_t){ (void **)&s_feat, &s_feat_cap, &s_feat_seq,
                                sizeof(rec_feature_t) };
    case SESSION_STREAM_EVENTS:
        return (stream_desc_t){ (void **)&s_evt,  &s_evt_cap,  &s_evt_seq,
                                sizeof(rec_event_t) };
    case SESSION_STREAM_REPS:
        return (stream_desc_t){ (void **)&s_rep,  &s_rep_cap,  &s_rep_seq,
                                sizeof(rec_rep_t) };
    default:
        return (stream_desc_t){ NULL, NULL, NULL, 0 };
    }
}

size_t session_stream_record_size(session_stream_t stream)
{
    return stream_desc(stream).rec_size;
}

size_t session_buffer_read_stream(session_stream_t stream,
                                  uint32_t from_record,
                                  void *out, size_t max_records)
{
    const stream_desc_t d = stream_desc(stream);
    if (!d.base || !*d.base || !out) {
        return 0;
    }

    const uint32_t written = *d.written;
    const size_t   cap     = *d.cap;

    if (from_record >= written) {
        return 0;                       /* nothing there yet */
    }

    /* Anything older than one full wrap is gone. The caller is told how many
     * records it actually got and the manifest's `first` says where the
     * retained range starts, so a short read is never mistaken for the end of
     * a complete stream. */
    const uint32_t oldest = (written > cap) ? (uint32_t)(written - cap) : 0;
    if (from_record < oldest) {
        from_record = oldest;
    }

    const uint8_t *base = (const uint8_t *)*d.base;
    uint8_t       *dst  = (uint8_t *)out;
    size_t         n    = 0;

    while (n < max_records && (from_record + n) < written) {
        const size_t slot = (from_record + n) % cap;
        memcpy(dst + n * d.rec_size, base + slot * d.rec_size, d.rec_size);
        n++;
    }
    return n;
}

void session_buffer_manifest(session_manifest_t *out)
{
    memset(out, 0, sizeof(*out));
    out->start_us     = s_set_start_us;
    out->end_us       = s_set_end_us;
    out->sealed       = !s_active;
    out->gap_occurred = s_gap;
    out->psram_backed = s_psram;

    for (int i = 0; i < SESSION_STREAM_COUNT; i++) {
        const stream_desc_t d = stream_desc((session_stream_t)i);
        if (!d.written) {
            continue;
        }
        const uint32_t written = *d.written;
        out->count[i] = written;
        out->first[i] = (written > *d.cap)
                      ? (uint32_t)(written - *d.cap) : 0;
    }
}

void session_buffer_stats(session_stats_t *out)
{
    memset(out, 0, sizeof(*out));
    out->seq_newest       = s_emg_seq;
    out->seq_oldest       = (s_emg_seq > s_emg_cap)
                          ? (uint32_t)(s_emg_seq - s_emg_cap) : 0;
    out->seq_acked        = s_acked;
    out->psram_backed     = s_psram;
    out->gap_occurred     = s_gap;
    out->capacity_samples = s_emg_cap;
}

/* ── Backfill [PRD §5.9] ─────────────────────────────────────────────── */

static uint32_t s_bf_next;      /* next sequence to send */
static uint32_t s_bf_end;       /* exclusive */
static bool     s_bf_active;

esp_err_t session_buffer_request_backfill(uint32_t from_seq, uint32_t to_seq)
{
    if (to_seq <= from_seq) {
        return ESP_ERR_INVALID_ARG;
    }
    if (!s_emg) {
        return ESP_ERR_INVALID_STATE;
    }

    const uint32_t oldest = (s_emg_seq > s_emg_cap)
                          ? (uint32_t)(s_emg_seq - s_emg_cap) : 0;

    if (from_seq >= s_emg_seq) {
        return ESP_ERR_NOT_FOUND;   /* entirely in the future */
    }

    if (from_seq < oldest) {
        /* Part of the range has aged out. Serve what remains and mark the
         * gap, so the host knows its reconstruction is incomplete rather than
         * trusting a short range [PRD §5.9]. */
        ESP_LOGW(TAG, "backfill %" PRIu32 "..%" PRIu32 " partly aged out; "
                      "serving from %" PRIu32, from_seq, to_seq, oldest);
        s_gap     = true;
        from_seq  = oldest;
    }

    s_bf_next   = from_seq;
    s_bf_end    = (to_seq > s_emg_seq) ? s_emg_seq : to_seq;
    s_bf_active = (s_bf_next < s_bf_end);

    ESP_LOGI(TAG, "backfill queued: %" PRIu32 "..%" PRIu32,
             s_bf_next, s_bf_end);
    return s_bf_active ? ESP_OK : ESP_ERR_NOT_FOUND;
}

bool session_buffer_backfill_pending(void) { return s_bf_active; }

bool session_buffer_service_backfill(void)
{
    if (!s_bf_active) {
        return false;
    }

    static emg_frame_t chunk[BLE_EMG_BATCH];
    const size_t want = (s_bf_end - s_bf_next > BLE_EMG_BATCH)
                      ? BLE_EMG_BATCH : (size_t)(s_bf_end - s_bf_next);

    const size_t got = session_buffer_read_emg(s_bf_next, chunk, want);
    if (got == 0) {
        s_bf_active = false;
        return false;
    }

    if (ble_notify_backfill(chunk, got, s_bf_next) != ESP_OK) {
        /* No subscriber, or the stack is busy. Leave the cursor where it is
         * and try again on the next pass rather than dropping the range. */
        return true;
    }

    s_bf_next += (uint32_t)got;
    if (s_bf_next >= s_bf_end) {
        s_bf_active = false;
        ESP_LOGI(TAG, "backfill complete to %" PRIu32, s_bf_next);
        return false;
    }
    return true;
}
