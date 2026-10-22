/*
 * status_led.h — on-board WS2812 state indicator
 *
 * This is the only output the patient has before BLE connects, which is
 * precisely the moment the phone cannot tell them anything.
 *
 * GPIO38 on DevKitC-1 v1.1. On v1.0 it is GPIO48 — change PIN_STATUS_LED in
 * rehab_config.h. If neither blinks, you have the other revision.
 */

#ifndef STATUS_LED_H
#define STATUS_LED_H

#include "esp_err.h"
#include "rehab_types.h"

esp_err_t status_led_init(void);

/* Colour follows firmware state. */
void status_led_set_state(fw_state_t state);

/* Overlays a magenta blink on the current colour while the link is down, so
 * the patient knows without the exercise changing. */
void status_led_set_link(bool connected);

/* Call from housekeeping at ~20 Hz to drive breathing and blink animation. */
void status_led_tick(void);

#endif /* STATUS_LED_H */
