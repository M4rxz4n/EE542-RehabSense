/*
 * emg_driver.h — acquisition hardware abstraction
 *
 * The prototype runs on the ESP32-S3's internal ADC; the custom PCB will run
 * on a TI ADS131M02 over SPI. Both normalise to a signed, zero-centred value,
 * so nothing above this interface knows which converter is underneath.
 *
 * Swapping backends is one assignment in main.c.
 */

#ifndef EMG_DRIVER_H
#define EMG_DRIVER_H

#include "esp_err.h"
#include "freertos/FreeRTOS.h"
#include "rehab_types.h"

typedef struct {
    uint32_t sample_rate_hz;      /* per channel */
    uint32_t dma_frame_samples;   /* per channel, per callback */
} emg_cfg_t;

typedef struct {
    bool     ok;
    int32_t  dc_offset[EMG_N_CHANNELS];   /* raw counts at rest */
    float    noise_rms[EMG_N_CHANNELS];   /* raw counts */
    uint32_t samples_seen;
    const char *detail;                   /* NULL when ok */
} emg_selftest_t;

typedef struct {
    const char *name;

    esp_err_t (*init)(const emg_cfg_t *cfg);
    esp_err_t (*start)(void);
    esp_err_t (*stop)(void);

    /* Blocking read of up to `max` frames. Returns the count actually read. */
    size_t    (*read)(emg_frame_t *out, size_t max, TickType_t wait);

    /* Acquire briefly with the patient at rest and report what was seen.
     * Must fail loudly rather than returning plausible zeros. */
    esp_err_t (*self_test)(emg_selftest_t *result);

    /* Full-scale magnitude in the driver's normalised units, used by the DSP
     * chain to decide what counts as clipping. */
    int32_t   (*full_scale)(void);
} emg_driver_t;

extern const emg_driver_t emg_driver_esp32_adc;    /* prototype */
extern const emg_driver_t emg_driver_ads131m02;    /* final PCB — stub for now */

#endif /* EMG_DRIVER_H */
