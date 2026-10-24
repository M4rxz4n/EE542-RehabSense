/*
 * bmi270.c — dual BMI270 over SPI2
 *
 * The single most common bring-up failure with this part: it ships inert.
 * A BMI270 that reports the correct chip ID (0x24) but returns nothing but
 * zeros has almost always had its ~8 kB configuration blob upload fail or
 * skipped. INTERNAL_STATUS must read 0x01 afterwards, and this driver treats
 * anything else as a hard error rather than carrying on.
 *
 * The second gotcha: the part powers up in I2C mode regardless of how the
 * board jumpers are set. A dummy read of register 0x00, whose CSB rising edge
 * latches SPI mode, is mandatory before anything else works.
 */

#include <string.h>
#include <math.h>
#include <stdio.h>
#include "driver/spi_master.h"
#include "driver/gpio.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "esp_check.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "bmi270.h"
#include "bmi270_config_blob.h"
#include "rehab_config.h"

static const char *TAG = "bmi270";

/* ── Registers ───────────────────────────────────────────────────────── */
#define REG_CHIP_ID         0x00
#define REG_ERR             0x02
#define REG_STATUS          0x03
#define REG_ACC_DATA        0x0C   /* acc X/Y/Z then gyr X/Y/Z, 12 bytes */
#define REG_INTERNAL_STATUS 0x21
#define REG_ACC_CONF        0x40
#define REG_ACC_RANGE       0x41
#define REG_GYR_CONF        0x42
#define REG_GYR_RANGE       0x43
#define REG_INIT_CTRL       0x59
#define REG_INIT_ADDR_0     0x5B
#define REG_INIT_ADDR_1     0x5C
#define REG_INIT_DATA       0x5E
#define REG_PWR_CONF        0x7C
#define REG_PWR_CTRL        0x7D
#define REG_CMD             0x7E

#define BMI270_CHIP_ID      0x24
#define INIT_STATUS_OK      0x01

/* ── Configuration values ────────────────────────────────────────────── */
/* ACC_CONF: filter_perf=1, bwp=normal(0x02), odr=100 Hz(0x08) */
#define ACC_CONF_VAL        0xA8
#define ACC_RANGE_4G        0x01
/* GYR_CONF: filter_perf=1, noise_perf=1, bwp=normal(0x02), odr=100 Hz(0x08) */
#define GYR_CONF_VAL        0xE8
#define GYR_RANGE_500DPS    0x02
/* PWR_CTRL: temp | acc | gyr enabled */
#define PWR_CTRL_VAL        0x0E

/* Scale factors for the ranges above, 16-bit signed. */
#define ACC_LSB_PER_G       (32768.0f / 4.0f)
#define GYR_LSB_PER_DPS     (32768.0f / 500.0f)

/* Chunk size for the config upload. Must be even — INIT_ADDR counts 16-bit
 * words, not bytes. */
#define INIT_CHUNK          128

typedef struct {
    spi_device_handle_t dev;
    int                 cs_pin;
    uint64_t            last_t_us;
    bool                ready;
} imu_dev_t;

static imu_dev_t s_imu[IMU_COUNT];
static bool      s_bus_ready;

/* ──────────────────────────────────────────────────────────────────────
 * Low-level SPI
 *
 * BMI270 SPI reads return one dummy byte before the real data, so every read
 * transfers len+1 bytes and discards the first.
 * ────────────────────────────────────────────────────────────────────── */

static esp_err_t bmi_read(imu_dev_t *d, uint8_t reg, uint8_t *buf, size_t len)
{
    uint8_t tx[1 + 1 + 32] = { 0 };
    uint8_t rx[1 + 1 + 32] = { 0 };

    if (len > 32) {
        return ESP_ERR_INVALID_SIZE;
    }

    tx[0] = reg | 0x80;                 /* read */

    spi_transaction_t t = {
        .length    = (2 + len) * 8,
        .tx_buffer = tx,
        .rx_buffer = rx,
    };
    ESP_RETURN_ON_ERROR(spi_device_polling_transmit(d->dev, &t), TAG, "spi read");

    memcpy(buf, &rx[2], len);           /* [0] echo, [1] dummy */
    return ESP_OK;
}

static esp_err_t bmi_write(imu_dev_t *d, uint8_t reg, uint8_t val)
{
    uint8_t tx[2] = { reg & 0x7F, val };
    spi_transaction_t t = {
        .length    = 16,
        .tx_buffer = tx,
    };
    return spi_device_polling_transmit(d->dev, &t);
}

static esp_err_t bmi_write_burst(imu_dev_t *d, uint8_t reg,
                                 const uint8_t *data, size_t len)
{
    static uint8_t tx[1 + INIT_CHUNK];
    if (len > INIT_CHUNK) {
        return ESP_ERR_INVALID_SIZE;
    }
    tx[0] = reg & 0x7F;
    memcpy(&tx[1], data, len);

    spi_transaction_t t = {
        .length    = (1 + len) * 8,
        .tx_buffer = tx,
    };
    return spi_device_polling_transmit(d->dev, &t);
}

