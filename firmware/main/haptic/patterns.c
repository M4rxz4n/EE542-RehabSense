/*
 * patterns.c — haptic pattern playback
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

#define OVERDRIVE_MS   20
#define MAX_STEPS      8

typedef struct {
    float    level;      /* 0..1 */
    uint16_t ms;
} step_t;

typedef struct {
    const char *name;
    uint8_t     priority;     /* higher wins */
    uint8_t     n_steps;
    step_t      steps[MAX_STEPS];
} pattern_def_t;

/* Gaps are level 0. Minimum 60 ms so the motor actually stops between
 * pulses — merged pulses read as one long buzz and lose the rhythm that
 * carries the meaning. */
static const pattern_def_t s_patterns[PATTERN_COUNT] = {
    [PATTERN_NONE] = { "none", 0, 0, {{0}} },

    [PATTERN_REP_COMPLETE] = {
        "rep-complete", 2, 1,
        { { 1.00f, 100 } },
    },

    [PATTERN_REP_COMPENSATED] = {
        "rep-compensated", 3, 5,
        { { 1.00f, 80 }, { 0.0f, 80 },
          { 1.00f, 80 }, { 0.0f, 80 },
          { 1.00f, 80 } },
    },

    [PATTERN_WRONG_START] = {
        "wrong-start", 1, 1,
        { { 0.50f, 300 } },
    },

    [PATTERN_REST_CUE] = {
        /* A ramp rather than pulses: clearly different in character from
         * everything else, so it cannot be mistaken for a rep signal. */
        "rest-cue", 4, 8,
        { { 0.20f, 125 }, { 0.40f, 125 }, { 0.70f, 125 }, { 1.00f, 125 },
          { 1.00f, 125 }, { 0.70f, 125 }, { 0.40f, 125 }, { 0.20f, 125 } },
    },

    [PATTERN_BOOT_OK] = {
        "boot-ok", 1, 3,
        { { 1.00f, 100 }, { 0.0f, 200 }, { 1.00f, 100 } },
    },
};

static QueueHandle_t  s_queue;
static TaskHandle_t   s_task;
static volatile bool  s_busy;
static volatile haptic_pattern_t s_pending;

static void play(const pattern_def_t *p)
{
    for (int i = 0; i < p->n_steps; i++) {
        const step_t *st = &p->steps[i];

        if (st->level > 0.0f) {
            /* Overdrive kick, then settle to the target level. */
            const uint16_t kick = (st->ms > OVERDRIVE_MS) ? OVERDRIVE_MS : st->ms;
            drv2605l_set_level(1.0f);
            vTaskDelay(pdMS_TO_TICKS(kick));

            if (st->ms > kick) {
                drv2605l_set_level(st->level);
                vTaskDelay(pdMS_TO_TICKS(st->ms - kick));
            }
        } else {
            drv2605l_set_level(0.0f);
            vTaskDelay(pdMS_TO_TICKS(st->ms));
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

        s_busy = true;
        s_pending = PATTERN_NONE;

        const pattern_def_t *p = &s_patterns[req];
        ESP_LOGD(TAG, "playing %s", p->name);
        play(p);

        s_busy = false;
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
    if (s_queue) {
        xQueueReset(s_queue);
    }
    drv2605l_set_level(0.0f);
}

bool haptic_is_busy(void)
{
    return s_busy || (s_pending != PATTERN_NONE);
}
