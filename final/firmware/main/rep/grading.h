/*
 * grading.h — repetition quality score, 0..100 [PRD §5.5]
 *
 * Four components of equal weight by default:
 *
 *   range          peak angle against the therapist's TARGET angle
 *   tempo          start threshold to finish threshold, against the window
 *   smoothness     velocity-peak count: one push scores 100
 *   co-contraction antagonist overlap while the agonist is active
 *
 * Then deductions for shoulder compensation, trunk lean and momentum, and the
 * result clamped to 0..100.
 *
 * Steadiness during the confirming hold is computed and REPORTED but does not
 * contribute to the default score. It is available as an optional fifth
 * component by giving w_hold_steady a non-zero weight.
 *
 * Every completed repetition is counted and THEN graded. Nothing is silently
 * discarded: a patient who gets no credit for a hard-won compensated
 * repetition learns that the device is broken, not that their form needs work.
 *
 * Weights and penalties are overridable per patient from the host. A
 * reasonable penalty for a healthy volunteer staging a compensation is an
 * unreasonable one for a patient whose compensation is the only way they can
 * complete the movement at all.
 */

#ifndef GRADING_H
#define GRADING_H

#include "rehab_types.h"

typedef struct {
    float    peak_angle;
    float    angle_min;          /* calibrated extension, the angle origin */
    float    target_angle;       /* therapist-set [PRD §5.9.1] */
    float    tempo_s;            /* start threshold to finish threshold */

    float    activation_sum;     /* summed agonist %MVC over the rep */
    float    antagonist_sum;     /* summed antagonist %MVC over the rep */
    float    overlap_sum;        /* antagonist WHILE the agonist was active */
    uint32_t activation_n;
    uint32_t overlap_n;

    uint8_t  velocity_peaks;     /* peaks above 10 % of this rep's peak speed */

    float    hold_sum;           /* angle during the confirming hold */
    float    hold_sum_sq;
    uint32_t hold_n;

    uint16_t comp_flags;
    bool     jolt_excluded;      /* a spike voided part of this repetition */
} grading_input_t;

void grading_evaluate(const grading_input_t *in, rep_result_t *out);

/* Runtime weights from the host [PRD §5.9.1]. Pass NULL to restore the
 * compile-time defaults. */
void grading_set_config(const rehab_runtime_cfg_t *cfg);

#endif /* GRADING_H */
