/*
 * main.c — RehabSense firmware entry point and task wiring
 *
 * Core 0 runs the NimBLE host and everything comms-adjacent.
 * Core 1 runs acquisition, DSP, fusion and analysis, where radio activity
 * cannot pre-empt it. That separation is the main reason the S3's second core
 * matters here.
 */

#include <string.h>
#include <inttypes.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "esp_task_wdt.h"
#include "esp_psram.h"
#include "esp_adc/adc_oneshot.h"
#include "nvs_flash.h"

#include "rehab_config.h"
#include "rehab_types.h"
#include "emg_driver.h"
#include "emg_dsp.h"
#include "bmi270.h"
#include "fusion.h"
#include "drv2605l.h"
#include "patterns.h"
#include "status_led.h"
#include "rep_cycle.h"
#include "calibration.h"
#include "session_buffer.h"
#include "ble_service.h"
#include "state_machine.h"
#include "config.h"
#include "rehab_time.h"

static const char *TAG = "main";

/* ── Battery ─────────────────────────────────────────────────────────────
 *
 * GPIO7 through a 2:1 divider on ADC1_CH6 [PRD §5.7].
 *
 * ADC1 runs in continuous DMA mode for EMG during a session, and a oneshot
 * read cannot share the unit with it. So the battery is sampled whenever
 * acquisition is NOT running — at boot, in STANDBY and between sets — and the
 * last reading is held during a session.
 *
 * That is sufficient for the rule it serves: "below 15 % the device completes
 * the current set, then stops and saves". The decision is taken at a set
 * boundary, which is exactly when a fresh reading is available.
 * ──────────────────────────────────────────────────────────────────────── */

static adc_oneshot_unit_handle_t s_vbat_adc;
static uint16_t s_vbat_mv;
static uint8_t  s_vbat_pct;
static bool     s_battery_warned;
static bool     s_stop_after_set;

static void battery_init(void)
{
    adc_oneshot_unit_init_cfg_t cfg = { .unit_id = ADC_UNIT_1 };
    if (adc_oneshot_new_unit(&cfg, &s_vbat_adc) != ESP_OK) {
        ESP_LOGW(TAG, "battery ADC unavailable; charge will read unknown");
        s_vbat_adc = NULL;
        return;
    }
    adc_oneshot_chan_cfg_t ch = {
        .atten    = ADC_ATTEN_DB_12,
        .bitwidth = ADC_BITWIDTH_DEFAULT,
    };
    adc_oneshot_config_channel(s_vbat_adc, ADC_CHAN_VBAT, &ch);
}

static void battery_read(uint16_t *mv_out, uint8_t *pct_out)
{
    /* Only safe while continuous mode is idle. During a session the cached
     * value stands. */
    if (s_vbat_adc && sm_state() != FW_STATE_OPERATIONAL) {
        int sum = 0, got = 0;
        for (int i = 0; i < VBAT_SAMPLE_COUNT; i++) {
            int raw = 0;
            if (adc_oneshot_read(s_vbat_adc, ADC_CHAN_VBAT, &raw) == ESP_OK) {
                sum += raw;
                got++;
            }
        }
        if (got > 0) {
            /* 12-bit at 12 dB attenuation spans roughly 0..3100 mV. */
            const int counts = sum / got;
            const int at_pin = (counts * 3100) / 4095;
            s_vbat_mv = (uint16_t)(at_pin * VBAT_DIVIDER_RATIO);

            int pct = ((int)s_vbat_mv - VBAT_EMPTY_MV) * 100 /
                      (VBAT_FULL_MV - VBAT_EMPTY_MV);
            if (pct < 0)   pct = 0;
            if (pct > 100) pct = 100;
            s_vbat_pct = (uint8_t)pct;

            if (s_vbat_pct >= VBAT_LOW_PCT) {
                s_battery_warned = false;   /* re-arm after a charge */
                status_led_set_battery_low(false);
            }
        }
    }
    if (mv_out)  *mv_out  = s_vbat_mv;
    if (pct_out) *pct_out = s_vbat_pct;
}