/* ──────────────────────────────────────────────────────────────────────
 * Config blob upload
 * ────────────────────────────────────────────────────────────────────── */

static esp_err_t upload_config(imu_dev_t *d)
{
    if (bmi270_config_file == NULL || bmi270_config_file_len == 0) {
        ESP_LOGE(TAG, "config blob is empty — see tools/fetch_bmi270_blob.py");
        return ESP_ERR_INVALID_STATE;
    }

    /* Advanced power save off before the upload. */
    ESP_RETURN_ON_ERROR(bmi_write(d, REG_PWR_CONF, 0x00), TAG, "PWR_CONF");
    esp_rom_delay_us(500);

    /* Prepare for init. */
    ESP_RETURN_ON_ERROR(bmi_write(d, REG_INIT_CTRL, 0x00), TAG, "INIT_CTRL lo");

    for (size_t off = 0; off < bmi270_config_file_len; off += INIT_CHUNK) {
        const size_t chunk = (bmi270_config_file_len - off < INIT_CHUNK)
                           ? (bmi270_config_file_len - off) : INIT_CHUNK;

        /* INIT_ADDR is a 16-bit word index split across two registers:
         * ADDR_0 holds bits [3:0], ADDR_1 holds bits [11:4]. */
        const uint16_t word_idx = off / 2;
        ESP_RETURN_ON_ERROR(bmi_write(d, REG_INIT_ADDR_0, word_idx & 0x0F),
                            TAG, "INIT_ADDR_0");
        ESP_RETURN_ON_ERROR(bmi_write(d, REG_INIT_ADDR_1, (word_idx >> 4) & 0xFF),
                            TAG, "INIT_ADDR_1");
        ESP_RETURN_ON_ERROR(
            bmi_write_burst(d, REG_INIT_DATA, &bmi270_config_file[off], chunk),
            TAG, "INIT_DATA");
    }

    /* Signal end of init and give the device time to digest it. */
    ESP_RETURN_ON_ERROR(bmi_write(d, REG_INIT_CTRL, 0x01), TAG, "INIT_CTRL hi");
    vTaskDelay(pdMS_TO_TICKS(25));

    uint8_t status = 0;
    ESP_RETURN_ON_ERROR(bmi_read(d, REG_INTERNAL_STATUS, &status, 1),
                        TAG, "INTERNAL_STATUS");

    if ((status & 0x0F) != INIT_STATUS_OK) {
        ESP_LOGE(TAG, "config upload failed: INTERNAL_STATUS = 0x%02X "
                      "(expected 0x01). The device will return zeros.", status);
        return ESP_ERR_INVALID_RESPONSE;
    }

    return ESP_OK;
}

/* ────────────────────────────────────────────────────────────────────── */

static esp_err_t init_one(imu_dev_t *d, const char *label)
{
    uint8_t id = 0;

    /* Latch SPI mode: the part boots in I2C regardless of jumpers, and the
     * CSB rising edge at the end of this throwaway read is what switches it.
     * The value read here is meaningless by design. */
    bmi_read(d, REG_CHIP_ID, &id, 1);
    esp_rom_delay_us(500);

    ESP_RETURN_ON_ERROR(bmi_read(d, REG_CHIP_ID, &id, 1), TAG, "chip id");
    if (id != BMI270_CHIP_ID) {
        ESP_LOGE(TAG, "%s: chip ID 0x%02X, expected 0x%02X — check CS wiring "
                      "and that the ADR jumper is fully open", label, id,
                 BMI270_CHIP_ID);
        return ESP_ERR_NOT_FOUND;
    }

    ESP_RETURN_ON_ERROR(upload_config(d), TAG, "config upload");

    ESP_RETURN_ON_ERROR(bmi_write(d, REG_ACC_CONF,  ACC_CONF_VAL),    TAG, "ACC_CONF");
    ESP_RETURN_ON_ERROR(bmi_write(d, REG_ACC_RANGE, ACC_RANGE_4G),    TAG, "ACC_RANGE");
    ESP_RETURN_ON_ERROR(bmi_write(d, REG_GYR_CONF,  GYR_CONF_VAL),    TAG, "GYR_CONF");
    ESP_RETURN_ON_ERROR(bmi_write(d, REG_GYR_RANGE, GYR_RANGE_500DPS),TAG, "GYR_RANGE");
    ESP_RETURN_ON_ERROR(bmi_write(d, REG_PWR_CTRL,  PWR_CTRL_VAL),    TAG, "PWR_CTRL");

    vTaskDelay(pdMS_TO_TICKS(10));

    uint8_t err = 0;
    bmi_read(d, REG_ERR, &err, 1);
    if (err & 0x01) {
        ESP_LOGE(TAG, "%s: ERR_REG fatal bit set (0x%02X)", label, err);
        return ESP_FAIL;
    }

    d->ready = true;
    ESP_LOGI(TAG, "%s up: ±4 g, ±500 dps, %d Hz", label, IMU_SAMPLE_RATE_HZ);
    return ESP_OK;
}

