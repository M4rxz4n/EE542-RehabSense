/*
 * rehab_time.h — the device clock and the host's wall clock [PRD §12]
 *
 * The device timebase is esp_timer_get_time(): monotonic microseconds since
 * boot, shared by every subsystem.
 *
 * On connection the host sends SET_TIME with its own epoch. The device records
 * the OFFSET and reports it, but NEVER adjusts its own clock. Adjusting a
 * sampling clock to match a phone would corrupt exactly the timing the
 * spectral analysis depends on — the fatigue index is a frequency measurement,
 * and a frequency measured against a clock that jumps is not a measurement.
 *
 * Everything that needs wall-clock time — profile staleness, session records
 * — asks here and gets zero until the host has spoken.
 */

#ifndef REHAB_TIME_H
#define REHAB_TIME_H

#include <stdint.h>
#include <stdbool.h>

/* Record the host's epoch. offset_us = host_epoch_us - device_monotonic_us. */
void rehab_time_set_host_epoch_us(uint64_t host_epoch_us, uint64_t device_us);

/* Offset for the status characteristic. Zero until SET_TIME arrives. */
int64_t rehab_time_offset_us(void);

bool rehab_time_have_host_time(void);

/* Current wall-clock time in epoch seconds, or 0 if the host has not sent it.
 * Callers must treat 0 as "unknown", never as 1970. */
uint32_t rehab_now_epoch_s(void);

#endif /* REHAB_TIME_H */