/* Backend selection. Swapping to the ADS131M02 on the custom PCB is this one
 * line — nothing above the driver interface changes. */
static const emg_driver_t *s_emg_drv = &emg_driver_esp32_adc;

extern void sm_publish_inputs(const emg_features_t *e, const fusion_out_t *m);
extern void sm_selftest_passed(void);

/* Shared state between the sensor tasks, double-buffered rather than locked:
 * the analysis task reads a consistent snapshot without ever blocking
 * acquisition. */
static volatile uint32_t s_pub_index;
static emg_features_t    s_emg_pub[2];
static fusion_out_t      s_motion_pub[2];

static QueueHandle_t s_ble_emg_q;

/* ── EMG DSP task ────────────────────────────────────────────────────── */

static void emg_dsp_task(void *arg)
{
    ESP_ERROR_CHECK(esp_task_wdt_add(NULL));

    static emg_frame_t frames[EMG_DMA_FRAME_SAMPLES];
    static emg_frame_t ble_batch[BLE_EMG_BATCH];
    size_t  batch_n = 0;
    uint32_t seq = 0;

    for (;;) {
        esp_task_wdt_reset();

        const size_t n = s_emg_drv->read(frames, EMG_DMA_FRAME_SAMPLES,
                                         pdMS_TO_TICKS(100));
        if (n == 0) {
            continue;
        }

        seq = session_buffer_push_emg(frames, n);

        for (size_t i = 0; i < n; i++) {
            emg_features_t f;
            if (emg_dsp_push(&frames[i], &f)) {
                const uint32_t slot = (s_pub_index + 1) & 1;
                s_emg_pub[slot] = f;
                s_pub_index = slot;
            }

            /* Batch for BLE. The transmit path never blocks acquisition: a
             * full queue drops the batch and the host backfills it later. */
            ble_batch[batch_n++] = frames[i];
            if (batch_n >= BLE_EMG_BATCH) {
                if (s_ble_emg_q) {
                    xQueueSend(s_ble_emg_q, ble_batch, 0);
                }
                batch_n = 0;
            }
        }
    }
}

/* ── IMU task ────────────────────────────────────────────────────────── */

static void imu_task(void *arg)
{
    ESP_ERROR_CHECK(esp_task_wdt_add(NULL));

    TickType_t last = xTaskGetTickCount();
    uint32_t   consecutive_errors = 0;

    for (;;) {
        esp_task_wdt_reset();
        vTaskDelayUntil(&last, pdMS_TO_TICKS(IMU_PERIOD_MS));

        imu_sample_t upper, fore;
        if (bmi270_read(IMU_UPPER_ARM, &upper) != ESP_OK ||
            bmi270_read(IMU_FOREARM,   &fore)  != ESP_OK) {
            if (++consecutive_errors > 50) {
                sm_fault(FAULT_IMU_UNRESPONSIVE, "IMU stopped responding");
                consecutive_errors = 0;
            }
            continue;
        }
        consecutive_errors = 0;

        fusion_update(&upper, &fore);

        fusion_out_t m;
        fusion_get(&m);
        const uint32_t slot = s_pub_index & 1;
        s_motion_pub[slot] = m;

        session_buffer_push_imu(&upper, &fore);
    }
}

/* ── Analysis task ───────────────────────────────────────────────────── */

static void analysis_task(void *arg)
{
    ESP_ERROR_CHECK(esp_task_wdt_add(NULL));

    TickType_t last = xTaskGetTickCount();
    uint32_t   seq  = 0;

    for (;;) {
        esp_task_wdt_reset();
        vTaskDelayUntil(&last, pdMS_TO_TICKS(ANALYSIS_PERIOD_MS));

        const uint32_t slot = s_pub_index & 1;
        const emg_features_t emg = s_emg_pub[slot];
        const fusion_out_t   mot = s_motion_pub[slot];

        sm_publish_inputs(&emg, &mot);

        const uint64_t now = esp_timer_get_time();
        sm_tick(now);

        /* Feature frames go out at FEATURE_RATE_HZ regardless of state, so a
         * host that connects mid-session sees live values immediately. */
        features_t f = {
            .t_us              = now,
            .elbow_angle_deg   = mot.elbow_angle_deg,
            .upper_arm_dev_deg = mot.upper_arm_dev_deg,
            .rep_state         = 0,
            .sig_flags         = emg.sig_flags,
        };
        for (int i = 0; i < EMG_N_CHANNELS; i++) {
            f.envelope[i] = emg.envelope[i];
            f.mdf[i]      = emg.mdf[i];
        }
        ble_notify_features(&f, seq++);
    }
}

