/*
 * emg_dsp.c — EMG signal chain
 *
 * Uses ESP-DSP (dsps_biquad_f32, dsps_fft2r_fc32), which is vector-optimised
 * for the S3. Coefficients are generated at init from the cutoffs in
 * rehab_config.h rather than pasted in, so changing a cutoff is a one-line
 * edit instead of a trip through a filter designer.
 *
 * A note on why this exists at all: the MyoWare's ENV output would give a
 * ready-made envelope for free, but it has already thrown away the frequency
 * spectrum. Median-frequency fatigue tracking needs that spectrum, so the
 * firmware takes RAW and does the work.
 */

#include <string.h>
#include <math.h>
#include "esp_log.h"
#include "esp_dsp.h"

#include "emg_dsp.h"
#include "rehab_config.h"

static const char *TAG = "emg_dsp";

#ifndef M_PI
#define M_PI 3.14159265358979323846f
#endif

#define N_BIQUADS 3   /* high-pass, low-pass, notch */

typedef struct {
    float coeffs[N_BIQUADS][5];   /* b0 b1 b2 a1 a2 */
    float state[N_BIQUADS][2];
} filter_chain_t;

typedef struct {
    filter_chain_t filt;

    /* Running sum of squares over the envelope window. */
    float    rms_window[EMG_RMS_WINDOW_SAMPLES];
    uint32_t rms_pos;
    float    rms_sum_sq;
    bool     rms_primed;

    /* FFT accumulation for median frequency. */
    float    fft_window[MDF_FFT_SIZE];
    uint32_t fft_pos;

    uint32_t clip_count;
    float    last_envelope_raw;   /* pre-normalisation, for calibration */
    float    last_mdf;
} chan_state_t;

static chan_state_t s_chan[EMG_N_CHANNELS];
static float        s_hann[MDF_FFT_SIZE];
static float        s_fft_buf[MDF_FFT_SIZE * 2];   /* interleaved re/im */
static uint32_t     s_decimate;
static int32_t      s_full_scale = 2048;
static bool         s_have_calib;
static calib_record_t s_calib;
static bool         s_fft_ready;

/* ──────────────────────────────────────────────────────────────────────
 * Biquad design — direct-form II transposed, normalised so a0 == 1.
 * Standard RBJ cookbook forms.
 * ────────────────────────────────────────────────────────────────────── */

static void design_highpass(float *c, float fs, float fc, float q)
{
    const float w0    = 2.0f * M_PI * fc / fs;
    const float cosw0 = cosf(w0);
    const float alpha = sinf(w0) / (2.0f * q);
    const float a0    = 1.0f + alpha;

    c[0] = ((1.0f + cosw0) / 2.0f) / a0;
    c[1] = (-(1.0f + cosw0)) / a0;
    c[2] = ((1.0f + cosw0) / 2.0f) / a0;
    c[3] = (-2.0f * cosw0) / a0;
    c[4] = (1.0f - alpha) / a0;
}

static void design_lowpass(float *c, float fs, float fc, float q)
{
    const float w0    = 2.0f * M_PI * fc / fs;
    const float cosw0 = cosf(w0);
    const float alpha = sinf(w0) / (2.0f * q);
    const float a0    = 1.0f + alpha;

    c[0] = ((1.0f - cosw0) / 2.0f) / a0;
    c[1] = (1.0f - cosw0) / a0;
    c[2] = ((1.0f - cosw0) / 2.0f) / a0;
    c[3] = (-2.0f * cosw0) / a0;
    c[4] = (1.0f - alpha) / a0;
}

static void design_notch(float *c, float fs, float fc, float q)
{
    const float w0    = 2.0f * M_PI * fc / fs;
    const float cosw0 = cosf(w0);
    const float alpha = sinf(w0) / (2.0f * q);
    const float a0    = 1.0f + alpha;

    c[0] = 1.0f / a0;
    c[1] = (-2.0f * cosw0) / a0;
    c[2] = 1.0f / a0;
    c[3] = (-2.0f * cosw0) / a0;
    c[4] = (1.0f - alpha) / a0;
}

/* ────────────────────────────────────────────────────────────────────── */

