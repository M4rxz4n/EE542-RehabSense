/*
 * status_led.c — WS2812 state indicator
 *
 * Palette matches the design doc. Once the physical colour coding for the
 * electrodes is decided, it should reuse these colours so the device and the
 * app speak one language.
 */

#include <string.h>
#include <math.h>
#include "led_strip.h"
#include "esp_log.h"
#include "esp_check.h"

#include "status_led.h"
#include "rehab_config.h"

static const char *TAG = "led";

typedef enum { ANIM_SOLID, ANIM_PULSE, ANIM_BREATHE, ANIM_OFF } anim_t;

typedef struct {
    uint8_t r, g, b;
    anim_t  anim;
} led_style_t;

static const led_style_t s_styles[] = {
    [FW_STATE_OFF]           = {   0,   0,   0, ANIM_OFF     },
    [FW_STATE_BOOT]          = { 255, 255, 255, ANIM_PULSE   },
    [FW_STATE_STANDBY]       = {   0,  80, 255, ANIM_BREATHE },
    [FW_STATE_DONNING_CHECK] = { 255, 150,   0, ANIM_SOLID   },
    [FW_STATE_CALIBRATION]   = { 255, 150,   0, ANIM_PULSE   },
    [FW_STATE_OPERATIONAL]   = {   0, 220,  60, ANIM_SOLID   },
    [FW_STATE_FAULT]         = { 255,   0,   0, ANIM_SOLID   },
};

static led_strip_handle_t s_strip;
static fw_state_t         s_state = FW_STATE_OFF;
static bool               s_link_up;
static uint32_t           s_tick;

esp_err_t status_led_init(void)
{
    led_strip_config_t cfg = {
        .strip_gpio_num = PIN_STATUS_LED,
        .max_leds       = 1,
        .led_model      = LED_MODEL_WS2812,
        .color_component_format = LED_STRIP_COLOR_COMPONENT_FMT_GRB,
    };
    led_strip_rmt_config_t rmt = {
        .clk_src       = RMT_CLK_SRC_DEFAULT,
        .resolution_hz = 10 * 1000 * 1000,
    };
    ESP_RETURN_ON_ERROR(led_strip_new_rmt_device(&cfg, &rmt, &s_strip),
                        TAG, "led strip init on GPIO%d", PIN_STATUS_LED);

    led_strip_clear(s_strip);
    ESP_LOGI(TAG, "status LED on GPIO%d (v1.0 boards use GPIO48)",
             PIN_STATUS_LED);
    return ESP_OK;
}

void status_led_set_state(fw_state_t state)
{
    s_state = state;
    s_tick  = 0;
}

void status_led_set_link(bool connected)
{
    s_link_up = connected;
}

static bool s_battery_low;

void status_led_set_battery_low(bool low)
{
    s_battery_low = low;
}

void status_led_tick(void)
{
    if (!s_strip) {
        return;
    }

    const led_style_t *st = &s_styles[s_state];
    float scale = 1.0f;

    switch (st->anim) {
    case ANIM_OFF:
        led_strip_clear(s_strip);
        s_tick++;
        return;
    case ANIM_SOLID:
        scale = 1.0f;
        break;
    case ANIM_PULSE:
        scale = ((s_tick / 5) % 2) ? 1.0f : 0.15f;
        break;
    case ANIM_BREATHE:
        /* ~3 s period at a 20 Hz tick. */
        scale = 0.15f + 0.85f * (0.5f + 0.5f * sinf(s_tick * 0.105f));
        break;
    }

    uint8_t r = (uint8_t)(st->r * scale);
    uint8_t g = (uint8_t)(st->g * scale);
    uint8_t b = (uint8_t)(st->b * scale);

    /* Link-down overlay: a brief magenta blink every 2 s. The exercise itself
     * is unaffected — acquisition, repetition detection and haptics all keep
     * running — so this is purely so the patient is not left guessing. */
    if (!s_link_up && s_state == FW_STATE_OPERATIONAL) {
        if ((s_tick % 40) < 4) {
            r = 255; g = 0; b = 255;
        }
    }

    /* Low-battery overlay: an amber double-blink every 2 s [PRD §5.7]. Shown
     * in every state except FAULT, where red solid is the more urgent
     * message and should not be interrupted. */
    if (s_battery_low && s_state != FW_STATE_FAULT) {
        const uint32_t p = s_tick % 40;
        if (p < 3 || (p >= 6 && p < 9)) {
            r = 255; g = 160; b = 0;
        }
    }

    led_strip_set_pixel(s_strip, 0, r, g, b);
    led_strip_refresh(s_strip);
    s_tick++;
}
