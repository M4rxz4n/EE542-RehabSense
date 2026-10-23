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

typedef struct {
    int16_t ch[EMG_N_CHANNELS];
} packed_emg_t;

typedef struct {
    int16_t accel[2][3];
    int16_t gyro[2][3];
} packed_imu_t;

static packed_emg_t *s_emg;
static packed_imu_t *s_imu;
static size_t        s_emg_cap;
static size_t        s_imu_cap;

static uint32_t s_emg_seq;      /* next sequence to assign */
static uint32_t s_imu_seq;
static uint32_t s_acked;
static uint64_t s_set_start_us;
static bool     s_gap;
static bool     s_psram;
static bool     s_active;

esp_err_t session_buffer_init(void)
{
    s_emg_cap = TIER2_EMG_SAMPLES;
    s_imu_cap = TIER2_IMU_SAMPLES;

    s_emg = heap_caps_malloc(s_emg_cap * sizeof(packed_emg_t), MALLOC_CAP_SPIRAM);
    s_imu = heap_caps_malloc(s_imu_cap * sizeof(packed_imu_t), MALLOC_CAP_SPIRAM);

    if (s_emg && s_imu) {
        s_psram = true;
        ESP_LOGI(TAG, "tier 2 in PSRAM: %u s of EMG (%u kB) + IMU (%u kB)",
                 (unsigned)TIER2_SECONDS,
                 (unsigned)(s_emg_cap * sizeof(packed_emg_t) / 1024),
                 (unsigned)(s_imu_cap * sizeof(packed_imu_t) / 1024));
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
    s_emg_cap = TIER1_EMG_SAMPLES;
    s_imu_cap = TIER1_IMU_SAMPLES;
    s_emg = calloc(s_emg_cap, sizeof(packed_emg_t));
    s_imu = calloc(s_imu_cap, sizeof(packed_imu_t));
    s_psram = false;

    if (!s_emg || !s_imu) {
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
    s_acked        = 0;
    s_gap          = false;
    s_set_start_us = esp_timer_get_time();
    s_active       = true;
    ESP_LOGI(TAG, "set buffer reset");
}

void session_buffer_end(void)
{
    s_active = false;
    ESP_LOGI(TAG, "set sealed at seq %" PRIu32, s_emg_seq);
}

uint32_t session_buffer_push_emg(const emg_frame_t *frames, size_t n)
{
    if (!s_active || !s_emg) {
        return s_emg_seq;
    }

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
    return s_emg_seq;
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
