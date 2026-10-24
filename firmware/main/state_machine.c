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
#include "rehab_time.h"
#include "config.h"

static const char *TAG = "sm";

static fw_state_t   s_state = FW_STATE_OFF;
static fault_code_t s_fault;
static uint8_t      s_exercise_id;
static uint64_t     s_wrong_pos_last_us;

/* When to cut the haptic enable pin after a fault cue. Zero means "already
 * muted, or no cue was owed". Checked in sm_tick so sm_fault never blocks the
 * analysis task waiting for a 900 ms pattern to finish. */
static uint64_t     s_mute_at_us;

/* The rest cue fires once per set, not on every repetition after the trend
 * crosses the threshold. */
static bool         s_fatigue_cued;

/* Latest inputs, published by the analysis task before each tick. */
static emg_features_t s_emg;
static fusion_out_t   s_motion;

/* The most recent repetition tick, so the feature frame can report what the
 * repetition cycle currently believes. Refreshed every operational tick and
 * cleared when a set begins or ends. */
static rep_tick_t     s_last_rep;

void sm_fill_features(features_t *f)
{
    if (s_state != FW_STATE_OPERATIONAL) {
        f->rep_state     = (uint8_t)REP_READY;
        f->rep_count     = 0;
        f->comp_flags    = 0;
        f->activation_on = 0;
        return;
    }
    f->rep_state     = (uint8_t)s_last_rep.state;
    f->rep_count     = s_last_rep.rep_count;
    f->comp_flags    = s_last_rep.comp_flags;
    f->activation_on = s_last_rep.activation_on ? 1 : 0;
}

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

    /* Recorded before it is transmitted, and recorded whether or not anyone is
     * listening. An event that exists only as a notification is lost to a
     * dropped link, and the event log is what the physician view reads to
     * explain why a repetition scored the way it did. */
    session_buffer_push_event(&evt);
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

    session_buffer_end();

    if (fault_warrants_cue(code)) {
        /* The patient must be TOLD. A lifted electrode or a flat battery is a
         * fault whose whole point is the warning, and muting first would let
         * the fault state silence its own cue [PRD §5.2].
         *
         * The fault pattern preempts whatever is playing, so it starts
         * immediately. The enable pin is cut once the cue has finished —
         * s_mute_at_us is checked by sm_tick rather than slept on here,
         * because this runs from the analysis task and must not block it. */
        haptic_play(PATTERN_FAULT);
        s_mute_at_us = esp_timer_get_time() +
                       (uint64_t)HAPTIC_MUTE_DELAY_MS * 1000;
    } else {
        /* A runaway motor, a dead bus, a watchdog bite: mute first and ask
         * questions later. Nothing useful can be signalled through an
         * actuator that may itself be the problem. */
        haptic_stop();
        drv2605l_mute();
        s_mute_at_us = 0;
    }

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

/* CMD_START_CALIBRATION carries the step to run, so a failed step can be
 * repeated on its own without restarting the protocol [PRD §5.3]. The step
 * argument used to be discarded, which made that impossible even though the
 * host had always sent it. */
void sm_request_calibration(calib_phase_t step)
{
    if (s_state != FW_STATE_STANDBY && s_state != FW_STATE_DONNING_CHECK &&
        s_state != FW_STATE_OPERATIONAL) {
        ESP_LOGW(TAG, "calibration refused in state %d", s_state);
        return;
    }

    switch (step) {
    case CALIB_STEP_ALL:
        calibration_begin_all();
        break;
    case CALIB_STEP_CONTACT:
        donning_check_begin();
        transition(FW_STATE_DONNING_CHECK);
        return;
    case CALIB_STEP_REST:
    case CALIB_STEP_STRAIGHT:
    case CALIB_STEP_BICEPS:
    case CALIB_STEP_TRICEPS:
    case CALIB_STEP_SWEEP:
        calibration_begin_step(step);
        break;
    default:
        ESP_LOGW(TAG, "unknown calibration step %d", (int)step);
        return;
    }
    transition(FW_STATE_CALIBRATION);
}

void sm_request_recalibration(void)
{
    sm_request_calibration(CALIB_STEP_ALL);
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
     * path — steps 1, 2 and 5 only — rather than repeating the maxima.
     *
     * The staleness check is given the real epoch. It used to be passed a
     * literal zero, which made every stored profile read as expired and sent
     * every patient through the full protocol every single session. */
    calib_record_t stored;
    if (calibration_load_nvs(&stored) == ESP_OK &&
        !calibration_is_stale(&stored, rehab_now_epoch_s())) {
        ESP_LOGI(TAG, "stored profile is current; session re-zero only");
        calibration_begin_session_rezero();
    } else {
        calibration_begin_all();
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

        s_fatigue_cued      = false;
        s_wrong_pos_last_us = 0;
        memset(&s_last_rep, 0, sizeof(s_last_rep));
        rep_cycle_begin_set();
        session_buffer_begin();
        transition(FW_STATE_OPERATIONAL);
    }
}