esp_err_t bmi270_init_all(void)
{
    if (!s_bus_ready) {
        spi_bus_config_t bus = {
            .mosi_io_num     = PIN_SPI_MOSI,
            .miso_io_num     = PIN_SPI_MISO,
            .sclk_io_num     = PIN_SPI_SCK,
            .quadwp_io_num   = -1,
            .quadhd_io_num   = -1,
            .max_transfer_sz = INIT_CHUNK + 8,
        };
        ESP_RETURN_ON_ERROR(spi_bus_initialize(SPI2_HOST, &bus, SPI_DMA_CH_AUTO),
                            TAG, "spi bus init");
        s_bus_ready = true;
    }

    const int cs_pins[IMU_COUNT] = { PIN_CS_IMU_UPPER, PIN_CS_IMU_FORE };
    const char *labels[IMU_COUNT] = { "upper-arm", "forearm" };

    for (int i = 0; i < IMU_COUNT; i++) {
        spi_device_interface_config_t dev = {
            .command_bits   = 0,
            .address_bits   = 0,
            .mode           = 0,            /* BMI270 supports mode 0 and 3 */
            .clock_speed_hz = SPI_IMU_HZ,
            .spics_io_num   = cs_pins[i],
            .queue_size     = 2,
        };
        ESP_RETURN_ON_ERROR(spi_bus_add_device(SPI2_HOST, &dev, &s_imu[i].dev),
                            TAG, "spi add device");
        s_imu[i].cs_pin = cs_pins[i];

        ESP_RETURN_ON_ERROR(init_one(&s_imu[i], labels[i]), TAG, "init %s",
                            labels[i]);
    }

    return ESP_OK;
}

esp_err_t bmi270_read(imu_id_t id, imu_sample_t *out)
{
    if (id >= IMU_COUNT || !s_imu[id].ready) {
        return ESP_ERR_INVALID_STATE;
    }

    uint8_t buf[12];
    ESP_RETURN_ON_ERROR(bmi_read(&s_imu[id], REG_ACC_DATA, buf, sizeof(buf)),
                        TAG, "data read");

    int16_t raw[6];
    for (int i = 0; i < 6; i++) {
        raw[i] = (int16_t)((uint16_t)buf[2 * i] | ((uint16_t)buf[2 * i + 1] << 8));
    }

    for (int i = 0; i < 3; i++) {
        out->accel[i] = raw[i]     / ACC_LSB_PER_G;
        out->gyro[i]  = raw[3 + i] / GYR_LSB_PER_DPS;
    }
    out->t_us = esp_timer_get_time();
    s_imu[id].last_t_us = out->t_us;

    return ESP_OK;
}

esp_err_t bmi270_self_test(char *detail, size_t detail_len)
{
    const char *labels[IMU_COUNT] = { "upper-arm", "forearm" };

    for (int i = 0; i < IMU_COUNT; i++) {
        if (!s_imu[i].ready) {
            snprintf(detail, detail_len, "%s IMU did not initialise", labels[i]);
            return ESP_ERR_INVALID_STATE;
        }

        /* Average a few samples: a single read can land mid-update. */
        float mag_sum = 0.0f;
        float gyro_sum = 0.0f;
        const int n = 10;

        for (int s = 0; s < n; s++) {
            imu_sample_t smp;
            ESP_RETURN_ON_ERROR(bmi270_read((imu_id_t)i, &smp), TAG, "self-test read");
            mag_sum += sqrtf(smp.accel[0] * smp.accel[0] +
                             smp.accel[1] * smp.accel[1] +
                             smp.accel[2] * smp.accel[2]);
            gyro_sum += fabsf(smp.gyro[0]) + fabsf(smp.gyro[1]) + fabsf(smp.gyro[2]);
            vTaskDelay(pdMS_TO_TICKS(IMU_PERIOD_MS));
        }

        const float mag = mag_sum / n;

        /* Gravity must read within 10 % of 1 g while static. Exactly 0.00 is
         * the classic signature of a skipped config upload. */
        if (mag < 0.90f || mag > 1.10f) {
            snprintf(detail, detail_len,
                     "%s IMU reads %.2f g at rest (expected ~1.00). %s",
                     labels[i], mag,
                     (mag < 0.05f) ? "Zeros usually mean the config blob upload failed."
                                   : "Check the board is still.");
            return ESP_FAIL;
        }

        ESP_LOGI(TAG, "%s self-test ok: |a| = %.3f g, gyro sum %.2f dps",
                 labels[i], mag, gyro_sum / n);
    }

    snprintf(detail, detail_len, "both IMUs ok");
    return ESP_OK;
}
