/*
 * patterns.c — haptic pattern playback [PRD §5.6]
 *
 * Patterns are built by modulating PWM duty over time, which gives finer
 * control over pulse shape than the DRV2605L's built-in effects ROM.
 *
 * Each pulse opens with a short overdrive kick. Without it an ERM's onset is
 * soft and the pulse reads as a fade rather than a tap, which is the
 * difference between a reward signal and a vague buzz.
 */

#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "esp_log.h"

#include "patterns.h"
#include "drv2605l.h"
#include "rehab_config.h"

static const char *TAG = "haptic";

#define MAX_STEPS      16

/* Preemption granularity. A fault must interrupt a playing cue, so no single
 * delay runs longer than this without checking the cancel flag. */
#define SLICE_MS       10

typedef struct {
    float    level;      /* 0..1 — FULL for every pattern but the rest ramp */
    uint16_t ms;
} step_t;

typedef struct {
    const char *name;
    uint8_t     priority;     /* higher wins */
    bool        no_overdrive; /* play at the stated level, no onset kick */
    uint8_t     n_steps;
    step_t      steps[MAX_STEPS];
} pattern_def_t;

/* Priorities, lowest to highest: tick, repetition result, set complete and
 * rest, fault [PRD §5.6]. The clean and flagged repetition cues share a rank
 * because they are one class — "repetition result" — and exactly one of them
 * is ever issued per repetition. */
#define PRI_TICK      1   /* button tick, and the mid-movement soft click */
#define PRI_REP       2
#define PRI_SET_REST  3
#define PRI_FAULT     4

#define FULL 1.00f

static const pattern_def_t s_patterns[PATTERN_COUNT] = {
    [PATTERN_NONE] = { "none", 0, false, 0, {{0}} },

    [PATTERN_TICK] = {
        "tick", PRI_TICK, false, 1,
        { { FULL, HAP_TICK_MS } },
    },

    [PATTERN_REP_CLEAN] = {
        "rep-clean", PRI_REP, false, 1,
        { { FULL, HAP_CLEAN_MS } },
    },

    [PATTERN_REP_FLAGGED] = {
        "rep-flagged", PRI_REP, false, 5,
        { { FULL, HAP_FLAGGED_PULSE_MS }, { 0.0f, HAP_FLAGGED_GAP_MS },
          { FULL, HAP_FLAGGED_PULSE_MS }, { 0.0f, HAP_FLAGGED_GAP_MS },
          { FULL, HAP_FLAGGED_PULSE_MS } },
    },

    [PATTERN_SET_COMPLETE] = {
        "set-complete", PRI_SET_REST, false, 5,
        { { FULL, HAP_SETDONE_PULSE_MS }, { 0.0f, HAP_SETDONE_GAP_MS },
          { FULL, HAP_SETDONE_PULSE_MS }, { 0.0f, HAP_SETDONE_GAP_MS },
          { FULL, HAP_SETDONE_FINAL_MS } },
    },

    [PATTERN_REST] = {
        /* A ramp rather than pulses: clearly different in character from
         * everything else, so it cannot be mistaken for a rep signal. This is
         * the one place amplitude varies, and it varies as a shape rather
         * than as a level carrying meaning. */
        "rest", PRI_SET_REST, false, 8,
        { { 0.20f, HAP_REST_RAMP_MS / 8 }, { 0.40f, HAP_REST_RAMP_MS / 8 },
          { 0.70f, HAP_REST_RAMP_MS / 8 }, { FULL,  HAP_REST_RAMP_MS / 8 },
          { FULL,  HAP_REST_RAMP_MS / 8 }, { 0.70f, HAP_REST_RAMP_MS / 8 },
          { 0.40f, HAP_REST_RAMP_MS / 8 }, { 0.20f, HAP_REST_RAMP_MS / 8 } },
    },

    [PATTERN_FAULT] = {
        "fault", PRI_FAULT, false, 3,
        { { FULL, HAP_FAULT_PULSE_MS }, { 0.0f, HAP_FAULT_GAP_MS },
          { FULL, HAP_FAULT_PULSE_MS } },
    },

    [PATTERN_SOFT_CLICK] = {
        /* The only cue that fires while the patient is moving, so it shares
         * the tick's priority: it is dropped rather than displacing a result
         * if anything else is playing. A waypoint the patient misses costs
         * nothing; a result they miss costs the repetition. */
        "soft-click", PRI_TICK, true, 1,
        { { HAP_SOFT_CLICK_LEVEL, HAP_SOFT_CLICK_MS } },
    },

    [PATTERN_REP_CLEAN_THEN_SET] = {
        "rep-clean+set", PRI_SET_REST, false, 7,
        { { FULL, HAP_CLEAN_MS },
          { 0.0f, HAP_SET_COMPLETE_GAP_MS },
          { FULL, HAP_SETDONE_PULSE_MS }, { 0.0f, HAP_SETDONE_GAP_MS },
          { FULL, HAP_SETDONE_PULSE_MS }, { 0.0f, HAP_SETDONE_GAP_MS },
          { FULL, HAP_SETDONE_FINAL_MS } },
    },

    [PATTERN_REP_FLAGGED_THEN_SET] = {
        "rep-flagged+set", PRI_SET_REST, false, 11,
        { { FULL, HAP_FLAGGED_PULSE_MS }, { 0.0f, HAP_FLAGGED_GAP_MS },
          { FULL, HAP_FLAGGED_PULSE_MS }, { 0.0f, HAP_FLAGGED_GAP_MS },
          { FULL, HAP_FLAGGED_PULSE_MS },
          { 0.0f, HAP_SET_COMPLETE_GAP_MS },
          { FULL, HAP_SETDONE_PULSE_MS }, { 0.0f, HAP_SETDONE_GAP_MS },
          { FULL, HAP_SETDONE_PULSE_MS }, { 0.0f, HAP_SETDONE_GAP_MS },
          { FULL, HAP_SETDONE_FINAL_MS } },
    },
};

