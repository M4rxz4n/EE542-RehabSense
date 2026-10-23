/*
 * emg_dsp.h — per-channel EMG signal chain
 *
 * Order, running at EMG_SAMPLE_RATE_HZ on the raw stream:
 *   1. High-pass 20 Hz      — electrode drift, motion artefact, ADC offset
 *   2. Low-pass 450 Hz      — band-limit to useful sEMG
 *   3. Notch 60 Hz          — mains pickup
 *   4. Clip detection       — so the MyoWare gain pots can be set by number
 *   5. Rectify + 150 ms RMS — the envelope, decimated to FEATURE_RATE_HZ
 *   6. Normalise to %MVC    — against the calibrated maximum
 *   7. Median frequency     — 512-point FFT, only while actually contracting
 */

#ifndef EMG_DSP_H
#define EMG_DSP_H

#include "esp_err.h"
#include "rehab_types.h"

typedef struct {
    float    envelope[EMG_N_CHANNELS];   /* %MVC, 0..1+ */
    float    mdf[EMG_N_CHANNELS];        /* Hz; 0 when below activation */
    float    mains_frac[EMG_N_CHANNELS]; /* power removed by the 60 Hz notch */
    uint32_t clip_count[EMG_N_CHANNELS]; /* cumulative since reset */
    uint16_t sig_flags;
    uint64_t t_us;
    bool     mdf_valid;
} emg_features_t;

esp_err_t emg_dsp_init(int32_t full_scale);

/* Normalisation and the fatigue reference come from the calibration record.
 * Call again after any recalibration. */
void emg_dsp_set_calibration(const calib_record_t *calib);

/* Push one sample frame. Returns true when a new feature set is ready, which
 * happens at FEATURE_RATE_HZ rather than on every sample. */
bool emg_dsp_push(const emg_frame_t *frame, emg_features_t *out);

/* Raw (un-normalised) RMS over the last envelope window. Calibration uses this
 * before a normalisation reference exists. */
void emg_dsp_raw_rms(float out[EMG_N_CHANNELS]);

void emg_dsp_reset_clip_counters(void);
void emg_dsp_reset(void);

#endif /* EMG_DSP_H */
