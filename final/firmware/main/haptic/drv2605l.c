/*
 * drv2605l.c — DRV2605L configuration and PWM drive
 *
 * Configuration sequence (I2C, once, at boot):
 *   1. Leave standby                      MODE      = 0x00
 *   2. Select the ERM library + actuator  FEEDBACK  = ERM
 *   3. Rated voltage and overdrive clamp  from the actuator datasheet
 *   4. Auto-calibrate                     MODE      = 0x07, GO = 1
 *   5. Switch to PWM input                MODE      = 0x03, CONTROL3 PWM
 *
 * After step 5 the bus is idle for the rest of the session.
 */

#include <string.h>
#include <math.h>
#include "driver/i2c_master.h"
#include "driver/ledc.h"
#include "driver/gpio.h"
#include "esp_log.h"
#include "esp_check.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "drv2605l.h"
#include "rehab_config.h"

static const char *TAG = "drv2605";

/* ── Registers ───────────────────────────────────────────────────────── */
#define REG_STATUS        0x00
#define REG_MODE          0x01
#define REG_RTP           0x02
#define REG_LIBRARY       0x03
#define REG_WAVESEQ1      0x04
#define REG_GO            0x0C
#define REG_RATED_V       0x16
#define REG_CLAMP_V       0x17
#define REG_A_CAL_COMP    0x18
#define REG_A_CAL_BEMF    0x19
#define REG_FEEDBACK      0x1A
#define REG_CONTROL1      0x1B
#define REG_CONTROL2      0x1C
#define REG_CONTROL3      0x1D
#define REG_CONTROL4      0x1E

#define MODE_INTERNAL     0x00
#define MODE_PWM_ANALOG   0x03
#define MODE_AUTOCAL      0x07
#define MODE_STANDBY_BIT  0x40

#define LIBRARY_ERM_A     0x01
#define STATUS_DIAG_BIT   0x08

#define LEDC_TIMER_SEL    LEDC_TIMER_0
#define LEDC_CHANNEL_SEL  LEDC_CHANNEL_0
#define LEDC_MAX_DUTY     ((1 << HAPTIC_PWM_RES_BITS) - 1)

static i2c_master_bus_handle_t s_bus;
static i2c_master_dev_handle_t s_dev;
static bool  s_ready;
static bool  s_muted;
static float s_level;

/* ── I2C helpers ─────────────────────────────────────────────────────── */

static esp_err_t reg_write(uint8_t reg, uint8_t val)
{
    const uint8_t buf[2] = { reg, val };
    return i2c_master_transmit(s_dev, buf, sizeof(buf), 100);
}

static esp_err_t reg_read(uint8_t reg, uint8_t *val)
{
    return i2c_master_transmit_receive(s_dev, &reg, 1, val, 1, 100);
}

/* Write then read back. Configuration that silently failed is worse than
 * configuration that failed loudly. */
static esp_err_t reg_write_verified(uint8_t reg, uint8_t val)
{
    ESP_RETURN_ON_ERROR(reg_write(reg, val), TAG, "write 0x%02X", reg);

    uint8_t got = 0;
    ESP_RETURN_ON_ERROR(reg_read(reg, &got), TAG, "readback 0x%02X", reg);

    if (got != val) {
        ESP_LOGE(TAG, "register 0x%02X reads 0x%02X, wrote 0x%02X",
                 reg, got, val);
        return ESP_ERR_INVALID_RESPONSE;
    }
    return ESP_OK;
}

/* ── Bus recovery ────────────────────────────────────────────────────── */

/* Clock SCL nine times with SDA released, then a STOP. Frees a slave that is
 * holding SDA low mid-byte, which is the failure mode a glitch on a sleeve
 * cable actually produces. */
static void i2c_bus_recover(void)
{
    ESP_LOGW(TAG, "attempting I2C bus recovery");

    gpio_config_t io = {
        .pin_bit_mask = (1ULL << PIN_I2C_SCL) | (1ULL << PIN_I2C_SDA),
        .mode         = GPIO_MODE_OUTPUT_OD,
        .pull_up_en   = GPIO_PULLUP_ENABLE,
    };
    gpio_config(&io);

    gpio_set_level(PIN_I2C_SDA, 1);
    for (int i = 0; i < 9; i++) {
        gpio_set_level(PIN_I2C_SCL, 0);
        esp_rom_delay_us(5);
        gpio_set_level(PIN_I2C_SCL, 1);
        esp_rom_delay_us(5);
    }
    /* STOP: SDA low->high while SCL is high. */
    gpio_set_level(PIN_I2C_SDA, 0);
    esp_rom_delay_us(5);
    gpio_set_level(PIN_I2C_SCL, 1);
    esp_rom_delay_us(5);
    gpio_set_level(PIN_I2C_SDA, 1);
    esp_rom_delay_us(5);
}

