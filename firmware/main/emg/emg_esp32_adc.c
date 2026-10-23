/*
 * emg_esp32_adc.c — EMG acquisition on the ESP32-S3 internal ADC
 *
 * Continuous (DMA) mode, not one-shot. One-shot sampling from a timer callback
 * jitters, and jitter smears the power spectrum — which is precisely the
 * measurement median-frequency fatigue tracking depends on.
 *
 * ADC1 only. ADC2 shares hardware with the RF subsystem.
 *
 * Expect ~9.5 effective bits here: roughly 50 dB of usable dynamic range,
 * against the ADS131M02's 110 dB. Enough to prove the pipeline and collect
 * training data. Not enough for the final product.
 */

#include <string.h>
#include <math.h>
#include <inttypes.h>
#include "esp_check.h"
#include "esp_attr.h"
#include "esp_adc/adc_continuous.h"
#include "esp_adc/adc_cali.h"
#include "esp_adc/adc_cali_scheme.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/ringbuf.h"

#include "emg_driver.h"
#include "rehab_config.h"

static const char *TAG = "emg_adc";

/* The S3 emits TYPE2 conversion results: 4 bytes per sample carrying the
 * channel id alongside the 12-bit datum. */
#define ADC_OUTPUT_TYPE    ADC_DIGI_OUTPUT_FORMAT_TYPE2
#define ADC_BIT_WIDTH      SOC_ADC_DIGI_MAX_BITWIDTH
#define ADC_FULL_SCALE     ((1 << 12) - 1)

/* Mid-rail bias: the MyoWare RAW output swings about Vs/2. Subtracting this
 * is what makes the driver's output zero-centred and signed. Refined at
 * self-test time from the measured resting DC. */
#define ADC_NOMINAL_BIAS   (ADC_FULL_SCALE / 2)

/* Conversion frames arrive holding interleaved channels. Size the DMA buffer
 * for a few frames so a late DSP task cannot drop data. */
#define CONV_FRAME_BYTES   (EMG_DMA_FRAME_SAMPLES * EMG_N_CHANNELS * SOC_ADC_DIGI_RESULT_BYTES)
#define DMA_POOL_BYTES     (CONV_FRAME_BYTES * 4)

typedef struct {
    adc_continuous_handle_t handle;
    adc_cali_handle_t       cali[EMG_N_CHANNELS];
    QueueHandle_t           frame_q;      /* of emg_frame_t */
    int32_t                 bias[EMG_N_CHANNELS];
    volatile bool           running;
    volatile uint32_t       overruns;
    uint64_t                sample_index;
} adc_ctx_t;

static adc_ctx_t s_ctx;

/* Map a hardware channel id to our logical channel index. */
static inline int chan_index(uint8_t hw_chan)
{
    if (hw_chan == ADC_CHAN_EMG_A) return 0;
    if (hw_chan == ADC_CHAN_EMG_B) return 1;
    return -1;
}

/* ──────────────────────────────────────────────────────────────────────
 * Conversion-done callback.
 *
 * ISR context. Does the minimum: unpack, de-bias, timestamp, enqueue.
 * Everything else belongs in emg_dsp.
 * ────────────────────────────────────────────────────────────────────── */
static bool IRAM_ATTR conv_done_cb(adc_continuous_handle_t handle,
                                   const adc_continuous_evt_data_t *edata,
                                   void *user_data)
{
    adc_ctx_t *ctx = (adc_ctx_t *)user_data;
    BaseType_t hp_woken = pdFALSE;

    const adc_digi_output_data_t *p =
        (const adc_digi_output_data_t *)edata->conv_frame_buffer;
    const size_t n_results = edata->size / SOC_ADC_DIGI_RESULT_BYTES;

    /* Results arrive interleaved in the scan pattern order. Walk them in
     * pairs, emitting one emg_frame_t per complete set of channels. */
    emg_frame_t frame = { 0 };
    uint8_t     have_mask = 0;

    const uint64_t now_us = esp_timer_get_time();

    for (size_t i = 0; i < n_results; i++) {
        const int idx = chan_index(p[i].type2.channel);
        if (idx < 0) {
            continue;   /* not one of ours; ignore rather than mis-assign */
        }

        const int32_t raw = (int32_t)p[i].type2.data;

        if (raw <= (int32_t)(ADC_FULL_SCALE * EMG_CLIP_MARGIN) ||
            raw >= (int32_t)(ADC_FULL_SCALE * (1.0f - EMG_CLIP_MARGIN))) {
            frame.flags |= (idx == 0) ? EMG_FLAG_CLIP_A : EMG_FLAG_CLIP_B;
        }

        frame.ch[idx] = raw - ctx->bias[idx];
        have_mask |= (1u << idx);

        if (have_mask == ((1u << EMG_N_CHANNELS) - 1)) {
            /* The conversion frame covers a known span; derive each sample's
             * timestamp by walking backwards from now rather than stamping
             * every sample with the callback time. */
            const uint32_t samples_in_frame = n_results / EMG_N_CHANNELS;
            const uint32_t sample_in_frame  = (i + 1) / EMG_N_CHANNELS;
            const int64_t  us_per_sample    = 1000000 / EMG_SAMPLE_RATE_HZ;
            frame.t_us = now_us -
                (int64_t)(samples_in_frame - sample_in_frame) * us_per_sample;

            if (xQueueSendFromISR(ctx->frame_q, &frame, &hp_woken) != pdTRUE) {
                ctx->overruns++;
            }

            have_mask  = 0;
            frame.flags = 0;
        }
    }

    return hp_woken == pdTRUE;
}

