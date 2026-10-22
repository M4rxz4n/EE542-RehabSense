/*
 * state_machine.c — firmware state machine
 */

#include <string.h>
#include "esp_log.h"
#include "esp_timer.h"

#include "state_machine.h"
#include "calibration.h"
#include "rep_cycle.h"
#include "emg_dsp.h"
#include "fusion.h"
#include "patterns.h"
#include "drv2605l.h"
#include "status_led.h"
#include "session_buffer.h"
#include "ble_service.h"
#include "rehab_config.h"

static const char *TAG = "sm";

static fw_state_t   s_state = FW_STATE_OFF;
static fault_code_t s_fault;
static uint8_t      s_exercise_id;
static uint64_t     s_wrong_pos_last_us;

/* Latest inputs, published by the analysis task before each tick. */
static emg_features_t s_emg;
static fusion_out_t   s_motion;

void sm_publish_inputs(const emg_features_t *e, const fusion_out_t *m)
{
    s_emg    = *e;
    s_motion = *m;
}

static void emit(event_id_t id, const void *payload, size_t len)
{
    rehab_event_t evt = { .t_us = esp_timer_get_time(), .id = (uint8_t)id };
    if (payload && len <= sizeof(evt.payload)) {
        memcpy(evt.payload, payload, len);
        evt.payload_len = (uint8_t)len;
    }
    ble_notify_event(&evt);
}

static void transition(fw_state_t next)
{
    if (next == s_state) {
        return;
    }
    ESP_LOGI(TAG, "state %d -> %d", s_state, next);
    s_state = next;
    status_led_set_state(next);

    const uint8_t payload = (uint8_t)next;
    emit(EVT_STATE_CHANGE, &payload, 1);
}

fw_state_t sm_state(void) { return s_state; }

void sm_init(void)
{
    s_state = FW_STATE_BOOT;
    s_fault = FAULT_NONE;
    status_led_set_state(s_state);
}

void sm_fault(fault_code_t code, const char *detail)
{
    s_fault = code;
    ESP_LOGE(TAG, "FAULT %d: %s", code, detail ? detail : "");

    /* Mute first, then change state. A runaway motor is the one thing that
     * must stop before anything else happens. */
    haptic_stop();
    drv2605l_mute();
    session_buffer_end();

    const uint8_t payload = (uint8_t)code;
    emit(EVT_FAULT, &payload, 1);
    transition(FW_STATE_FAULT);
}

/* ── Requests ────────────────────────────────────────────────────────── */

void sm_request_start_session(uint8_t exercise_id)
{
    s_exercise_id = exercise_id;

    switch (s_state) {
    case FW_STATE_STANDBY:
        donning_check_begin();
        transition(FW_STATE_DONNING_CHECK);
        break;
    case FW_STATE_OPERATIONAL:
        ESP_LOGW(TAG, "START ignored: a set is already running");
        break;
    default:
        ESP_LOGW(TAG, "START refused in state %d", s_state);
        break;
    }
}

void sm_request_stop_session(void)
{
    if (s_state != FW_STATE_OPERATIONAL) {
        return;
    }
    rep_cycle_end_set();
    session_buffer_end();
    emit(EVT_SET_COMPLETE, NULL, 0);
    transition(FW_STATE_STANDBY);
}

void sm_request_calibration(bool full)
{
    if (s_state != FW_STATE_STANDBY && s_state != FW_STATE_DONNING_CHECK &&
        s_state != FW_STATE_OPERATIONAL) {
        ESP_LOGW(TAG, "calibration refused in state %d", s_state);
        return;
    }
    if (full) {
        calibration_begin();
    } else {
        calibration_begin_neutral_only();
    }
    transition(FW_STATE_CALIBRATION);
}

void sm_request_power_off(void)
{
    if (s_state == FW_STATE_OPERATIONAL) {
        /* Seal the buffer first so the set is not lost. */
        rep_cycle_end_set();
        session_buffer_end();
    }
    haptic_stop();
    drv2605l_mute();
    transition(FW_STATE_OFF);
}

/* ── Tick ────────────────────────────────────────────────────────────── */