/* ── PWM ─────────────────────────────────────────────────────────────── */

static esp_err_t pwm_init(void)
{
    ledc_timer_config_t timer = {
        .speed_mode      = LEDC_LOW_SPEED_MODE,
        .timer_num       = LEDC_TIMER_SEL,
        .duty_resolution = HAPTIC_PWM_RES_BITS,
        .freq_hz         = HAPTIC_PWM_HZ,
        .clk_cfg         = LEDC_AUTO_CLK,
    };
    ESP_RETURN_ON_ERROR(ledc_timer_config(&timer), TAG, "ledc timer");

    ledc_channel_config_t chan = {
        .gpio_num   = PIN_HAPTIC_PWM,
        .speed_mode = LEDC_LOW_SPEED_MODE,
        .channel    = LEDC_CHANNEL_SEL,
        .timer_sel  = LEDC_TIMER_SEL,
        .duty       = HAPTIC_PWM_ZERO_DUTY,
        .hpoint     = 0,
    };
    ESP_RETURN_ON_ERROR(ledc_channel_config(&chan), TAG, "ledc channel");

    return ESP_OK;
}

void drv2605l_set_level(float level)
{
    if (!s_ready || s_muted) {
        level = 0.0f;
    }
    if (level < 0.0f) level = 0.0f;
    if (level > 1.0f) level = 1.0f;
    s_level = level;

    /* In PWM input mode 50 % duty is zero drive; deviation sets amplitude.
     * Driving above the midpoint keeps the direction consistent, which for an
     * ERM simply means it always spins the same way. */
    const uint32_t span = LEDC_MAX_DUTY - HAPTIC_PWM_ZERO_DUTY;
    const uint32_t duty = HAPTIC_PWM_ZERO_DUTY + (uint32_t)(level * span);

    ledc_set_duty(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_SEL, duty);
    ledc_update_duty(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_SEL);
}

void drv2605l_mute(void)
{
    s_muted = true;
    ledc_set_duty(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_SEL, HAPTIC_PWM_ZERO_DUTY);
    ledc_update_duty(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_SEL);
    gpio_set_level(PIN_HAPTIC_EN, 0);
}

void drv2605l_unmute(void)
{
    s_muted = false;
    gpio_set_level(PIN_HAPTIC_EN, 1);
}

bool drv2605l_is_ready(void)
{
    return s_ready;
}

/* ── Init ────────────────────────────────────────────────────────────── */

/* The datasheet encodes rated voltage and overdrive clamp as 8-bit values
 * scaled against a reference. These are the open-loop ERM forms. */
static uint8_t encode_rated_voltage(float volts)
{
    const float v = volts / (21.32e-3f * 5.44f);   /* ERM, open loop */
    return (uint8_t)fminf(fmaxf(v, 0.0f), 255.0f);
}

static uint8_t encode_clamp_voltage(float volts)
{
    const float v = (volts * 1e3f) / 21.22f;
    return (uint8_t)fminf(fmaxf(v, 0.0f), 255.0f);
}

