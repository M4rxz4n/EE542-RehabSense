/*
 * emg_ads131m02.c — ADS131M02 backend (Mikroe ADC 15 Click)
 *
 * STUB. The October 29 prototype runs on the internal ADC; this backend is for
 * the custom PCB. It exists now so the interface boundary is real rather than
 * aspirational — when the Click arrives, filling this in is the only change
 * above the driver layer.
 *
 * What it will need:
 *   - SPI at up to 25 MHz, SPI mode 1 (CPOL=0, CPHA=1)
 *   - DRDY on an interrupt pin, since the ADC sets the pace, not a timer
 *   - 24-bit two's-complement words, 3 bytes per channel per frame
 *   - CRC on the response frame (the part computes one; check it)
 *   - Gain and OSR configured for a 2 kSPS output rate
 *
 * The device is differential, so its output is already zero-centred: no bias
 * subtraction, unlike the internal ADC path.
 */

#include <string.h>
#include "esp_log.h"
#include "emg_driver.h"

static const char *TAG = "emg_ads131";

static esp_err_t ads_init(const emg_cfg_t *cfg)
{
    (void)cfg;
    ESP_LOGE(TAG, "ADS131M02 backend not implemented — "
                  "the prototype uses emg_driver_esp32_adc");
    return ESP_ERR_NOT_SUPPORTED;
}

static esp_err_t ads_start(void)                 { return ESP_ERR_NOT_SUPPORTED; }
static esp_err_t ads_stop(void)                  { return ESP_ERR_NOT_SUPPORTED; }

static size_t ads_read(emg_frame_t *out, size_t max, TickType_t wait)
{
    (void)out; (void)max; (void)wait;
    return 0;
}

static esp_err_t ads_self_test(emg_selftest_t *result)
{
    memset(result, 0, sizeof(*result));
    result->ok     = false;
    result->detail = "ADS131M02 backend not implemented";
    return ESP_ERR_NOT_SUPPORTED;
}

static int32_t ads_full_scale(void)
{
    return (1 << 23) - 1;   /* 24-bit signed */
}

const emg_driver_t emg_driver_ads131m02 = {
    .name       = "ads131m02",
    .init       = ads_init,
    .start      = ads_start,
    .stop       = ads_stop,
    .read       = ads_read,
    .self_test  = ads_self_test,
    .full_scale = ads_full_scale,
};
