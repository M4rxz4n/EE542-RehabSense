/*
 * rep_cycle.h — hold-gated repetition detection
 *
 * A repetition is bounded by two deliberate 1-second holds, not by velocity or
 * elapsed time. The patient extends to their limit and holds, curls up, holds
 * at the top, then returns. The repetition is counted at the end of the top
 * hold, and that is also when the haptic fires.
 *
 *   WAIT_START -> EXTENDED_HOLD -> CONCENTRIC -> FLEXED_HOLD -> ECCENTRIC
 *                      ^                                            |
 *                      +--------------------------------------------+
 *
 * This removes timing pressure from the feedback path: every haptic lands at a
 * moment the patient is already stationary and expecting it.
 */

#ifndef REP_CYCLE_H
#define REP_CYCLE_H

#include "rehab_types.h"
#include "fusion.h"
#include "emg_dsp.h"

typedef enum {
    REP_EVT_NONE = 0,
    REP_EVT_START_POS_OK,
    REP_EVT_START_POS_BAD,
    REP_EVT_HOLD_START,       /* entered a hold band, timer running */
    REP_EVT_REP_START,        /* bottom hold satisfied, rep underway */
    REP_EVT_REP_COMPLETE,     /* top hold satisfied — fire the haptic */
    REP_EVT_REP_ABANDONED,
    REP_EVT_COMPENSATION,     /* latched during the rep, reported at the top */
} rep_event_t;

typedef struct {
    rep_event_t  event;
    rep_state_t  state;
    uint16_t     rep_count;
    uint16_t     comp_flags;
    rep_result_t result;      /* valid when event == REP_EVT_REP_COMPLETE */
} rep_tick_t;

void rep_cycle_init(void);
void rep_cycle_set_calibration(const calib_record_t *calib);

/* Start and end a set. Resets the counter and the fatigue trend. */
void rep_cycle_begin_set(void);
void rep_cycle_end_set(void);

/* Call at FEATURE_RATE_HZ. Returns what happened on this tick. */
void rep_cycle_tick(const fusion_out_t *motion,
                    const emg_features_t *emg,
                    uint64_t t_us,
                    rep_tick_t *out);

/* True once the fatigue criterion has been met for this set. */
bool rep_cycle_fatigue_flagged(void);

#endif /* REP_CYCLE_H */