/* ── BLE transmit task ───────────────────────────────────────────────── */

static void ble_tx_task(void *arg)
{
    static emg_frame_t batch[BLE_EMG_BATCH];
    uint32_t seq = 0;

    for (;;) {
        if (xQueueReceive(s_ble_emg_q, batch, portMAX_DELAY) != pdTRUE) {
            continue;
        }
        /* No host subscribed is normal, not an error: a dropped link must not
         * change anything about the exercise. */
        ble_notify_emg(batch, BLE_EMG_BATCH, seq);
        seq += BLE_EMG_BATCH;
    }
}

/* ── Storage ─────────────────────────────────────────────────────────────
 *
 * Serves backfill requests BELOW the live stream in priority, one chunk per
 * pass, so a host catching up after a dropout never stalls real-time data
 * [PRD §5.9]. Idles cheaply when nothing is outstanding.
 * ──────────────────────────────────────────────────────────────────────── */

static void storage_task(void *arg)
{
    for (;;) {
        if (session_buffer_backfill_pending()) {
            session_buffer_service_backfill();
            /* Pace the replay: a chunk every 20 ms is ~8 kB/s, comfortably
             * below the live stream's share of the link. */
            vTaskDelay(pdMS_TO_TICKS(20));
        } else {
            vTaskDelay(pdMS_TO_TICKS(100));
        }
    }
}

/* ── Housekeeping ────────────────────────────────────────────────────── */

static void housekeeping_task(void *arg)
{
    TickType_t last = xTaskGetTickCount();
    uint32_t   tick = 0;

    for (;;) {
        vTaskDelayUntil(&last, pdMS_TO_TICKS(50));   /* 20 Hz for the LED */
        status_led_tick();

        if (++tick % 20 == 0) {       /* once a second */
            session_stats_t st;
            session_buffer_stats(&st);

            device_status_t ds = {
                .fw_state    = (uint8_t)sm_state(),
                .seq_oldest  = st.seq_oldest,
                .seq_newest  = st.seq_newest,
                .flags       = (uint8_t)((st.psram_backed ? 1 : 0) |
                                         (st.gap_occurred ? 2 : 0)),
            };
            battery_read(&ds.battery_mv, &ds.battery_pct);

            /* Below 15 % the device completes the current set, then stops and
             * saves, rather than terminating mid-set [PRD §5.7]. The fault
             * carries a cue, so the patient is told rather than simply
             * finding the device dead. */
            if (ds.battery_pct > 0 && ds.battery_pct < VBAT_LOW_PCT &&
                !s_battery_warned) {
                s_battery_warned = true;
                status_led_set_battery_low(true);
                if (sm_state() == FW_STATE_OPERATIONAL) {
                    ESP_LOGW(TAG, "battery %u%%: finishing the set, then "
                                  "stopping", ds.battery_pct);
                    s_stop_after_set = true;
                } else {
                    sm_fault(FAULT_BATTERY_LOW, "battery low");
                }
            }

            ds.host_time_offset_us = rehab_time_offset_us();

            ble_update_status(&ds);
        }
    }
}

/* ── Control commands ────────────────────────────────────────────────── */

