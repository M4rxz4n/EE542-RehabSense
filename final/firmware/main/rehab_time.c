/*
 * rehab_time.c — the device clock and the host's wall clock [PRD §12]
 */

#include "rehab_time.h"

#ifdef REHAB_HOST_TEST
/* The host test build has no esp_timer; tests drive the device clock
 * explicitly through rehab_time_set_host_epoch_us(). */
static uint64_t s_fake_now_us;
static uint64_t now_us(void) { return s_fake_now_us; }
#else
#include "esp_timer.h"
static uint64_t now_us(void) { return (uint64_t)esp_timer_get_time(); }
#endif

static int64_t s_offset_us;
static bool    s_have;

void rehab_time_set_host_epoch_us(uint64_t host_epoch_us, uint64_t device_us)
{
#ifdef REHAB_HOST_TEST
    s_fake_now_us = device_us;
#endif
    s_offset_us = (int64_t)host_epoch_us - (int64_t)device_us;
    s_have      = true;
}

int64_t rehab_time_offset_us(void) { return s_offset_us; }
bool    rehab_time_have_host_time(void) { return s_have; }

uint32_t rehab_now_epoch_s(void)
{
    if (!s_have) {
        return 0;   /* unknown, which is not the same as 1970 */
    }
    const int64_t wall_us = (int64_t)now_us() + s_offset_us;
    if (wall_us <= 0) {
        return 0;
    }
    return (uint32_t)(wall_us / 1000000);
}