static void tick_operational(uint64_t t_us)
{
    rep_tick_t rt;
    rep_cycle_tick(&s_motion, &s_emg, t_us, &rt);

    /* Snapshot for the feature frame the analysis task builds immediately
     * after this returns. */
    s_last_rep = rt;

    switch (rt.event) {

    case REP_EVT_REP_COMPLETE:
        /* Exactly one haptic per repetition, at the end of the confirming
         * hold: either the clean click or the three-pulse flagged pattern,
         * never both [PRD §5.6].
         *
         * On the repetition that completes the set, the compound pattern
         * plays the per-repetition result, a 300 ms gap, then the set-complete
         * cue — one request, because a single-slot scheduler would drop a
         * second one. */
        if (rt.set_complete) {
            haptic_play(rt.comp_flags ? PATTERN_REP_FLAGGED_THEN_SET
                                      : PATTERN_REP_CLEAN_THEN_SET);
        } else {
            haptic_play(rt.comp_flags ? PATTERN_REP_FLAGGED
                                      : PATTERN_REP_CLEAN);
        }

        /* The full result goes to the session record; the BLE event carries
         * only the first 16 bytes, because rehab_event_t's payload is that
         * size. The app shows the headline from the event, the physician view
         * reads the complete record from the downloaded session. */
        session_buffer_push_rep(&rt.result);

        emit(EVT_REP_COMPLETE, &rt.result, sizeof(rt.result) > 16
                                           ? 16 : sizeof(rt.result));

        if (rt.comp_flags & COMP_FLAG_SHOULDER) {
            emit(EVT_COMPENSATION_SHOULDER, NULL, 0);
        }
        if (rt.comp_flags & COMP_FLAG_TRUNK) {
            emit(EVT_COMPENSATION_TRUNK, NULL, 0);
        }
        if (rt.comp_flags & COMP_FLAG_SWING) {
            emit(EVT_COMPENSATION_SWING, NULL, 0);
        }

        if (rt.set_complete) {
            /* Reaching rep_target ends the set [PRD §5.6]. The buffer is
             * sealed and the device returns to STANDBY for the rest interval;
             * the host decides when the next set starts. */
            rep_cycle_end_set();
            session_buffer_end();
            emit(EVT_SET_COMPLETE, &rt.rep_count, sizeof(rt.rep_count));
            ESP_LOGI(TAG, "set complete at %u repetitions", rt.rep_count);
            transition(FW_STATE_STANDBY);
            return;
        }

        /* Fatigue ADVISES, it does not stop the session. The rest cue fires
         * and the event is reported; whether to act on it is the patient's
         * and the therapist's decision, not the firmware's. A device that
         * ended a set on its own reading of a frequency trend would be
         * overruling the person doing the exercise. */
        if (rep_cycle_fatigue_flagged() && !s_fatigue_cued) {
            s_fatigue_cued = true;
            haptic_play(PATTERN_REST);
            emit(EVT_FATIGUE_WARN, NULL, 0);
        }
        break;

    case REP_EVT_REP_START:
        emit(EVT_REP_START, NULL, 0);
        break;

    case REP_EVT_PEAK_REACHED:
        /* Soft click at 80 % of the target angle: "you may begin the return."
         * Settled from PRD §11.2, which left it open. It shares the tick's
         * priority, so it is dropped rather than displacing a result cue. */
        haptic_play(PATTERN_SOFT_CLICK);
        break;

    case REP_EVT_HOLD_START:
        emit(EVT_HOLD_START, NULL, 0);
        break;

    case REP_EVT_REP_ABANDONED:
        emit(EVT_REP_ABANDONED, NULL, 0);
        break;

    case REP_EVT_PASSIVE_SWING:
        /* The arm rose with the agonist quiet. Report it and do not count it;
         * this is the case the whole device exists to catch [PRD §5.4]. The
         * patient gets no cue, because there is nothing to confirm — the app
         * says "use your muscle to lift". */
        if (t_us - s_wrong_pos_last_us > 2500000ULL) {
            emit(EVT_PASSIVE_SWING, NULL, 0);
            s_wrong_pos_last_us = t_us;
        }
        break;

    case REP_EVT_START_POS_BAD:
        /* Posture is wrong and the counter stays frozen until it is
         * corrected. Reported to the app, which shows what to fix; no haptic,
         * because a cue that repeats every 2.5 s while a patient is trying to
         * get into position reads as nagging rather than as information. */
        if (t_us - s_wrong_pos_last_us > 2500000ULL) {
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
        /* The fault cue has had its 900 ms; cut drive now [PRD §5.2]. */
        if (s_mute_at_us != 0 && t_us >= s_mute_at_us) {
            haptic_stop();
            drv2605l_mute();
            s_mute_at_us = 0;
            ESP_LOGI(TAG, "fault cue finished; haptics muted");
        }
        break;
    case FW_STATE_OFF:
        break;
    }

    status_led_set_link(ble_is_connected());
}

/* Promoted from BOOT once main() has run the self-tests.
 *
 * No boot cue: the six-pattern vocabulary in PRD §5.6 has no boot pattern, and
 * the one v0.1 used (two 100 ms pulses) sat in the fault cue's rhythmic
 * neighbourhood — the same class of collision the PRD records having to fix
 * once already. The status LED reports a successful boot instead. */
void sm_selftest_passed(void)
{
    transition(FW_STATE_STANDBY);
}