static void tick_donning(uint64_t t_us)
{
    const char *msg = NULL;
    const donning_result_t r =
        donning_check_tick(&s_emg, &s_motion, t_us, &msg);

    if (r == DON_PENDING) {
        return;
    }

    if (r != DON_PASS) {
        ESP_LOGW(TAG, "donning check failed: %s", msg);
        const uint8_t payload = (uint8_t)r;
        emit(EVT_CALIB_PHASE_DONE, &payload, 1);
        transition(FW_STATE_STANDBY);
        return;
    }

    /* Passed. A returning patient with a current profile takes the short
     * path: recapture the neutral pose and go, rather than repeating the
     * full 90-second protocol. */
    calib_record_t stored;
    if (calibration_load_nvs(&stored) == ESP_OK &&
        !calibration_is_stale(&stored, 0)) {
        calibration_begin_neutral_only();
    } else {
        calibration_begin();
    }
    transition(FW_STATE_CALIBRATION);
}

static void tick_calibration(uint64_t t_us)
{
    calib_progress_t pr;
    calibration_tick(&s_emg, &s_motion, t_us, &pr);

    if (pr.phase_changed) {
        const uint8_t payload[2] = { (uint8_t)pr.phase, pr.percent };
        emit(EVT_CALIB_PHASE_DONE, payload, sizeof(payload));
    }

    if (pr.phase == CALIB_FAILED) {
        transition(FW_STATE_STANDBY);
        return;
    }

    if (calibration_complete()) {
        const calib_record_t *rec = calibration_record();
        calibration_save_nvs(rec);

        emg_dsp_set_calibration(rec);
        fusion_set_calibration(rec);
        rep_cycle_set_calibration(rec);

        rep_cycle_begin_set();
        session_buffer_begin();
        transition(FW_STATE_OPERATIONAL);
    }
}

static void tick_operational(uint64_t t_us)
{
    rep_tick_t rt;
    rep_cycle_tick(&s_motion, &s_emg, t_us, &rt);

    switch (rt.event) {

    case REP_EVT_REP_COMPLETE:
        /* One haptic per repetition, at the end of the top hold: either the
         * clean pulse or the compensation pattern, never both. */
        haptic_play(rt.comp_flags ? PATTERN_REP_COMPENSATED
                                  : PATTERN_REP_COMPLETE);
        emit(EVT_REP_COMPLETE, &rt.result, sizeof(rt.result) > 16
                                           ? 16 : sizeof(rt.result));

        if (rep_cycle_fatigue_flagged()) {
            haptic_play(PATTERN_REST_CUE);
            emit(EVT_FATIGUE_WARN, NULL, 0);
        }
        break;

    case REP_EVT_REP_START:
        emit(EVT_REP_START, NULL, 0);
        break;

    case REP_EVT_REP_ABANDONED:
        emit(EVT_REP_ABANDONED, NULL, 0);
        break;

    case REP_EVT_START_POS_BAD:
        /* Nag every 2.5 s while posture is wrong. The counter stays frozen
         * until it is corrected. */
        if (t_us - s_wrong_pos_last_us > 2500000ULL) {
            haptic_play(PATTERN_WRONG_START);
            emit(EVT_START_POS_BAD, NULL, 0);
            s_wrong_pos_last_us = t_us;
        }
        break;

    case REP_EVT_START_POS_OK:
        s_wrong_pos_last_us = 0;
        break;

    default:
        break;
    }

    if (s_emg.sig_flags & (SIG_FLAG_DEGRADED_A | SIG_FLAG_DEGRADED_B)) {
        const uint8_t payload = (uint8_t)s_emg.sig_flags;
        emit(EVT_SIGNAL_DEGRADED, &payload, 1);
    }
}

void sm_tick(uint64_t t_us)
{
    switch (s_state) {
    case FW_STATE_BOOT:
        /* main() drives self-test and promotes us to STANDBY. */
        break;
    case FW_STATE_STANDBY:
        break;
    case FW_STATE_DONNING_CHECK:
        tick_donning(t_us);
        break;
    case FW_STATE_CALIBRATION:
        tick_calibration(t_us);
        break;
    case FW_STATE_OPERATIONAL:
        tick_operational(t_us);
        break;
    case FW_STATE_FAULT:
    case FW_STATE_OFF:
        break;
    }

    status_led_set_link(ble_is_connected());
}

/* Promoted from BOOT once main() has run the self-tests. */
void sm_selftest_passed(void)
{
    haptic_play(PATTERN_BOOT_OK);
    transition(FW_STATE_STANDBY);
}
