/*
 * rep_cycle.h — repetition detection [PRD §5.4]
 *
 * A repetition BEGINS when the biceps activates and the arm rises past the
 * start threshold, and is COUNTED when the arm has returned below the finish
 * threshold and been held still there for hold_duration_ms.
 *
 *   READY -> CONCENTRIC -> PEAK -> ECCENTRIC -> EXTENDED_HOLD -> (counted)
 *     ^                                                              |
 *     +--------------------------------------------------------------+
 *
 * Two properties follow from counting on the RETURN rather than at the top.
 * The score covers the whole movement including the eccentric phase, which is
 * where a weak limb usually fails first. And the confirming hold supplies a
 * stationary moment at a predictable point, which is what the haptic and the
 * gravity re-anchor both need — feedback is scheduled, not reactive.
 *
 * ARMING REQUIRES THE AGONIST
 * ---------------------------
 * Leaving READY needs posture AND muscle. Posture alone is satisfied by an arm
 * somebody else is moving, which is precisely the case this device exists to
 * catch and the one a motion-only device cannot. An arm that rises with the
 * agonist quiet produces REP_EVT_PASSIVE_SWING and no count.
 *
 * Deliberately not a learned model. Threshold crossings held for a fixed
 * duration are a solved problem: deterministic, debuggable, and every miscount
 * traces back to a threshold you can print. There is also no training data yet
 * — these thresholds are what produce the labelled repetition boundaries any
 * future model would need.
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
    REP_EVT_REP_START,        /* activation + start threshold: rep underway */
    REP_EVT_PEAK_REACHED,     /* 80 % of target — the soft click fires here */
    REP_EVT_HOLD_START,       /* settled at extension, confirming timer running */
    REP_EVT_REP_COMPLETE,     /* hold satisfied — counted, graded, haptic */
    REP_EVT_REP_ABANDONED,    /* phase timeout or fell back: partial */
    REP_EVT_PASSIVE_SWING,    /* angle rose with the agonist quiet */
} rep_event_t;

typedef struct {
    rep_event_t  event;
    rep_state_t  state;
    uint16_t     rep_count;
    uint16_t     comp_flags;
    bool         activation_on;   /* agonist live on this tick */
    bool         set_complete;    /* this repetition reached rep_target */
    rep_result_t result;          /* valid when event == REP_EVT_REP_COMPLETE */
} rep_tick_t;

void rep_cycle_init(void);

/* Calibration supplies the activation thresholds (rest mean and sigma) and the
 * angle scale. Call after every calibration and every session re-zero. */
void rep_cycle_set_calibration(const calib_record_t *calib);

/* Runtime parameters from the host [PRD §5.9.1]. Angles, the hold length and
 * the tempo window are read per tick rather than latched at the start of a
 * repetition, so a change mid-session takes effect on the next repetition
 * without disturbing one already underway. */
void rep_cycle_set_config(const rehab_runtime_cfg_t *cfg);

/* Start and end a set. Resets the counter, the fatigue trend and the
 * activation detector. */
void rep_cycle_begin_set(void);
void rep_cycle_end_set(void);

/* Call at FEATURE_RATE_HZ. Returns what happened on this tick. */
void rep_cycle_tick(const fusion_out_t *motion,
                    const emg_features_t *emg,
                    uint64_t t_us,
                    rep_tick_t *out);

bool rep_cycle_activation_on(void);
bool rep_cycle_set_complete(void);
bool rep_cycle_fatigue_flagged(void);

#endif /* REP_CYCLE_H */
