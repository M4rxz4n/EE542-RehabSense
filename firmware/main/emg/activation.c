/*
 * activation.c — muscle-on detection with hysteresis [PRD §5.4]
 */

#include <string.h>
#include "activation.h"
#include "rehab_config.h"

static uint16_t ticks_for(uint32_t ms, uint32_t tick_hz)
{
    /* Round up: a 50 ms window at 50 Hz is 2.5 ticks, and asserting after 2
     * would be a 40 ms confirmation. Erring long is the safe direction for the
     * ON edge and harmless for the OFF edge. */
    uint32_t t = (ms * tick_hz + 999) / 1000;
    return (uint16_t)(t ? t : 1);
}

void activation_init(activation_det_t *d,
                     float rest_mean, float rest_sd, float mvc,
                     uint32_t tick_hz)
{
    memset(d, 0, sizeof(*d));

    if (tick_hz == 0) {
        tick_hz = FEATURE_RATE_HZ;
    }
    d->on_needed  = ticks_for(ACT_ON_CONFIRM_MS,  tick_hz);
    d->off_needed = ticks_for(ACT_OFF_CONFIRM_MS, tick_hz);

    /* The envelope this detector sees has already been through emg_dsp's
     * normalisation: zeroed below rest × EMG_NOISE_FLOOR_MULT, then scaled so
     * that the calibrated maximum reads 1.0. Thresholds expressed in raw RMS
     * must go through the same transform or they land somewhere else entirely.
     *
     *     env_norm = (raw - floor) / (mvc - floor),  floor = rest × MULT
     */
    const float floor_v = rest_mean * EMG_NOISE_FLOOR_MULT;
    const float denom   = mvc - floor_v;

    const bool usable = (denom > 1e-9f) && (rest_sd > 0.0f) &&
                        (rest_mean >= 0.0f);

    if (usable) {
        const float on_raw  = rest_mean + ACT_ON_SIGMA  * rest_sd;
        const float off_raw = rest_mean + ACT_OFF_SIGMA * rest_sd;
        d->on_thresh  = (on_raw  - floor_v) / denom;
        d->off_thresh = (off_raw - floor_v) / denom;

        /* A quiet rest capture can put 3σ below the noise floor the DSP
         * already zeroes, which would make the gate fire on any non-zero
         * sample. Hold it just above zero instead. */
        if (d->on_thresh < ACT_MIN_THRESH) {
            d->on_thresh  = ACT_MIN_THRESH;
            d->off_thresh = ACT_MIN_THRESH * 0.66f;
        }
    }

    /* A rest capture so quiet that 3σ still sits inside the noise, or so noisy
     * that it swallows the whole MVC range, is not a usable reference. Clamp
     * into a band where the detector can still do its job, and record that the
     * thresholds are not the calibrated ones. */
    if (!usable || d->on_thresh <= 0.0f || d->on_thresh >= 1.0f) {
        d->on_thresh      = ACT_FALLBACK_MVC_FRAC;
        d->off_thresh     = ACT_FALLBACK_MVC_FRAC * 0.66f;
        d->using_fallback = true;
    }

    /* Keep the ordering invariant even if a strange σ inverted them. */
    if (d->off_thresh > d->on_thresh) {
        d->off_thresh = d->on_thresh;
    }
}

bool activation_update(activation_det_t *d, float envelope)
{
    if (!d->on) {
        if (envelope > d->on_thresh) {
            if (++d->on_ticks >= d->on_needed) {
                d->on        = true;
                d->off_ticks = 0;
            }
        } else {
            d->on_ticks = 0;
        }
    } else {
        if (envelope < d->off_thresh) {
            if (++d->off_ticks >= d->off_needed) {
                d->on       = false;
                d->on_ticks = 0;
            }
        } else {
            d->off_ticks = 0;
        }
    }
    return d->on;
}

void activation_reset(activation_det_t *d)
{
    d->on        = false;
    d->on_ticks  = 0;
    d->off_ticks = 0;
}