static void on_ble_command(uint8_t op, const uint8_t *payload, size_t len)
{
    switch (op) {
    case CMD_START_SESSION:
        sm_request_start_session(len ? payload[0] : 0);
        break;

    case CMD_STOP_SESSION:
        sm_request_stop_session();
        break;

    case CMD_START_CALIBRATION:
        /* The step argument has always been on the wire; it is now honoured,
         * so a failed step can be repeated on its own [PRD §5.3]. */
        sm_request_calibration(len ? (calib_phase_t)payload[0]
                                   : CALIB_STEP_ALL);
        break;

    case CMD_REQUEST_RECALIBRATION:
        sm_request_recalibration();
        break;

    case CMD_ABORT_CALIBRATION:
        calibration_abort();
        break;

    case CMD_ACK_SEQ:
        if (len >= 4) {
            uint32_t seq;
            memcpy(&seq, payload, 4);
            session_buffer_ack(seq);
        }
        break;

    case CMD_REQUEST_BACKFILL:
        /* Replay a range the host missed during a dropout [PRD §5.9]. Served
         * below the live stream in priority so catching up never stalls
         * real-time data; the storage task owns the pacing. */
        if (len >= 8) {
            uint32_t from, to;
            memcpy(&from, payload,     4);
            memcpy(&to,   payload + 4, 4);
            const esp_err_t be = session_buffer_request_backfill(from, to);
            if (be != ESP_OK) {
                ESP_LOGW(TAG, "backfill %u..%u refused (%d)",
                         (unsigned)from, (unsigned)to, (int)be);
            }
        } else {
            ESP_LOGW(TAG, "REQUEST_BACKFILL needs 8 bytes, got %u",
                     (unsigned)len);
        }
        break;

    case CMD_SET_CONFIG:
        /* TLV of the parameters in PRD §5.9.1. Values are validated and
         * clamped, persisted to NVS, and pushed to grading and the repetition
         * cycle; they take effect from the next repetition. */
        if (config_apply_tlv(payload, len) != ESP_OK) {
            ESP_LOGW(TAG, "SET_CONFIG rejected: malformed TLV");
        }
        break;

    case CMD_GET_CONFIG: {
        /* How the host confirms a write took effect. */
        uint8_t buf[CFG_TLV_MAX_BYTES];
        const size_t n = config_serialise(buf, sizeof(buf));
        ble_notify_config(buf, n);
        break;
    }

    case CMD_SET_TIME:
        /* The device records the offset and reports it, but never adjusts its
         * own clock: altering the sampling clock would corrupt the timing the
         * spectral analysis depends on [PRD §12]. */
        if (len >= 8) {
            uint64_t host_us;
            memcpy(&host_us, payload, 8);
            rehab_time_set_host_epoch_us(host_us,
                                         (uint64_t)esp_timer_get_time());
            ESP_LOGI(TAG, "host time received; offset %lld us",
                     (long long)rehab_time_offset_us());
        }
        break;

    case CMD_INTERNAL_CALIB_WRITE:
        /* A calibration record pushed from the host. This is how a
         * clinician-supplied normalisation value supersedes a measured one
         * [PRD §5.3]. */
        if (len == sizeof(calib_record_t)) {
            const calib_record_t *rec = (const calib_record_t *)payload;
            calibration_set_record(rec, true);
            emg_dsp_set_calibration(rec);
            rep_cycle_set_calibration(rec);
            ESP_LOGI(TAG, "calibration record installed from host");
        } else {
            ESP_LOGW(TAG, "calib write: expected %u bytes, got %u",
                     (unsigned)sizeof(calib_record_t), (unsigned)len);
        }
        break;

    case CMD_HAPTIC_TEST:
        if (len >= 1) {
            haptic_play((haptic_pattern_t)payload[0]);
        }
        break;

    case CMD_POWER_OFF:
        sm_request_power_off();
        break;

    default:
        ESP_LOGW(TAG, "unhandled command 0x%02X", op);
        break;
    }
}

/* ── Boot ────────────────────────────────────────────────────────────── */