esp_err_t emg_dsp_init(int32_t full_scale)
{
    memset(s_chan, 0, sizeof(s_chan));
    s_full_scale = (full_scale > 0) ? full_scale : 2048;
    s_decimate   = EMG_SAMPLE_RATE_HZ / FEATURE_RATE_HZ;
    s_have_calib = false;

    const float fs = (float)EMG_SAMPLE_RATE_HZ;
    const float q_butterworth = 0.70710678f;   /* 2nd-order Butterworth */

    for (int ch = 0; ch < EMG_N_CHANNELS; ch++) {
        design_highpass(s_chan[ch].filt.coeffs[0], fs, EMG_HPF_HZ, q_butterworth);
        design_lowpass (s_chan[ch].filt.coeffs[1], fs, EMG_LPF_HZ, q_butterworth);
        design_notch   (s_chan[ch].filt.coeffs[2], fs, EMG_NOTCH_HZ, EMG_NOTCH_Q);
    }

    /* Hann window for the MDF estimate. Rectangular windowing would leak
     * enough to bias the median frequency upward. */
    for (int i = 0; i < MDF_FFT_SIZE; i++) {
        s_hann[i] = 0.5f * (1.0f - cosf(2.0f * M_PI * i / (MDF_FFT_SIZE - 1)));
    }

    if (dsps_fft2r_init_fc32(NULL, MDF_FFT_SIZE) != ESP_OK) {
        ESP_LOGE(TAG, "FFT init failed — fatigue detection disabled");
        s_fft_ready = false;
    } else {
        s_fft_ready = true;
    }

    ESP_LOGI(TAG, "chain up: HPF %.0f Hz, LPF %.0f Hz, notch %.0f Hz (Q %.0f), "
                  "envelope %d ms, MDF %d-point",
             EMG_HPF_HZ, EMG_LPF_HZ, EMG_NOTCH_HZ, EMG_NOTCH_Q,
             EMG_RMS_WINDOW_MS, MDF_FFT_SIZE);
    return ESP_OK;
}

void emg_dsp_set_calibration(const calib_record_t *calib)
{
    if (!calib) {
        s_have_calib = false;
        return;
    }
    memcpy(&s_calib, calib, sizeof(s_calib));
    s_have_calib = true;
}

/* ──────────────────────────────────────────────────────────────────────
 * Median frequency.
 *
 * The frequency below which half the signal power lies. It falls as muscle
 * fatigues — conduction velocity drops and the spectrum shifts down. Computed
 * only while the envelope shows real activation: the spectrum of a resting
 * muscle is noise, and averaging it into the trend would mask real fatigue.
 * ────────────────────────────────────────────────────────────────────── */
static float compute_mdf(const float *window)
{
    if (!s_fft_ready) {
        return 0.0f;
    }

    for (int i = 0; i < MDF_FFT_SIZE; i++) {
        s_fft_buf[2 * i]     = window[i] * s_hann[i];
        s_fft_buf[2 * i + 1] = 0.0f;
    }

    dsps_fft2r_fc32(s_fft_buf, MDF_FFT_SIZE);
    dsps_bit_rev_fc32(s_fft_buf, MDF_FFT_SIZE);

    /* Power spectrum over the first half (real input ⇒ symmetric). */
    const int   n_bins   = MDF_FFT_SIZE / 2;
    const float bin_hz   = (float)EMG_SAMPLE_RATE_HZ / MDF_FFT_SIZE;
    const int   lo_bin   = (int)(EMG_HPF_HZ / bin_hz);
    const int   hi_bin   = (int)(EMG_LPF_HZ / bin_hz);

    float total = 0.0f;
    static float power[MDF_FFT_SIZE / 2];

    for (int i = 0; i < n_bins; i++) {
        const float re = s_fft_buf[2 * i];
        const float im = s_fft_buf[2 * i + 1];
        power[i] = re * re + im * im;
        if (i >= lo_bin && i <= hi_bin) {
            total += power[i];
        }
    }

    if (total <= 0.0f) {
        return 0.0f;
    }

    const float half = total * 0.5f;
    float running = 0.0f;
    for (int i = lo_bin; i <= hi_bin; i++) {
        running += power[i];
        if (running >= half) {
            /* Linear interpolation inside the bin that crosses the halfway
             * mark — without it the estimate quantises to ~3.9 Hz steps,
             * which is coarse against the drift being tracked. */
            const float prev = running - power[i];
            const float frac = (power[i] > 0.0f) ? (half - prev) / power[i] : 0.0f;
            return (i + frac) * bin_hz;
        }
    }
    return (float)hi_bin * bin_hz;
}

/* ────────────────────────────────────────────────────────────────────── */

