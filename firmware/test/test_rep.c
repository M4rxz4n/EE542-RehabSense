/*
 * Host test for rep_cycle.c and grading.c — compiles the REAL firmware
 * sources against small stubs for esp_err/esp_log.
 *
 * Simulates elbow-angle traces at FEATURE_RATE_HZ and checks the counter.
 */

#include <stdio.h>
#include <string.h>
#include <math.h>
#include <stdlib.h>
#include "rep_cycle.h"
#include "grading.h"
#include "rehab_config.h"

static int g_failures;

#define CHECK(cond, fmt, ...)                                       \
    do {                                                            \
        if (!(cond)) {                                              \
            printf("  FAIL: " fmt "\n", ##__VA_ARGS__);             \
            g_failures++;                                           \
        } else {                                                    \
            printf("  ok:   " fmt "\n", ##__VA_ARGS__);             \
        }                                                           \
    } while (0)

/* Patient profile: 10 deg extension limit, 130 deg flexion. ROM = 120. */
static calib_record_t make_calib(void)
{
    calib_record_t c;
    memset(&c, 0, sizeof(c));
    c.version   = CALIB_RECORD_VERSION;
    c.angle_min = 10.0f;
    c.angle_max = 130.0f;
    c.emg_mvc[0] = 1.0f;
    c.emg_mvc[1] = 1.0f;
    c.flexion_axis[0] = 1.0f;
    return c;
}

typedef struct {
    uint64_t t_us;
    int      completed;
    int      abandoned;
    int      started;
    int      total_score;
    uint16_t last_comp;
} sim_t;

/* One tick at the given angle. */
static void tick(sim_t *sim, float angle, float upper_dev, float activation,
                 float upper_rate)
{
    static float prev_angle = 0.0f;

    fusion_out_t m = {
        .elbow_angle_deg    = angle,
        .upper_arm_dev_deg  = upper_dev,
        .elbow_velocity_dps = (angle - prev_angle) * FEATURE_RATE_HZ,
        .upper_arm_rate_dps = upper_rate,
        .anchored           = false,
    };
    prev_angle = angle;

    emg_features_t e;
    memset(&e, 0, sizeof(e));
    e.envelope[0] = activation;
    e.envelope[1] = activation * 0.15f;   /* mild, healthy co-contraction */
    e.mdf[0]      = 150.0f;
    e.t_us        = sim->t_us;

    rep_tick_t out;
    rep_cycle_tick(&m, &e, sim->t_us, &out);

    switch (out.event) {
    case REP_EVT_REP_COMPLETE:
        sim->completed++;
        sim->total_score += out.result.score;
        sim->last_comp = out.result.comp_flags;
        break;
    case REP_EVT_REP_ABANDONED: sim->abandoned++; break;
    case REP_EVT_REP_START:     sim->started++;   break;
    default: break;
    }

    sim->t_us += 1000000ULL / FEATURE_RATE_HZ;
}

static void hold_at(sim_t *sim, float angle, float ms, float dev,
                    float act, float rate)
{
    const int n = (int)(ms * FEATURE_RATE_HZ / 1000.0f);
    for (int i = 0; i < n; i++) {
        tick(sim, angle, dev, act, rate);
    }
}

static void ramp(sim_t *sim, float from, float to, float ms, float dev,
                 float act, float rate)
{
    const int n = (int)(ms * FEATURE_RATE_HZ / 1000.0f);
    for (int i = 0; i < n; i++) {
        const float f = (float)(i + 1) / n;
        tick(sim, from + (to - from) * f, dev, act, rate);
    }
}

/* One textbook repetition: hold low, curl, hold high, lower. */
static void good_rep(sim_t *sim, float dev, float rate)
{
    hold_at(sim, 15.0f,  1300, dev, 0.05f, rate);   /* bottom hold */
    ramp(sim, 15.0f, 122.0f, 1500, dev, 0.45f, rate);
    hold_at(sim, 122.0f, 1300, dev, 0.40f, rate);   /* top hold -> counts */
    ramp(sim, 122.0f, 15.0f, 1500, dev, 0.30f, rate);
}

int main(void)
{
    const calib_record_t calib = make_calib();

    /* ── 1. Ten clean repetitions must count as exactly ten ─────────── */
    printf("\n[1] ten clean repetitions\n");
    {
        sim_t sim = { 0 };
        rep_cycle_init();
        rep_cycle_set_calibration(&calib);
        rep_cycle_begin_set();

        for (int i = 0; i < 10; i++) {
            good_rep(&sim, 3.0f, 5.0f);
        }
        hold_at(&sim, 15.0f, 1300, 3.0f, 0.05f, 5.0f);

        CHECK(sim.completed == 10, "counted %d (expected 10)", sim.completed);
        CHECK(sim.abandoned == 0,  "abandoned %d (expected 0)", sim.abandoned);
        const int avg = sim.completed ? sim.total_score / sim.completed : 0;
        CHECK(avg > 55, "mean score %d (expected > 55 for clean form)", avg);
    }

    /* ── 2. A short top hold must NOT count ─────────────────────────── */
    printf("\n[2] top hold released early (500 ms)\n");
    {
        sim_t sim = { 0 };
        rep_cycle_init();
        rep_cycle_set_calibration(&calib);
        rep_cycle_begin_set();

        hold_at(&sim, 15.0f, 1300, 3.0f, 0.05f, 5.0f);
        ramp(&sim, 15.0f, 122.0f, 1500, 3.0f, 0.45f, 5.0f);
        hold_at(&sim, 122.0f, 500, 3.0f, 0.40f, 5.0f);     /* too short */
        ramp(&sim, 122.0f, 15.0f, 1500, 3.0f, 0.30f, 5.0f);
        hold_at(&sim, 15.0f, 1300, 3.0f, 0.05f, 5.0f);

        CHECK(sim.started == 1,   "repetition armed (%d)", sim.started);
        CHECK(sim.completed == 0, "counted %d (expected 0)", sim.completed);
    }

    /* ── 3. Passing through the band without holding must not arm ───── */
    printf("\n[3] swinging through the bottom band without holding\n");
    {
        sim_t sim = { 0 };
        rep_cycle_init();
        rep_cycle_set_calibration(&calib);
        rep_cycle_begin_set();

        for (int i = 0; i < 4; i++) {
            ramp(&sim, 60.0f, 15.0f, 400, 3.0f, 0.3f, 5.0f);
            ramp(&sim, 15.0f, 60.0f, 400, 3.0f, 0.3f, 5.0f);
        }

        CHECK(sim.started == 0,   "never armed (%d)", sim.started);
        CHECK(sim.completed == 0, "counted %d (expected 0)", sim.completed);
    }

    /* ── 4. Stalling mid-curl past the timeout abandons the rep ─────── */
    printf("\n[4] stalled mid-concentric past the 10 s timeout\n");
    {
        sim_t sim = { 0 };
        rep_cycle_init();
        rep_cycle_set_calibration(&calib);
        rep_cycle_begin_set();

        hold_at(&sim, 15.0f, 1300, 3.0f, 0.05f, 5.0f);
        ramp(&sim, 15.0f, 70.0f, 800, 3.0f, 0.45f, 5.0f);
        hold_at(&sim, 70.0f, 11000, 3.0f, 0.2f, 5.0f);     /* stuck */

        CHECK(sim.started == 1,   "repetition armed (%d)", sim.started);
        CHECK(sim.abandoned == 1, "abandoned %d (expected 1)", sim.abandoned);
        CHECK(sim.completed == 0, "counted %d (expected 0)", sim.completed);
    }

    /* ── 5. Bad start posture freezes the counter ───────────────────── */
    printf("\n[5] upper arm 25 deg off neutral throughout\n");
    {
        sim_t sim = { 0 };
        rep_cycle_init();
        rep_cycle_set_calibration(&calib);
        rep_cycle_begin_set();

        for (int i = 0; i < 3; i++) {
            good_rep(&sim, 25.0f, 5.0f);   /* beyond the 15 deg tolerance */
        }

        CHECK(sim.started == 0,   "never armed (%d)", sim.started);
        CHECK(sim.completed == 0, "counted %d (expected 0)", sim.completed);
    }

    /* ── 6. Compensation is flagged, counted, and scored lower ──────── */
    printf("\n[6] shoulder hike and arm swing during the curl\n");
    {
        sim_t clean = { 0 }, dirty = { 0 };

        rep_cycle_init();
        rep_cycle_set_calibration(&calib);
        rep_cycle_begin_set();
        good_rep(&clean, 3.0f, 5.0f);
        const int clean_score = clean.total_score;

        rep_cycle_init();
        rep_cycle_set_calibration(&calib);
        rep_cycle_begin_set();
        /* Start posture still fine; the hike develops during the lift. */
        hold_at(&dirty, 15.0f, 1300, 3.0f, 0.05f, 5.0f);
        ramp(&dirty, 15.0f, 122.0f, 1500, 20.0f, 45.0f, 45.0f);
        hold_at(&dirty, 122.0f, 1300, 20.0f, 0.40f, 45.0f);
        const int dirty_score = dirty.total_score;

        CHECK(dirty.completed == 1, "compensated rep still counted (%d)",
              dirty.completed);
        CHECK((dirty.last_comp & COMP_FLAG_SHOULDER) != 0,
              "shoulder hike flagged (flags 0x%02X)", dirty.last_comp);
        CHECK((dirty.last_comp & COMP_FLAG_SWING) != 0,
              "arm swing flagged (flags 0x%02X)", dirty.last_comp);
        CHECK(dirty_score < clean_score,
              "score penalised: %d < %d", dirty_score, clean_score);
    }

    /* ── 7. Partial ROM scores lower than full ROM ──────────────────── */
    printf("\n[7] partial range scores below full range\n");
    {
        sim_t full = { 0 }, part = { 0 };

        rep_cycle_init();
        rep_cycle_set_calibration(&calib);
        rep_cycle_begin_set();
        good_rep(&full, 3.0f, 5.0f);

        rep_cycle_init();
        rep_cycle_set_calibration(&calib);
        rep_cycle_begin_set();
        /* Only just reaches the flexion band, at 110 deg. Ramp time scaled so
         * the angular SPEED matches the full rep — otherwise this test would
         * be changing two variables at once. */
        hold_at(&part, 15.0f, 1300, 3.0f, 0.05f, 5.0f);
        ramp(&part, 15.0f, 110.0f, 1332, 3.0f, 0.45f, 5.0f);
        hold_at(&part, 110.0f, 1300, 3.0f, 0.40f, 5.0f);

        CHECK(part.completed == 1, "shallow rep counted (%d)", part.completed);
        CHECK(part.total_score < full.total_score,
              "scored lower: %d < %d", part.total_score, full.total_score);
    }

    /* ── 8. Smoothness must be scale-free ───────────────────────────────
     * A slow smooth curl and a fast smooth curl are both smooth. If the
     * metric is not normalised by speed, moving slowly scores better — which
     * would reward the guarding this device exists to discourage. */
    printf("\n[8] slow and fast smooth reps score alike\n");
    {
        sim_t fast = { 0 }, slow = { 0 };

        rep_cycle_init();
        rep_cycle_set_calibration(&calib);
        rep_cycle_begin_set();
        hold_at(&fast, 15.0f, 1300, 3.0f, 0.05f, 5.0f);
        ramp(&fast, 15.0f, 122.0f, 1000, 3.0f, 0.45f, 5.0f);
        hold_at(&fast, 122.0f, 1300, 3.0f, 0.40f, 5.0f);

        rep_cycle_init();
        rep_cycle_set_calibration(&calib);
        rep_cycle_begin_set();
        hold_at(&slow, 15.0f, 1300, 3.0f, 0.05f, 5.0f);
        ramp(&slow, 15.0f, 122.0f, 3000, 3.0f, 0.45f, 5.0f);   /* 3x slower */
        hold_at(&slow, 122.0f, 1300, 3.0f, 0.40f, 5.0f);

        const int diff = abs(fast.total_score - slow.total_score);
        CHECK(fast.completed == 1 && slow.completed == 1,
              "both counted (%d, %d)", fast.completed, slow.completed);
        CHECK(diff <= 3, "scores within 3 points: %d vs %d (diff %d)",
              fast.total_score, slow.total_score, diff);
    }

    printf("\n%s (%d failure%s)\n",
           g_failures ? "FAILURES PRESENT" : "all checks passed",
           g_failures, g_failures == 1 ? "" : "s");
    return g_failures ? 1 : 0;
}
