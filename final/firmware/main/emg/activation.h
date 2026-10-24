/*
 * activation.h — muscle-on detection with hysteresis [PRD §5.4]
 *
 * "Envelope above rest mean + 3σ for 50 ms turns activation on; below rest
 * mean + 2σ for 100 ms turns it off."
 *
 * This replaces a fixed %MVC threshold, which cannot adapt to a session's own
 * noise floor. Both the mean and σ come from calibration step 1, per channel.
 *
 * The hysteresis is not decoration. A single-threshold detector chatters at
 * the boundary, and chatter on this signal means repetitions starting and
 * abandoning at random — the asymmetric confirmation windows (fast on, slow
 * off) are what make the gate usable on a real limb.
 *
 * It lives in its own translation unit so the host test build can link it
 * without pulling in the biquad chain and the FFT.
 */

#ifndef ACTIVATION_H
#define ACTIVATION_H

#include <stdbool.h>
#include <stdint.h>

typedef struct {
    float    on_thresh;     /* %MVC */
    float    off_thresh;    /* %MVC */
    uint16_t on_needed;     /* consecutive ticks to assert   */
    uint16_t off_needed;    /* consecutive ticks to release  */
    uint16_t on_ticks;
    uint16_t off_ticks;
    bool     on;
    bool     using_fallback; /* calibration gave no usable σ */
} activation_det_t;

/* Thresholds are derived in raw envelope units and then expressed as %MVC, so
 * the detector can run against the same normalised envelope every other
 * consumer sees.
 *
 * rest_mean, rest_sd and mvc are all RAW RMS from calibration, before
 * normalisation exists. If σ or the maximum is unusable, the detector falls
 * back to a fixed fraction of MVC and says so through using_fallback — it
 * never fails open, because failing open silently restores exactly the
 * behaviour this replaces.
 *
 * tick_hz is the rate activation_update() will be called at. */
void activation_init(activation_det_t *d,
                     float rest_mean, float rest_sd, float mvc,
                     uint32_t tick_hz);

/* Feed one normalised envelope sample (%MVC). Returns the debounced state. */
bool activation_update(activation_det_t *d, float envelope);

/* Force the detector to the released state without changing its thresholds.
 * Used when a set begins, so a residual contraction from the previous set
 * cannot arm the first repetition. */
void activation_reset(activation_det_t *d);

#endif /* ACTIVATION_H */