/* ────────────────────────────────────────────────────────────────────── */

static esp_err_t adc_init(const emg_cfg_t *cfg)
{
    memset(&s_ctx, 0, sizeof(s_ctx));

    for (int i = 0; i < EMG_N_CHANNELS; i++) {
        s_ctx.bias[i] = ADC_NOMINAL_BIAS;
    }

    /* Queue holds a little over one DMA frame's worth of samples so the DSP
     * task can fall behind briefly without losing data. */
    s_ctx.frame_q = xQueueCreate(EMG_DMA_FRAME_SAMPLES * 2, sizeof(emg_frame_t));
    if (!s_ctx.frame_q) {
        return ESP_ERR_NO_MEM;
    }

    adc_continuous_handle_cfg_t handle_cfg = {
        .max_store_buf_size = DMA_POOL_BYTES,
        .conv_frame_size    = CONV_FRAME_BYTES,
    };
    ESP_RETURN_ON_ERROR(adc_continuous_new_handle(&handle_cfg, &s_ctx.handle),
                        TAG, "adc_continuous_new_handle failed");

    adc_digi_pattern_config_t pattern[EMG_N_CHANNELS] = {
        {
            .atten     = ADC_ATTEN_DB_12,   /* ~0-3.1 V, centred on the 1.65 V bias */
            .channel   = ADC_CHAN_EMG_A,
            .unit      = ADC_UNIT_1,
            .bit_width = ADC_BIT_WIDTH,
        },
        {
            .atten     = ADC_ATTEN_DB_12,
            .channel   = ADC_CHAN_EMG_B,
            .unit      = ADC_UNIT_1,
            .bit_width = ADC_BIT_WIDTH,
        },
    };

    adc_continuous_config_t dig_cfg = {
        .pattern_num    = EMG_N_CHANNELS,
        .adc_pattern    = pattern,
        .sample_freq_hz = cfg->sample_rate_hz * EMG_N_CHANNELS,
        .conv_mode      = ADC_CONV_SINGLE_UNIT_1,
        .format         = ADC_OUTPUT_TYPE,
    };
    ESP_RETURN_ON_ERROR(adc_continuous_config(s_ctx.handle, &dig_cfg),
                        TAG, "adc_continuous_config failed");

    adc_continuous_evt_cbs_t cbs = { .on_conv_done = conv_done_cb };
    ESP_RETURN_ON_ERROR(
        adc_continuous_register_event_callbacks(s_ctx.handle, &cbs, &s_ctx),
        TAG, "callback registration failed");

    /* Curve fitting corrects the S3's gain and offset error. Without it the
     * 20 Hz high-pass still removes the offset, but absolute %MVC scaling
     * drifts between boards. */
    for (int i = 0; i < EMG_N_CHANNELS; i++) {
        adc_cali_curve_fitting_config_t cali_cfg = {
            .unit_id  = ADC_UNIT_1,
            .chan     = (i == 0) ? ADC_CHAN_EMG_A : ADC_CHAN_EMG_B,
            .atten    = ADC_ATTEN_DB_12,
            .bitwidth = ADC_BIT_WIDTH,
        };
        if (adc_cali_create_scheme_curve_fitting(&cali_cfg, &s_ctx.cali[i]) != ESP_OK) {
            ESP_LOGW(TAG, "no calibration data for channel %d; using raw counts", i);
            s_ctx.cali[i] = NULL;
        }
    }

    ESP_LOGI(TAG, "initialised: %" PRIu32 " Hz x %d ch, %d-sample DMA frames",
             cfg->sample_rate_hz, EMG_N_CHANNELS, (int)cfg->dma_frame_samples);
    return ESP_OK;
}