bool emg_dsp_push(const emg_frame_t *frame, emg_features_t *out)
{
    static uint32_t decimate_counter;
    bool emit = false;

    for (int ch = 0; ch < EMG_N_CHANNELS; ch++) {
        chan_state_t *st = &s_chan[ch];

        /* Normalise to ±1.0 before filtering so coefficients are scale-free. */
        float x = (float)frame->ch[ch] / (float)s_full_scale;

        if (frame->flags & ((ch == 0) ? EMG_FLAG_CLIP_A : EMG_FLAG_CLIP_B)) {
            st->clip_count++;
        }

        for (int b = 0; b < N_BIQUADS; b++) {
            float y;
            dsps_biquad_f32(&x, &y, 1, st->filt.coeffs[b], st->filt.state[b]);
            x = y;
        }

        /* Sliding sum of squares — O(1) per sample rather than re-summing
         * the whole window. */
        const float sq  = x * x;
        const float old = st->rms_window[st->rms_pos];
        st->rms_window[st->rms_pos] = sq;
        st->rms_sum_sq += sq - old;
        st->rms_pos = (st->rms_pos + 1) % EMG_RMS_WINDOW_SAMPLES;
        if (st->rms_pos == 0) {
            st->rms_primed = true;
        }

        /* Guard against negative drift from float cancellation over hours. */
        if (st->rms_sum_sq < 0.0f) {
            st->rms_sum_sq = 0.0f;
        }

        st->last_envelope_raw =
            sqrtf(st->rms_sum_sq / (float)EMG_RMS_WINDOW_SAMPLES);

        /* Accumulate the filtered signal for the next FFT. */
        st->fft_window[st->fft_pos++] = x;
        if (st->fft_pos >= MDF_FFT_SIZE) {
            float activation = st->last_envelope_raw;
            if (s_have_calib && s_calib.emg_mvc[ch] > 0.0f) {
                activation /= s_calib.emg_mvc[ch];
            }

            if (activation >= MDF_MIN_ACTIVATION) {
                st->last_mdf = compute_mdf(st->fft_window);
            } else {
                st->last_mdf = 0.0f;   /* resting: no meaningful spectrum */
            }

            /* 50 % overlap: keep the second half as the next window's first. */
            memmove(st->fft_window,
                    st->fft_window + MDF_OVERLAP,
                    (MDF_FFT_SIZE - MDF_OVERLAP) * sizeof(float));
            st->fft_pos = MDF_FFT_SIZE - MDF_OVERLAP;
        }
    }

    if (++decimate_counter >= s_decimate) {
        decimate_counter = 0;
        emit = true;

        memset(out, 0, sizeof(*out));
        out->t_us      = frame->t_us;
        out->mdf_valid = s_fft_ready;

        for (int ch = 0; ch < EMG_N_CHANNELS; ch++) {
            chan_state_t *st = &s_chan[ch];

            float env = st->last_envelope_raw;

            if (s_have_calib) {
                /* Force to zero below the rest baseline plus margin, so that
                 * noise does not read as weak activation. */
                const float floor_v = s_calib.emg_rest_rms[ch] * 1.5f;
                env = (env > floor_v) ? (env - floor_v) : 0.0f;

                if (s_calib.emg_mvc[ch] > floor_v) {
                    env /= (s_calib.emg_mvc[ch] - floor_v);
                }
                if (s_calib.flags & CALIB_FLAG_MVC_UNRELIABLE) {
                    out->sig_flags |= SIG_FLAG_MVC_UNRELIABLE;
                }
            }

            out->envelope[ch]   = env;
            out->mdf[ch]        = st->last_mdf;
            out->clip_count[ch] = st->clip_count;

            /* Sustained clipping means the gain pot is too high and the
             * spectrum is being destroyed — report it rather than silently
             * producing a plausible-looking envelope. */
            if (st->clip_count > EMG_SAMPLE_RATE_HZ / 10) {
                out->sig_flags |= (ch == 0) ? SIG_FLAG_DEGRADED_A
                                            : SIG_FLAG_DEGRADED_B;
            }
        }
    }

    return emit;
}

void emg_dsp_raw_rms(float out[EMG_N_CHANNELS])
{
    for (int ch = 0; ch < EMG_N_CHANNELS; ch++) {
        out[ch] = s_chan[ch].rms_primed ? s_chan[ch].last_envelope_raw : 0.0f;
    }
}

void emg_dsp_reset_clip_counters(void)
{
    for (int ch = 0; ch < EMG_N_CHANNELS; ch++) {
        s_chan[ch].clip_count = 0;
    }
}

void emg_dsp_reset(void)
{
    for (int ch = 0; ch < EMG_N_CHANNELS; ch++) {
        memset(s_chan[ch].filt.state, 0, sizeof(s_chan[ch].filt.state));
        memset(s_chan[ch].rms_window, 0, sizeof(s_chan[ch].rms_window));
        s_chan[ch].rms_pos    = 0;
        s_chan[ch].rms_sum_sq = 0.0f;
        s_chan[ch].rms_primed = false;
        s_chan[ch].fft_pos    = 0;
        s_chan[ch].last_mdf   = 0.0f;
    }
}
