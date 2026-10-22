/*
 * patterns.h — the haptic vocabulary
 *
 * One motor has to carry five messages, through fabric, on a limb that may
 * have reduced sensation. An ERM's vibration frequency is coupled to its
 * amplitude, so "stronger" also means "faster" and cannot carry independent
 * meaning: every pattern is therefore distinguished by RHYTHM.
 *
 * Gaps are at least HAPTIC_MIN_GAP_MS. Active braking through the driver is
 * what makes 60 ms workable; without a driver IC the floor would be ~120 ms.
 */

#ifndef PATTERNS_H
#define PATTERNS_H

#include <stdint.h>
#include <stdbool.h>

typedef enum {
    PATTERN_NONE = 0,
    PATTERN_REP_COMPLETE,       /* one 100 ms pulse            */
    PATTERN_REP_COMPENSATED,    /* three 80 ms pulses          */
    PATTERN_WRONG_START,        /* one 300 ms pulse at 50 %    */
    PATTERN_REST_CUE,           /* 1000 ms ramp up then down   */
    PATTERN_BOOT_OK,            /* two 100 ms pulses           */
    PATTERN_COUNT
} haptic_pattern_t;

void haptic_task_start(void);

/* Queue a pattern. Single-slot with priority: a higher-priority pattern
 * replaces a waiting one rather than blending into an ambiguous mush, and
 * exactly one haptic plays at a time. */
void haptic_play(haptic_pattern_t pattern);

/* Stop immediately and clear the slot. */
void haptic_stop(void);

bool haptic_is_busy(void);

#endif /* PATTERNS_H */
