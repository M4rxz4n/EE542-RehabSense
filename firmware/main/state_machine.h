/*
 * state_machine.h — firmware state machine
 *
 *   OFF -> BOOT/SELF-TEST -> STANDBY -> DONNING CHECK -> CALIBRATION
 *                               ^                            |
 *                               |                            v
 *                               +------- OPERATIONAL <-------+
 *
 * The app drives transitions through the control characteristic, but the
 * device refuses to enter OPERATIONAL until the donning check has passed and
 * a calibration profile exists. The app cannot override that: scoring against
 * a bad reference is worse than not scoring at all.
 *
 * Losing the BLE link is NOT a state transition. A device in OPERATIONAL with
 * no connection stays in OPERATIONAL — acquisition, repetition detection and
 * haptics all continue, and only the transmit task idles.
 */

#ifndef STATE_MACHINE_H
#define STATE_MACHINE_H

#include "rehab_types.h"
#include "calibration.h"

void       sm_init(void);
fw_state_t sm_state(void);

/* Requests from the control characteristic. Refused requests are logged and
 * reported, never silently ignored. */
void sm_request_start_session(uint8_t exercise_id);
void sm_request_stop_session(void);

/* Run one calibration step, or CALIB_STEP_ALL for the whole protocol. A failed
 * step is repeated on its own rather than restarting [PRD §5.3]. */
void sm_request_calibration(calib_phase_t step);
void sm_request_recalibration(void);
void sm_request_power_off(void);

void sm_fault(fault_code_t code, const char *detail);

/* Driven by the analysis task at FEATURE_RATE_HZ. */
void sm_tick(uint64_t t_us);

#endif /* STATE_MACHINE_H */
