/*
 * grading.h — repetition quality score
 *
 * Every completed repetition is counted and THEN graded. Nothing is silently
 * discarded: a patient who gets no credit for a hard-won compensated
 * repetition learns that the device is broken, not that their form needs work.
 *
 * Weights and penalties live in rehab_config.h and are overridable per patient
 * from the therapist board. A reasonable penalty for a healthy volunteer
 * staging a compensation is an unreasonable one for a patient whose
 * compensation is the only way they can complete the movement at all.
 */

#ifndef GRADING_H
#define GRADING_H

#include "rehab_types.h"

typedef struct {
    float    peak_angle;
    float    angle_min;
    float    angle_max;
    float    activation_sum;     /* summed agonist %MVC over the rep */
    float    antagonist_sum;
    uint32_t activation_n;
    float    jerk_sum;           /* summed |d(velocity)| */
    float    speed_sum;          /* summed |velocity|, normalises the above */
    uint32_t jerk_n;
    float    hold_sum;           /* angle during holds */
    float    hold_sum_sq;
    uint32_t hold_n;
    uint16_t comp_flags;
} grading_input_t;

void grading_evaluate(const grading_input_t *in, rep_result_t *out);

/* Runtime overrides pushed from the therapist board. Pass NULL to restore the
 * compile-time defaults. */
typedef struct {
    float w_range, w_activation, w_smoothness, w_hold_steady;
    float p_shoulder, p_trunk, p_swing, p_cocontraction;
    float cocontraction_threshold;
} grading_weights_t;

void grading_set_weights(const grading_weights_t *w);

#endif /* GRADING_H */
