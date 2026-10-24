/*
 * Host test for rep_cycle.c, grading.c and activation.c — compiles the REAL
 * firmware sources against small stubs for esp_err/esp_log.
 *
 * Simulates elbow-angle and EMG traces at FEATURE_RATE_HZ and checks what the
 * repetition cycle does with them. No hardware, no ESP-IDF.
 *
 * The cycle under test [PRD §5.4]:
 *
 *   READY -> CONCENTRIC -> PEAK -> ECCENTRIC -> EXTENDED_HOLD -> (counted)
 *
 * Start is gated on agonist activation AND the start threshold; the count
 * happens on the RETURN, after a confirming hold at the extended position.
 */

#include <stdio.h>
#include <string.h>
#include <math.h>
#include <stdlib.h>
#include "rep_cycle.h"
#include "grading.h"
#include "activation.h"
#include "rehab_config.h"

static int g_failures;

static float cfg_tempo_max(void)
{
    rehab_runtime_cfg_t c;
    rehab_cfg_defaults(&c);
    return c.tempo_max_s;
}

#define CHECK(cond, fmt, ...)                                       \
    do {                                                            \
        if (!(cond)) {                                              \
            printf("  FAIL: " fmt "\n", ##__VA_ARGS__);             \
            g_failures++;                                           \
        } else {                                                    \
            printf("  ok:   " fmt "\n", ##__VA_ARGS__);             \
        }                                                           \
    } while (0)

/* Patient profile: 10 deg extension limit, 130 deg flexion.
 *
 * Rest mean 0.01 with sigma 0.002 and a maximum of 1.0 puts the activation
 * thresholds at roughly 0.0 and -0.001 raw, which the detector floors to
 * ACT_MIN_THRESH — so "activation" in these tests means an envelope clearly
 * above a couple of percent of MVC, and "quiet" means essentially zero. */
static calib_record_t make_calib(void)
{
    calib_record_t c;
    memset(&c, 0, sizeof(c));
    c.version    = CALIB_RECORD_VERSION;
    c.angle_min  = 10.0f;
    c.angle_max  = 130.0f;
    for (int i = 0; i < EMG_N_CHANNELS; i++) {
        c.emg_rest_rms[i] = 0.010f;
        c.emg_rest_sd[i]  = 0.002f;
        c.emg_mvc[i]      = 1.000f;
    }
    c.flexion_axis[0] = 1.0f;
    return c;
}

typedef struct {
    uint64_t t_us;
    int      completed;
    int      abandoned;
    int      started;
    int      passive;
    int      peak_cues;
    int      set_completes;
    int      total_score;
    uint16_t last_comp;
    uint8_t  last_score;
    float    last_tempo;
    uint8_t  last_peaks;
    float    prev_angle;
} sim_t;

static void sim_reset(sim_t *s)
{
    memset(s, 0, sizeof(*s));
    s->prev_angle = 10.0f;
}

/* One tick at the given angle. `act` is the agonist envelope in %MVC. */
static void tick(sim_t *sim, float angle, float upper_dev, float act,
                 float upper_rate, float common_mode)
{
    fusion_out_t m;
    memset(&m, 0, sizeof(m));
    m.elbow_angle_deg    = angle;
    m.upper_arm_dev_deg  = upper_dev;
    m.common_mode_deg    = common_mode;
    m.elbow_velocity_dps = (angle - sim->prev_angle) * FEATURE_RATE_HZ;
    m.upper_arm_rate_dps = upper_rate;
    m.max_accel_g        = 1.0f;
    sim->prev_angle      = angle;

    emg_features_t e;
    memset(&e, 0, sizeof(e));
    e.envelope[EMG_CH_AGONIST] = act;
#if EMG_N_CHANNELS > 1
    e.envelope[EMG_CH_ANTAGONIST] = act * 0.15f;  /* mild, healthy */
#endif
    e.mdf[EMG_CH_AGONIST] = 150.0f;
    e.t_us = sim->t_us;

    rep_tick_t out;
    rep_cycle_tick(&m, &e, sim->t_us, &out);

    switch (out.event) {
    case REP_EVT_REP_COMPLETE:
        sim->completed++;
        sim->total_score += out.result.score;
        sim->last_comp   = out.result.comp_flags;
        sim->last_score  = out.result.score;
        sim->last_tempo  = out.result.tempo_s;
        sim->last_peaks  = out.result.velocity_peaks;
        if (out.set_complete) sim->set_completes++;
        break;
    case REP_EVT_REP_ABANDONED: sim->abandoned++; break;
    case REP_EVT_REP_START:     sim->started++;   break;
    case REP_EVT_PASSIVE_SWING: sim->passive++;   break;
    case REP_EVT_PEAK_REACHED:  sim->peak_cues++; break;
    default: break;
    }

    sim->t_us += 1000000ULL / FEATURE_RATE_HZ;
}

static void hold_at(sim_t *sim, float angle, float ms, float dev, float act)
{
    const int n = (int)(ms * FEATURE_RATE_HZ / 1000.0f);
    for (int i = 0; i < n; i++) {
        tick(sim, angle, dev, act, 0.0f, 0.0f);
    }
}

/* Move smoothly from a to b over ms, holding the given deviation and
 * activation. A single monotone ramp is one velocity peak. */
static void ramp(sim_t *sim, float a, float b, float ms, float dev, float act,
                 float rate, float common)
{
    const int n = (int)(ms * FEATURE_RATE_HZ / 1000.0f);
    for (int i = 1; i <= n; i++) {
        /* Raised cosine: starts and ends at zero velocity, one clean peak in
         * the middle. A linear ramp would register velocity steps at both
         * ends and score as three pushes rather than one. */
        const float u = (float)i / (float)n;
        const float s = 0.5f - 0.5f * cosf(u * 3.14159265f);
        tick(sim, a + (b - a) * s, dev, act, rate, common);
    }
}

/* One complete, clean repetition at the default configuration:
 * rest at extension, curl past 80 % of target, return, hold to count. */
static void good_rep(sim_t *sim, float travel_ms)
{
    const float bottom = 10.0f;    /* angle_min */
    const float top    = 10.0f + 100.0f;

    hold_at(sim, bottom, 200, 0.0f, 0.0f);          /* quiet at rest */
    ramp(sim, bottom, top, travel_ms / 2, 0.0f, 0.45f, 0.0f, 0.0f);
    ramp(sim, top, bottom, travel_ms / 2, 0.0f, 0.35f, 0.0f, 0.0f);
    hold_at(sim, bottom, REP_HOLD_MS + 200, 0.0f, 0.0f);
}

static void setup(const rehab_runtime_cfg_t *cfg)
{
    calib_record_t c = make_calib();
    rep_cycle_init();
    if (cfg) {
        rep_cycle_set_config(cfg);
        grading_set_config(cfg);
    } else {
        rep_cycle_set_config(NULL);
        grading_set_config(NULL);
    }
    rep_cycle_set_calibration(&c);
    rep_cycle_begin_set();
}

/* ────────────────────────────────────────────────────────────────────── */

static void test_ten_reps(void)
{
    printf("\n[1] ten deliberate repetitions count as exactly ten\n");
    sim_t s; sim_reset(&s);
    setup(NULL);

    for (int i = 0; i < 10; i++) {
        good_rep(&s, 2400);
    }
    CHECK(s.completed == 10, "counted %d of 10", s.completed);
    CHECK(s.abandoned == 0,  "no partials (%d)", s.abandoned);
}

static void test_passive_swing(void)
{
    printf("\n[2] a passively swung arm is NOT counted [PRD §5.4]\n");
    sim_t s; sim_reset(&s);
    setup(NULL);

    /* Identical geometry to a good repetition — full range, correct posture,
     * correct timing — but the agonist never activates. This is the case a
     * motion-only device cannot distinguish, and the one the whole product
     * rests on. */
    for (int i = 0; i < 5; i++) {
        const float bottom = 10.0f, top = 110.0f;
        hold_at(&s, bottom, 200, 0.0f, 0.0f);
        ramp(&s, bottom, top, 1200, 0.0f, 0.0f, 0.0f, 0.0f);
        ramp(&s, top, bottom, 1200, 0.0f, 0.0f, 0.0f, 0.0f);
        hold_at(&s, bottom, REP_HOLD_MS + 200, 0.0f, 0.0f);
    }

    CHECK(s.completed == 0, "nothing counted (%d)", s.completed);
    CHECK(s.started   == 0, "no repetition even started (%d)", s.started);
    CHECK(s.passive    > 0, "passive swing reported (%d times)", s.passive);
}

static void test_gate_needs_both(void)
{
    printf("\n[3] the gate needs muscle AND movement, not either alone\n");

    /* Muscle without movement: a static contraction at rest. */
    sim_t s; sim_reset(&s);
    setup(NULL);
    hold_at(&s, 10.0f, 3000, 0.0f, 0.60f);
    CHECK(s.started == 0, "a contraction at rest starts nothing (%d)", s.started);

    /* Movement without muscle is covered by test [2]; together they count. */
    sim_reset(&s);
    setup(NULL);
    good_rep(&s, 2400);
    CHECK(s.completed == 1, "muscle plus movement counts (%d)", s.completed);
}

static void test_counted_on_return(void)
{
    printf("\n[4] the count happens on the RETURN, not at the top\n");
    sim_t s; sim_reset(&s);
    setup(NULL);

    const float bottom = 10.0f, top = 110.0f;
    hold_at(&s, bottom, 200, 0.0f, 0.0f);
    ramp(&s, bottom, top, 1200, 0.0f, 0.45f, 0.0f, 0.0f);

    /* Hold at the TOP for longer than the confirming hold. Under the old
     * design this counted; under PRD §5.4 it must not. */
    hold_at(&s, top, REP_HOLD_MS + 600, 0.0f, 0.45f);
    CHECK(s.completed == 0, "a long hold at the top counts nothing (%d)",
          s.completed);

    ramp(&s, top, bottom, 1200, 0.0f, 0.35f, 0.0f, 0.0f);
    hold_at(&s, bottom, REP_HOLD_MS + 200, 0.0f, 0.0f);
    CHECK(s.completed == 1, "counted after the return (%d)", s.completed);
}

static void test_early_release(void)
{
    printf("\n[5] releasing the confirming hold early does not count\n");
    sim_t s; sim_reset(&s);
    setup(NULL);

    const float bottom = 10.0f, top = 110.0f;
    hold_at(&s, bottom, 200, 0.0f, 0.0f);
    ramp(&s, bottom, top, 1200, 0.0f, 0.45f, 0.0f, 0.0f);
    ramp(&s, top, bottom, 1200, 0.0f, 0.35f, 0.0f, 0.0f);

    /* Only half the hold, then straight into the next curl. */
    hold_at(&s, bottom, REP_HOLD_MS / 2, 0.0f, 0.0f);
    ramp(&s, bottom, top, 1200, 0.0f, 0.45f, 0.0f, 0.0f);

    CHECK(s.completed == 0, "nothing counted on an early release (%d)",
          s.completed);
}

static void test_partial_range(void)
{
    printf("\n[6] a curl short of 80 %% of target is a partial\n");
    sim_t s; sim_reset(&s);
    setup(NULL);

    /* Target 110, so the peak criterion is 88 + angle_min. Stop at 70. */
    const float bottom = 10.0f;
    hold_at(&s, bottom, 200, 0.0f, 0.0f);
    ramp(&s, bottom, 70.0f, 1000, 0.0f, 0.45f, 0.0f, 0.0f);
    ramp(&s, 70.0f, bottom, 1000, 0.0f, 0.35f, 0.0f, 0.0f);
    hold_at(&s, bottom, REP_HOLD_MS + 400, 0.0f, 0.0f);

    CHECK(s.completed == 0, "shallow curl not counted (%d)", s.completed);
    CHECK(s.abandoned  > 0, "reported as a partial (%d)", s.abandoned);
}

static void test_timeout(void)
{
    printf("\n[7] a repetition exceeding the phase timeout is abandoned\n");
    sim_t s; sim_reset(&s);
    setup(NULL);

    const float bottom = 10.0f;
    hold_at(&s, bottom, 200, 0.0f, 0.0f);
    /* Climb past the start threshold, then stall well short of the peak band
     * for longer than the 10 s timeout. The 21 Oct session contained 16.6 s
     * and 24.7 s "repetitions". */
    ramp(&s, bottom, 60.0f, 2000, 0.0f, 0.45f, 0.0f, 0.0f);
    hold_at(&s, 60.0f, 12000, 0.0f, 0.45f);

    CHECK(s.abandoned > 0, "timed out and reported (%d)", s.abandoned);
    CHECK(s.completed == 0, "not counted (%d)", s.completed);
}

static void test_set_complete(void)
{
    printf("\n[8] set completion fires at rep_target\n");

    const uint8_t targets[] = { 5, 20 };
    for (unsigned k = 0; k < sizeof(targets); k++) {
        rehab_runtime_cfg_t cfg;
        rehab_cfg_defaults(&cfg);
        cfg.rep_target = targets[k];

        sim_t s; sim_reset(&s);
        setup(&cfg);

        for (int i = 0; i < targets[k] + 2; i++) {
            good_rep(&s, 2400);
        }

        CHECK(s.set_completes == 1,
              "target %u: set-complete fired exactly once (%d)",
              targets[k], s.set_completes);
        CHECK(s.completed >= targets[k],
              "target %u: reached the target (%d counted)",
              targets[k], s.completed);
    }
}

static void test_soft_click(void)
{
    printf("\n[9] the soft click fires once per repetition at 80 %% of target\n");
    sim_t s; sim_reset(&s);
    setup(NULL);

    for (int i = 0; i < 3; i++) {
        good_rep(&s, 2400);
    }
    CHECK(s.peak_cues == 3, "one cue per repetition (%d for 3 reps)",
          s.peak_cues);
}

static void test_tempo(void)
{
    printf("\n[10] tempo is measured and scored against the window\n");

    /* Inside the 1.5-3.5 s window. */
    sim_t s; sim_reset(&s);
    setup(NULL);
    good_rep(&s, 2400);
    const uint8_t in_window = s.last_score;
    const float   tempo_in  = s.last_tempo;
    CHECK(tempo_in > 1.5f && tempo_in < 3.5f,
          "a 2.4 s repetition measures %.2f s, inside the window", tempo_in);

    /* Far too slow: 9 s, well outside. Same range, same smoothness. */
    sim_reset(&s);
    setup(NULL);
    good_rep(&s, 9000);
    const uint8_t too_slow = s.last_score;
    CHECK(s.last_tempo > cfg_tempo_max(),
          "a 9 s repetition measures %.2f s, outside the window",
          s.last_tempo);
    CHECK(too_slow < in_window,
          "the slow repetition scores lower: %u < %u", too_slow, in_window);
}

static void test_smoothness_peaks(void)
{
    printf("\n[11] smoothness counts pushes, and does not reward slowness\n");

    /* One smooth push. */
    sim_t s; sim_reset(&s);
    setup(NULL);
    good_rep(&s, 2400);
    const uint8_t smooth_peaks = s.last_peaks;
    CHECK(smooth_peaks <= 2, "a smooth curl registers %u velocity peak(s)",
          smooth_peaks);

    /* Four separate pushes over the same range and the same total time. */
    sim_reset(&s);
    setup(NULL);
    const float bottom = 10.0f, top = 110.0f;
    hold_at(&s, bottom, 200, 0.0f, 0.0f);
    float at = bottom;
    for (int i = 0; i < 4; i++) {
        const float next = bottom + (top - bottom) * (i + 1) / 4.0f;
        ramp(&s, at, next, 300, 0.0f, 0.45f, 0.0f, 0.0f);
        hold_at(&s, next, 100, 0.0f, 0.45f);   /* pause between pushes */
        at = next;
    }
    ramp(&s, top, bottom, 1200, 0.0f, 0.35f, 0.0f, 0.0f);
    hold_at(&s, bottom, REP_HOLD_MS + 200, 0.0f, 0.0f);

    CHECK(s.last_peaks > smooth_peaks,
          "a jerky curl registers more peaks (%u vs %u)",
          s.last_peaks, smooth_peaks);

    /* Slow and smooth versus fast and smooth: the tempo term separates them,
     * but smoothness itself must not. */
    sim_reset(&s);
    setup(NULL);
    good_rep(&s, 3200);
    const uint8_t slow_peaks = s.last_peaks;
    CHECK(slow_peaks == smooth_peaks,
          "moving slower does not buy a better peak count (%u vs %u)",
          slow_peaks, smooth_peaks);
}

static void test_compensation(void)
{
    printf("\n[12] compensation is flagged, counted, and scored down\n");

    sim_t clean; sim_reset(&clean);
    setup(NULL);
    good_rep(&clean, 2400);

    sim_t s; sim_reset(&s);
    setup(NULL);
    const float bottom = 10.0f, top = 110.0f;
    hold_at(&s, bottom, 200, 0.0f, 0.0f);
    /* Start clean — the posture gate refuses a repetition begun already
     * hiked — then hike to 25 deg mid-curl, past the 20 deg threshold. */
    ramp(&s, bottom, 45.0f, 500, 0.0f, 0.45f, 0.0f, 0.0f);
    ramp(&s, 45.0f, top, 900, 25.0f, 0.45f, 0.0f, 0.0f);
    ramp(&s, top, bottom, 1200, 25.0f, 0.35f, 0.0f, 0.0f);
    hold_at(&s, bottom, REP_HOLD_MS + 200, 0.0f, 0.0f);

    CHECK(s.completed == 1, "a compensated repetition still counts (%d)",
          s.completed);
    CHECK(s.last_comp & COMP_FLAG_SHOULDER, "shoulder flag set (0x%02X)",
          s.last_comp);
    CHECK(s.last_score < clean.last_score,
          "scored below a clean repetition: %u < %u",
          s.last_score, clean.last_score);
}

static void test_compensation_not_double_counted(void)
{
    printf("\n[13] a shoulder hike does not also register as trunk lean\n");
    sim_t s; sim_reset(&s);
    setup(NULL);

    /* Upper arm well past both thresholds, but no COMMON-MODE rotation: the
     * forearm is not being carried with it. Under the old inference this set
     * both flags and cost -35 instead of -20. */
    const float bottom = 10.0f, top = 110.0f;
    hold_at(&s, bottom, 200, 0.0f, 0.0f);
    ramp(&s, bottom, 45.0f, 500, 0.0f, 0.45f, 0.0f, 0.0f);
    ramp(&s, 45.0f, top, 900, 30.0f, 0.45f, 0.0f, 0.0f);
    ramp(&s, top, bottom, 1400, 30.0f, 0.35f, 0.0f, 0.0f);
    hold_at(&s, bottom, REP_HOLD_MS + 200, 0.0f, 0.0f);

    CHECK(s.last_comp & COMP_FLAG_SHOULDER, "shoulder flagged (0x%02X)",
          s.last_comp);
    CHECK(!(s.last_comp & COMP_FLAG_TRUNK),
          "trunk NOT flagged by the same deviation (0x%02X)", s.last_comp);

    /* A real trunk lean: both segments rotating together. */
    sim_reset(&s);
    setup(NULL);
    hold_at(&s, bottom, 200, 0.0f, 0.0f);
    ramp(&s, bottom, 45.0f, 500, 0.0f, 0.45f, 0.0f, 0.0f);
    ramp(&s, 45.0f, top, 900, 14.0f, 0.45f, 0.0f, 14.0f);
    ramp(&s, top, bottom, 1400, 14.0f, 0.35f, 0.0f, 14.0f);
    hold_at(&s, bottom, REP_HOLD_MS + 200, 0.0f, 0.0f);
    CHECK(s.last_comp & COMP_FLAG_TRUNK,
          "common-mode rotation flags trunk lean (0x%02X)", s.last_comp);
}

static void test_start_posture_gate(void)
{
    printf("\n[16] a repetition begun already hiked is refused\n");
    sim_t s; sim_reset(&s);
    setup(NULL);

    const float bottom = 10.0f, top = 110.0f;
    hold_at(&s, bottom, 200, 30.0f, 0.0f);
    ramp(&s, bottom, top, 1200, 30.0f, 0.45f, 0.0f, 0.0f);
    ramp(&s, top, bottom, 1200, 30.0f, 0.35f, 0.0f, 0.0f);
    hold_at(&s, bottom, REP_HOLD_MS + 200, 30.0f, 0.0f);

    CHECK(s.started == 0, "never armed from a hiked start (%d)", s.started);
    CHECK(s.completed == 0, "nothing counted (%d)", s.completed);
}

static void test_runtime_config(void)
{
    printf("\n[14] host configuration takes effect [PRD §5.9.1]\n");

    /* A shorter hold must still count, and a longer one must not count a
     * repetition that held only the default. */
    rehab_runtime_cfg_t cfg;
    rehab_cfg_defaults(&cfg);
    cfg.hold_duration_ms = 400;

    sim_t s; sim_reset(&s);
    setup(&cfg);
    const float bottom = 10.0f, top = 110.0f;
    hold_at(&s, bottom, 200, 0.0f, 0.0f);
    ramp(&s, bottom, top, 1200, 0.0f, 0.45f, 0.0f, 0.0f);
    ramp(&s, top, bottom, 1200, 0.0f, 0.35f, 0.0f, 0.0f);
    hold_at(&s, bottom, 600, 0.0f, 0.0f);     /* 600 ms: enough for 400 */
    CHECK(s.completed == 1, "a 400 ms hold counts with hold_duration 400 (%d)",
          s.completed);

    rehab_cfg_defaults(&cfg);
    cfg.hold_duration_ms = 2500;
    sim_reset(&s);
    setup(&cfg);
    hold_at(&s, bottom, 200, 0.0f, 0.0f);
    ramp(&s, bottom, top, 1200, 0.0f, 0.45f, 0.0f, 0.0f);
    ramp(&s, top, bottom, 1200, 0.0f, 0.35f, 0.0f, 0.0f);
    hold_at(&s, bottom, 1200, 0.0f, 0.0f);    /* 1.2 s: short of 2.5 */
    CHECK(s.completed == 0, "the same hold does not count at 2500 ms (%d)",
          s.completed);

    /* A lower target angle makes a shallower curl acceptable. */
    rehab_cfg_defaults(&cfg);
    cfg.target_angle_deg = 60.0f;             /* peak criterion at 48 */
    sim_reset(&s);
    setup(&cfg);
    hold_at(&s, bottom, 200, 0.0f, 0.0f);
    ramp(&s, bottom, 65.0f, 1200, 0.0f, 0.45f, 0.0f, 0.0f);
    ramp(&s, 65.0f, bottom, 1200, 0.0f, 0.35f, 0.0f, 0.0f);
    hold_at(&s, bottom, REP_HOLD_MS + 200, 0.0f, 0.0f);
    CHECK(s.completed == 1, "a 55 deg curl counts against a 60 deg target (%d)",
          s.completed);
}

static void test_activation_detector(void)
{
    printf("\n[15] the activation detector has hysteresis [PRD §5.4]\n");

    activation_det_t d;
    activation_init(&d, 0.010f, 0.002f, 1.0f, FEATURE_RATE_HZ);

    CHECK(d.on_thresh >= d.off_thresh,
          "ON threshold is not below OFF (%.4f >= %.4f)",
          d.on_thresh, d.off_thresh);

    /* A single tick above the threshold must not assert: the confirmation
     * window exists so that a noise spike cannot start a repetition. */
    CHECK(!activation_update(&d, 0.80f), "one tick above does not assert");

    for (int i = 0; i < 10; i++) activation_update(&d, 0.80f);
    CHECK(d.on, "sustained activation asserts");

    /* One tick below must not release. */
    CHECK(activation_update(&d, 0.0f), "one tick below does not release");

    for (int i = 0; i < 20; i++) activation_update(&d, 0.0f);
    CHECK(!d.on, "sustained quiet releases");

    /* Chatter around a single threshold must not produce transitions. */
    activation_reset(&d);
    const float mid = (d.on_thresh + d.off_thresh) * 0.5f;
    int transitions = 0;
    bool prev = d.on;
    for (int i = 0; i < 100; i++) {
        const bool now = activation_update(&d, mid + ((i % 2) ? 1e-4f : -1e-4f));
        if (now != prev) transitions++;
        prev = now;
    }
    CHECK(transitions <= 1, "chatter at the boundary produces %d transition(s)",
          transitions);
}

int main(void)
{
    printf("=== repetition cycle, PRD v1.4 ===\n");

    test_ten_reps();
    test_passive_swing();
    test_gate_needs_both();
    test_counted_on_return();
    test_early_release();
    test_partial_range();
    test_timeout();
    test_set_complete();
    test_soft_click();
    test_tempo();
    test_smoothness_peaks();
    test_compensation();
    test_compensation_not_double_counted();
    test_start_posture_gate();
    test_runtime_config();
    test_activation_detector();

    printf("\n%s (%d failure%s)\n",
           g_failures ? "FAILURES" : "all checks passed",
           g_failures, g_failures == 1 ? "" : "s");
    return g_failures ? 1 : 0;
}
