/*
 * bmi270.h — dual BMI270 over SPI
 *
 * Board setup on each SparkFun Qwiic BMI270 breakout:
 *   - ADR jumper FULLY OPEN. This is what selects SPI; cutting it to GND
 *     selects I2C address 0x69 instead, which is a different thing.
 *   - I2C pull-up jumpers cut on both boards.
 *   - Header mapping: SCL->SCK, SDA->PICO, ADR->POCI, CS->CS.
 */

#ifndef BMI270_H
#define BMI270_H

#include "esp_err.h"
#include "rehab_types.h"

typedef enum {
    IMU_UPPER_ARM = 0,
    IMU_FOREARM   = 1,
    IMU_COUNT
} imu_id_t;

/* Brings up the shared SPI2 bus and both devices. */
esp_err_t bmi270_init_all(void);

/* Latest sample. Returns ESP_ERR_INVALID_STATE if the device has stopped
 * producing new data rather than handing back a stale sample silently. */
esp_err_t bmi270_read(imu_id_t id, imu_sample_t *out);

/* Confirms chip ID, config upload and that both devices report plausible
 * gravity while static. */
esp_err_t bmi270_self_test(char *detail, size_t detail_len);

#endif /* BMI270_H */
