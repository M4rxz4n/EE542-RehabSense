/*
 * bmi270_config_blob.h — the BMI270's configuration firmware
 *
 * The BMI270 ships inert. Until this ~8 kB blob is uploaded it will answer
 * its chip ID correctly and then return nothing but zeros forever.
 *
 * The blob is Bosch's, not ours, so it is not checked in here. Generate it:
 *
 *     python tools/fetch_bmi270_blob.py
 *
 * which writes main/imu/bmi270_config_blob.c from the Bosch BMI270-Sensor-API
 * repository. Run it once after cloning; the build fails with a clear message
 * until you do.
 */

#ifndef BMI270_CONFIG_BLOB_H
#define BMI270_CONFIG_BLOB_H

#include <stdint.h>
#include <stddef.h>

extern const uint8_t *bmi270_config_file;
extern const size_t   bmi270_config_file_len;

#endif /* BMI270_CONFIG_BLOB_H */