void app_main(void)
{
    ESP_LOGI(TAG, "RehabSense firmware starting");

    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ESP_ERROR_CHECK(nvs_flash_init());
    }

    /* PSRAM first: the buffer design depends on it, and an N8R8 module left in
     * quad mode reports zero here, which looks exactly like absent hardware. */
    const size_t psram = esp_psram_get_size();
    if (psram == 0) {
        ESP_LOGW(TAG, "no PSRAM detected. If this is an N8R8 module, "
                      "CONFIG_SPIRAM_MODE_OCT is probably unset.");
    } else {
        ESP_LOGI(TAG, "PSRAM: %u kB", (unsigned)(psram / 1024));
    }

    ESP_ERROR_CHECK(status_led_init());
    sm_init();

    /* ── Peripherals ───────────────────────────────────────────────── */
    const emg_cfg_t emg_cfg = {
        .sample_rate_hz    = EMG_SAMPLE_RATE_HZ,
        .dma_frame_samples = EMG_DMA_FRAME_SAMPLES,
    };
    ESP_ERROR_CHECK(s_emg_drv->init(&emg_cfg));
    ESP_ERROR_CHECK(emg_dsp_init(s_emg_drv->full_scale()));

    if (bmi270_init_all() != ESP_OK) {
        sm_fault(FAULT_IMU_UNRESPONSIVE, "IMU init failed");
        return;
    }
    fusion_init();

    if (drv2605l_init() != ESP_OK) {
        /* Not fatal: the device still records, it just cannot give feedback.
         * Say so rather than pretending the haptic works. */
        ESP_LOGE(TAG, "haptic unavailable — continuing without feedback");
    }
    haptic_task_start();

    ESP_ERROR_CHECK(session_buffer_init());
    calibration_init();
    rep_cycle_init();
    battery_init();

    /* Runtime configuration: NVS if a profile exists, compile-time defaults
     * otherwise. Published to grading and the repetition cycle before either
     * runs, so the first repetition is already scored against the parameters
     * in force [PRD §5.9.1]. */
    config_init();

    /* ── Self-test ─────────────────────────────────────────────────── */
    emg_selftest_t emg_st;
    if (s_emg_drv->self_test(&emg_st) != ESP_OK) {
        sm_fault(FAULT_EMG_UNRESPONSIVE, emg_st.detail);
        return;
    }

    char imu_detail[128];
    if (bmi270_self_test(imu_detail, sizeof(imu_detail)) != ESP_OK) {
        sm_fault(FAULT_IMU_UNRESPONSIVE, imu_detail);
        return;
    }

    /* ── Comms ─────────────────────────────────────────────────────── */
    s_ble_emg_q = xQueueCreate(QUEUE_DEPTH_FRAMES,
                               sizeof(emg_frame_t) * BLE_EMG_BATCH);
    ESP_ERROR_CHECK(ble_service_init(on_ble_command));

    /* Load any stored profile so a returning patient skips the full
     * protocol. */
    calib_record_t stored;
    if (calibration_load_nvs(&stored) == ESP_OK) {
        emg_dsp_set_calibration(&stored);
        fusion_set_calibration(&stored);
        rep_cycle_set_calibration(&stored);
        ESP_LOGI(TAG, "stored calibration profile loaded");
    }

    ESP_ERROR_CHECK(s_emg_drv->start());

    /* ── Tasks ─────────────────────────────────────────────────────── */
    xTaskCreatePinnedToCore(emg_dsp_task,      "emg_dsp",  STACK_EMG_DSP,
                            NULL, PRIO_EMG_DSP,      NULL, CORE_SENSOR);
    xTaskCreatePinnedToCore(imu_task,          "imu",      STACK_IMU,
                            NULL, PRIO_IMU,          NULL, CORE_SENSOR);
    xTaskCreatePinnedToCore(analysis_task,     "analysis", STACK_ANALYSIS,
                            NULL, PRIO_ANALYSIS,     NULL, CORE_SENSOR);
    xTaskCreatePinnedToCore(ble_tx_task,       "ble_tx",   STACK_BLE_TX,
                            NULL, PRIO_BLE_TX,       NULL, CORE_COMMS);
    xTaskCreatePinnedToCore(storage_task,      "storage",  STACK_STORAGE,
                            NULL, PRIO_STORAGE,      NULL, CORE_COMMS);
    xTaskCreatePinnedToCore(housekeeping_task, "house",    STACK_HOUSEKEEPING,
                            NULL, PRIO_HOUSEKEEPING, NULL, CORE_COMMS);

    sm_selftest_passed();
    ESP_LOGI(TAG, "ready — advertising as \"%s\"", BLE_DEVICE_NAME);
}