static esp_err_t configure_device(void)
{
    uint8_t status = 0;

    /* Out of standby. */
    ESP_RETURN_ON_ERROR(reg_write(REG_MODE, MODE_INTERNAL), TAG, "exit standby");
    vTaskDelay(pdMS_TO_TICKS(5));

    ESP_RETURN_ON_ERROR(reg_read(REG_STATUS, &status), TAG, "status");
    ESP_LOGI(TAG, "device id 0x%02X", (status >> 5) & 0x07);

    /* ERM drive, open loop. N_ERM_LRA = 0 selects ERM; the rest of FEEDBACK
     * keeps Bosch's defaults for brake factor and loop gain.
     *
     * Switching to an LRA later would be this one bit plus a re-calibration,
     * but no LRA is planned for this build. */
    uint8_t feedback = 0;
    ESP_RETURN_ON_ERROR(reg_read(REG_FEEDBACK, &feedback), TAG, "feedback read");
    feedback &= ~0x80;
    ESP_RETURN_ON_ERROR(reg_write_verified(REG_FEEDBACK, feedback), TAG, "feedback");

    ESP_RETURN_ON_ERROR(reg_write_verified(REG_LIBRARY, LIBRARY_ERM_A),
                        TAG, "library");

    ESP_RETURN_ON_ERROR(
        reg_write_verified(REG_RATED_V, encode_rated_voltage(ERM_RATED_VOLTAGE_V)),
        TAG, "rated voltage");
    ESP_RETURN_ON_ERROR(
        reg_write_verified(REG_CLAMP_V, encode_clamp_voltage(ERM_OVERDRIVE_CLAMP_V)),
        TAG, "clamp voltage");

    /* ── Auto-calibration ──────────────────────────────────────────────
     * The device measures the actuator and writes back compensation and
     * back-EMF coefficients. A set diagnostic bit afterwards means the
     * actuator is disconnected or the voltages above are wrong for it —
     * either way it must fail the self-test rather than be ignored. */
    ESP_RETURN_ON_ERROR(reg_write(REG_MODE, MODE_AUTOCAL), TAG, "autocal mode");
    ESP_RETURN_ON_ERROR(reg_write(REG_GO, 0x01), TAG, "autocal go");

    for (int i = 0; i < 100; i++) {
        uint8_t go = 1;
        vTaskDelay(pdMS_TO_TICKS(10));
        if (reg_read(REG_GO, &go) == ESP_OK && (go & 0x01) == 0) {
            break;
        }
    }

    ESP_RETURN_ON_ERROR(reg_read(REG_STATUS, &status), TAG, "autocal status");
    if (status & STATUS_DIAG_BIT) {
        ESP_LOGE(TAG, "auto-calibration failed (status 0x%02X). Check the "
                      "actuator is connected and that ERM_RATED_VOLTAGE_V / "
                      "ERM_OVERDRIVE_CLAMP_V match the datasheet.", status);
        return ESP_ERR_INVALID_RESPONSE;
    }

    uint8_t comp = 0, bemf = 0;
    reg_read(REG_A_CAL_COMP, &comp);
    reg_read(REG_A_CAL_BEMF, &bemf);
    ESP_LOGI(TAG, "auto-calibration ok: comp 0x%02X, back-EMF 0x%02X", comp, bemf);

    /* ── Switch to PWM input and stop touching the bus ─────────────────── */
    uint8_t ctrl3 = 0;
    ESP_RETURN_ON_ERROR(reg_read(REG_CONTROL3, &ctrl3), TAG, "control3 read");
    ctrl3 &= ~0x02;      /* N_PWM_ANALOG = 0 -> PWM input, not analog */
    ESP_RETURN_ON_ERROR(reg_write_verified(REG_CONTROL3, ctrl3), TAG, "control3");

    ESP_RETURN_ON_ERROR(reg_write_verified(REG_MODE, MODE_PWM_ANALOG),
                        TAG, "pwm mode");

    ESP_LOGI(TAG, "configured for PWM input — I2C idle from here");
    return ESP_OK;
}

esp_err_t drv2605l_init(void)
{
    s_ready = false;

    gpio_config_t en = {
        .pin_bit_mask = (1ULL << PIN_HAPTIC_EN),
        .mode         = GPIO_MODE_OUTPUT,
    };
    ESP_RETURN_ON_ERROR(gpio_config(&en), TAG, "EN pin");
    gpio_set_level(PIN_HAPTIC_EN, 1);
    vTaskDelay(pdMS_TO_TICKS(5));

    ESP_RETURN_ON_ERROR(pwm_init(), TAG, "pwm");

    i2c_master_bus_config_t bus_cfg = {
        .i2c_port          = I2C_NUM_0,
        .sda_io_num        = PIN_I2C_SDA,
        .scl_io_num        = PIN_I2C_SCL,
        .clk_source        = I2C_CLK_SRC_DEFAULT,
        .glitch_ignore_cnt = 7,
        .flags.enable_internal_pullup = true,
    };
    ESP_RETURN_ON_ERROR(i2c_new_master_bus(&bus_cfg, &s_bus), TAG, "i2c bus");

    i2c_device_config_t dev_cfg = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address  = DRV2605L_I2C_ADDR,
        .scl_speed_hz    = I2C_HZ,
    };
    ESP_RETURN_ON_ERROR(i2c_master_bus_add_device(s_bus, &dev_cfg, &s_dev),
                        TAG, "i2c device");

    esp_err_t err = configure_device();

    if (err != ESP_OK) {
        /* One recovery attempt, then give up. Two failures is a wiring
         * problem, not a transient. */
        i2c_bus_recover();
        vTaskDelay(pdMS_TO_TICKS(10));
        err = configure_device();
    }

    if (err != ESP_OK) {
        ESP_LOGE(TAG, "haptic driver unavailable");
        drv2605l_mute();
        return err;
    }

    s_ready = true;
    s_muted = false;
    drv2605l_set_level(0.0f);
    return ESP_OK;
}

esp_err_t drv2605l_verify(void)
{
    if (!s_ready) {
        return ESP_ERR_INVALID_STATE;
    }
    uint8_t mode = 0;
    ESP_RETURN_ON_ERROR(reg_read(REG_MODE, &mode), TAG, "verify read");
    if ((mode & 0x07) != MODE_PWM_ANALOG) {
        ESP_LOGE(TAG, "MODE drifted to 0x%02X — device may have reset", mode);
        return ESP_ERR_INVALID_RESPONSE;
    }
    return ESP_OK;
}
