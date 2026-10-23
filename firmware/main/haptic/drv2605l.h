/*
 * drv2605l.h — haptic driver, I2C config at boot and PWM drive after
 *
 * The DRV2605L needs I2C to leave standby, select ERM drive and run
 * auto-calibration. Those writes happen once, in STANDBY, with the arm at
 * rest. The mode register is then set to PWM input and the bus goes silent:
 * no I2C transaction occurs while the patient is moving, which is where
 * interference would matter.
 *
 * Actuator: Adafruit 1201 ERM disc.
 */

#ifndef DRV2605L_H
#define DRV2605L_H

#include "esp_err.h"
#include <stdbool.h>
#include <stdint.h>

/* Brings up I2C, configures the device, runs auto-calibration, then switches
 * to PWM input mode. After this returns the I2C bus is not used again. */
esp_err_t drv2605l_init(void);

/* Set drive level, 0.0 (off) to 1.0 (full). In PWM input mode 50 % duty means
 * no drive, so this maps onto deviation from the midpoint. */
void drv2605l_set_level(float level);

/* Cuts drive via the EN pin and disables the LEDC channel. Works with the I2C
 * bus dead, which is the point. */
void drv2605l_mute(void);
void drv2605l_unmute(void);

/* Reads back the mode registers and compares them with what was written.
 * A mismatch means the device fell off the bus during configuration. */
esp_err_t drv2605l_verify(void);

bool drv2605l_is_ready(void);

#endif /* DRV2605L_H */
