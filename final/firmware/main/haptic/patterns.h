/*
 * patterns.h — the haptic vocabulary [PRD §5.6]
 *
 * One motor carries seven messages, through fabric, on a limb that may have
 * reduced sensation.
 *
 * Six are results, delivered at a stationary moment. The seventh — the soft
 * click at 80 % of the target angle — is a waypoint delivered mid-movement,
 * and is deliberately the shortest and lightest of the set so that it cannot
 * be mistaken for one of the six.
 *
 * ACTUATOR: Adafruit 1201 ERM. An ERM's vibration frequency is coupled to its
 * amplitude, so "stronger" also means "faster" and cannot carry independent
 * meaning. Every pattern is therefore distinguished by RHYTHM — pulse count,
 * width and gap — and every cue plays at ONE consistent amplitude, which is
 * also easier for a patient to learn than a set of intensity gradations.
 *
 * The rest cue is the single exception, and deliberately so: a ramp is a
 * change in character rather than a gradation, which is what stops it being
 * mistaken for a repetition signal.
 *
 * Gaps are at least HAPTIC_MIN_GAP_MS. Active braking through the driver is
 * what makes 60 ms workable; without a driver IC the floor would be ~120 ms.
 * The shortest gap any pattern asks for is 70 ms, so all of them clear it.
 */

#ifndef PATTERNS_H
#define PATTERNS_H

#include <stdint.h>
#include <stdbool.h>

typedef enum {
    PATTERN_NONE = 0,
    PATTERN_TICK,              /* one 40 ms tick — button acknowledged      */
    PATTERN_REP_CLEAN,         /* one 100 ms click                          */
    PATTERN_REP_FLAGGED,       /* three 80 ms pulses, 80 ms gaps            */
    PATTERN_SET_COMPLETE,      /* two 70 ms pulses, then one 500 ms pulse   */
    PATTERN_REST,              /* 1000 ms ramp up and down                  */
    PATTERN_FAULT,             /* two 300 ms pulses, 300 ms apart           */
    PATTERN_SOFT_CLICK,        /* 30 ms at reduced level — 80 % of target   */

    /* Compound cues for the repetition that completes the set. The
     * per-repetition result plays first, then a 300 ms gap, then the
     * set-complete pattern, so the patient receives both the quality result
     * and confirmation that the set is finished [PRD §5.6].
     *
     * These exist as single patterns rather than two queued requests because
     * the single-slot scheduler would otherwise drop the second one. */
    PATTERN_REP_CLEAN_THEN_SET,
    PATTERN_REP_FLAGGED_THEN_SET,

    PATTERN_COUNT
} haptic_pattern_t;

void haptic_task_start(void);

/* Queue a pattern.
 *
 * Scheduling rules [PRD §5.6]:
 *   - one cue plays at a time
 *   - a FAULT preempts a playing cue and clears anything pending
 *   - a TICK is dropped if any cue is playing
 *   - otherwise a new cue takes the single pending slot only if its priority
 *     exceeds that of the cue already waiting
 *
 * Priorities, lowest to highest: tick, repetition result, set complete and
 * rest, fault. */
void haptic_play(haptic_pattern_t pattern);

/* Stop immediately: cancels any pattern in flight and clears the slot. */
void haptic_stop(void);

bool haptic_is_busy(void);

/* Nominal duration of a pattern, for the fault-cue-before-mute delay and for
 * host-side test expectations. */
uint32_t haptic_pattern_duration_ms(haptic_pattern_t pattern);

#endif /* PATTERNS_H */