static QueueHandle_t  s_queue;
static TaskHandle_t   s_task;
static volatile bool  s_busy;
static volatile bool  s_cancel;
static volatile haptic_pattern_t s_pending;

uint32_t haptic_pattern_duration_ms(haptic_pattern_t pattern)
{
    if (pattern <= PATTERN_NONE || pattern >= PATTERN_COUNT) {
        return 0;
    }
    const pattern_def_t *p = &s_patterns[pattern];
    uint32_t total = 0;
    for (int i = 0; i < p->n_steps; i++) {
        total += p->steps[i].ms;
    }
    return total;
}

/* Delay in slices so a fault can interrupt. Returns false if cancelled. */
static bool sliced_delay(uint16_t ms)
{
    uint16_t left = ms;
    while (left > 0) {
        if (s_cancel) {
            return false;
        }
        const uint16_t chunk = (left > SLICE_MS) ? SLICE_MS : left;
        vTaskDelay(pdMS_TO_TICKS(chunk));
        left -= chunk;
    }
    return !s_cancel;
}

static void play(const pattern_def_t *p)
{
    for (int i = 0; i < p->n_steps; i++) {
        const step_t *st = &p->steps[i];

        if (s_cancel) {
            break;
        }

        if (st->level > 0.0f) {
            if (p->no_overdrive) {
                /* The soft click is meant to be felt as lighter than a
                 * result. An onset kick at full amplitude would erase that
                 * difference in the first 20 ms, which is most of the cue. */
                drv2605l_set_level(st->level);
                if (!sliced_delay(st->ms)) break;
            } else {
                /* Overdrive kick, then settle to the target level. Without it
                 * an ERM's onset is soft and the pulse reads as a fade rather
                 * than a tap. */
                const uint16_t kick = (st->ms > HAPTIC_OVERDRIVE_MS)
                                          ? HAPTIC_OVERDRIVE_MS : st->ms;
                drv2605l_set_level(1.0f);
                if (!sliced_delay(kick)) break;

                if (st->ms > kick) {
                    drv2605l_set_level(st->level);
                    if (!sliced_delay(st->ms - kick)) break;
                }
            }
        } else {
            drv2605l_set_level(0.0f);
            if (!sliced_delay(st->ms)) break;
        }
    }
    drv2605l_set_level(0.0f);
}

static void haptic_task(void *arg)
{
    haptic_pattern_t req;

    for (;;) {
        if (xQueueReceive(s_queue, &req, portMAX_DELAY) != pdTRUE) {
            continue;
        }
        if (req <= PATTERN_NONE || req >= PATTERN_COUNT) {
            continue;
        }

        s_busy    = true;
        s_cancel  = false;
        s_pending = PATTERN_NONE;

        const pattern_def_t *p = &s_patterns[req];
        ESP_LOGD(TAG, "playing %s (%u ms)", p->name,
                 (unsigned)haptic_pattern_duration_ms(req));
        play(p);

        s_busy   = false;
        s_cancel = false;
    }
}

void haptic_task_start(void)
{
    /* Depth 1: single-slot by design. A second request while one is playing
     * either replaces the waiting slot or is dropped, so two patterns can
     * never overlap. */
    s_queue = xQueueCreate(1, sizeof(haptic_pattern_t));
    xTaskCreatePinnedToCore(haptic_task, "haptic", STACK_HAPTIC, NULL,
                            PRIO_HAPTIC, &s_task, CORE_COMMS);
}

void haptic_play(haptic_pattern_t pattern)
{
    if (!s_queue || pattern <= PATTERN_NONE || pattern >= PATTERN_COUNT) {
        return;
    }

    const uint8_t incoming = s_patterns[pattern].priority;

    /* A fault preempts whatever is playing and clears anything pending. It is
     * the only cue allowed to interrupt, because it is the only one whose
     * information cannot wait for the current cue to finish. */
    if (incoming >= PRI_FAULT) {
        s_cancel = true;
        xQueueReset(s_queue);
        s_pending = pattern;
        xQueueSend(s_queue, &pattern, 0);
        return;
    }

    /* A tick is dropped if anything is playing or waiting: it confirms a
     * button press, and a button press during a cue is not worth displacing
     * the cue for. */
    if (incoming == PRI_TICK && haptic_is_busy()) {
        return;
    }

    /* If something is already waiting, keep whichever matters more. */
    haptic_pattern_t waiting;
    if (xQueuePeek(s_queue, &waiting, 0) == pdTRUE) {
        if (s_patterns[waiting].priority >= incoming) {
            return;
        }
        xQueueReset(s_queue);
    }

    s_pending = pattern;
    xQueueSend(s_queue, &pattern, 0);
}

void haptic_stop(void)
{
    s_cancel = true;
    if (s_queue) {
        xQueueReset(s_queue);
    }
    s_pending = PATTERN_NONE;
    drv2605l_set_level(0.0f);
}

bool haptic_is_busy(void)
{
    return s_busy || (s_pending != PATTERN_NONE);
}