static esp_err_t adc_start(void)
{
    xQueueReset(s_ctx.frame_q);
    s_ctx.overruns = 0;
    ESP_RETURN_ON_ERROR(adc_continuous_start(s_ctx.handle), TAG, "start failed");
    s_ctx.running = true;
    return ESP_OK;
}

static esp_err_t adc_stop(void)
{
    s_ctx.running = false;
    return adc_continuous_stop(s_ctx.handle);
}

static size_t adc_read(emg_frame_t *out, size_t max, TickType_t wait)
{
    size_t n = 0;
    while (n < max) {
        if (xQueueReceive(s_ctx.frame_q, &out[n], (n == 0) ? wait : 0) != pdTRUE) {
            break;
        }
        n++;
    }
    if (n > 0 && s_ctx.overruns > 0) {
        out[0].flags |= EMG_FLAG_OVERRUN;
        s_ctx.overruns = 0;
    }
    return n;
}

static esp_err_t adc_self_test(emg_selftest_t *result)
{
    memset(result, 0, sizeof(*result));

    const bool was_running = s_ctx.running;
    if (!was_running) {
        ESP_RETURN_ON_ERROR(adc_start(), TAG, "self-test could not start ADC");
    }

    /* Half a second at rest is enough to characterise the noise floor and
     * find the true bias point. */
    const uint32_t want = EMG_SAMPLE_RATE_HZ / 2;
    int64_t  sum[EMG_N_CHANNELS]    = { 0 };
    int64_t  sum_sq[EMG_N_CHANNELS] = { 0 };
    uint32_t seen = 0;

    emg_frame_t f;
    const TickType_t deadline = xTaskGetTickCount() + pdMS_TO_TICKS(2000);

    while (seen < want && xTaskGetTickCount() < deadline) {
        if (xQueueReceive(s_ctx.frame_q, &f, pdMS_TO_TICKS(100)) != pdTRUE) {
            continue;
        }
        for (int i = 0; i < EMG_N_CHANNELS; i++) {
            const int32_t v = f.ch[i] + s_ctx.bias[i];   /* back to raw counts */
            sum[i]    += v;
            sum_sq[i] += (int64_t)v * v;
        }
        seen++;
    }

    if (!was_running) {
        adc_stop();
    }

    result->samples_seen = seen;

    if (seen < want / 2) {
        result->ok     = false;
        result->detail = "ADC produced too few samples — check DMA configuration";
        return ESP_FAIL;
    }

    for (int i = 0; i < EMG_N_CHANNELS; i++) {
        const double mean = (double)sum[i] / seen;
        const double var  = (double)sum_sq[i] / seen - mean * mean;

        result->dc_offset[i] = (int32_t)mean;
        result->noise_rms[i] = (float)(var > 0 ? sqrt(var) : 0.0);

        /* Adopt the measured bias. A MyoWare at 3.3 V should sit near mid-rail;
         * far from it means the sensor is unpowered or the lead is off. */
        s_ctx.bias[i] = (int32_t)mean;

        const double deviation = fabs(mean - ADC_NOMINAL_BIAS) / ADC_FULL_SCALE;
        if (deviation > 0.25) {
            result->ok     = false;
            result->detail = "EMG channel is not biased near mid-rail — "
                             "check MyoWare power and electrode leads";
            return ESP_FAIL;
        }

        /* A perfectly flat channel means nothing is connected. Real electrodes
         * always show some noise. */
        if (result->noise_rms[i] < 0.5f) {
            result->ok     = false;
            result->detail = "EMG channel is flat — sensor probably disconnected";
            return ESP_FAIL;
        }
    }

    result->ok = true;
    ESP_LOGI(TAG, "self-test ok: bias %" PRId32 "/%" PRId32 " counts, "
                  "noise %.2f/%.2f LSB RMS",
             s_ctx.bias[0], s_ctx.bias[1],
             result->noise_rms[0], result->noise_rms[1]);
    return ESP_OK;
}

static int32_t adc_full_scale(void)
{
    return ADC_FULL_SCALE / 2;   /* signed swing about the bias point */
}

const emg_driver_t emg_driver_esp32_adc = {
    .name       = "esp32s3-adc1",
    .init       = adc_init,
    .start      = adc_start,
    .stop       = adc_stop,
    .read       = adc_read,
    .self_test  = adc_self_test,
    .full_scale = adc_full_scale,
};
