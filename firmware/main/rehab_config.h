/*
 * rehab_config.h — RehabSense firmware configuration
 *
 * Single source of truth for the pin map and every tunable constant.
 * Hardware target: ESP32-S3-DevKitC-1 v1.1, module ESP32-S3-WROOM-1 N8R8
 *                  (8 MB flash, 8 MB octal PSRAM)
 *
 * Design doc: "RehabSense Firmware — Firmware Design v1.0"
 * Normative source: RehabSense PRD v1.4 (22 October 2026).
 *
 * The design invariant: channel-to-muscle mapping, electrode sites, thresholds,
 * hold durations and scoring weights are all configuration. Changing which
 * muscle pair is measured touches this file only.
 *
 * Values here are DEFAULTS. Everything listed in PRD §5.9.1 is overridable at
 * runtime over BLE (see rehab_runtime_cfg_t and config.h); these constants are
 * what the device boots with and what it falls back to on a reset-to-defaults.
 */

#ifndef REHAB_CONFIG_H
#define REHAB_CONFIG_H

#include <stdint.h>

/* ────────────────────────────────────────────────────────────────────────
 * Pin map
 * Avoids: GPIO19-20 (USB D-/D+), GPIO26-32 (SPI flash),
 *         GPIO33-37 (octal PSRAM on the N8R8 module).
 * ──────────────────────────────────────────────────────────────────────── */

/* EMG — ADC1 only. ADC2 is unusable alongside the RF subsystem. */
#define PIN_EMG_A              4      /* ADC1_CH3 — biceps  (agonist by default) */
#define PIN_EMG_B              5      /* ADC1_CH4 — triceps (antagonist)         */
#define PIN_VBAT_SENSE         7      /* ADC1_CH6 — through a 2:1 divider        */

#define ADC_CHAN_EMG_A         ADC_CHANNEL_3
#define ADC_CHAN_EMG_B         ADC_CHANNEL_4
#define ADC_CHAN_VBAT          ADC_CHANNEL_6

/* IMUs — SPI2 (FSPI), one chip select each. */
#define PIN_SPI_SCK            12
#define PIN_SPI_MOSI           11     /* PICO on the SparkFun silkscreen */
#define PIN_SPI_MISO           13     /* POCI — the board's ADR pin      */
#define PIN_CS_IMU_UPPER       10
#define PIN_CS_IMU_FORE        14
#define SPI_IMU_HZ             (10 * 1000 * 1000)   /* BMI270 maximum */

/* Haptics — DRV2605L. I2C at boot only, PWM for the whole session. */
#define PIN_I2C_SDA            8
#define PIN_I2C_SCL            9
#define I2C_HZ                 400000
#define PIN_HAPTIC_PWM         6      /* -> DRV2605L IN/TRIG */
#define PIN_HAPTIC_EN          15     /* -> DRV2605L EN, hard mute without I2C */
#define DRV2605L_I2C_ADDR      0x5A

/* Status + input */
#define PIN_STATUS_LED         38     /* WS2812 on DevKitC-1 v1.1. v1.0 uses 48. */
#define PIN_BUTTON             0      /* On-board BOOT button */

/* ────────────────────────────────────────────────────────────────────────
 * Sampling
 *
 * Analysis runs at 50 Hz because the hold timers and the compensation
 * confirmation windows need that resolution. Feature frames go on air at
 * 20 Hz, which is all a live plot requires [PRD §12]; the saved bandwidth
 * belongs to the raw stream.
 * ──────────────────────────────────────────────────────────────────────── */

/* CHANNEL COUNT.
 *
 * Phase 1 prototype: ONE MyoWare 2.0 on the biceps — two electrodes on the
 * muscle belly ~20 mm apart plus one reference on the bony elbow landmark,
 * three electrodes in all.
 *
 * Phase 2 custom PCB: the integrated two-channel front end adds the triceps,
 * which restores the co-contraction score. Everything that needs a second
 * channel is guarded on this constant rather than deleted, so Phase 2 is a
 * change of 1 to 2 here and not a restoration of removed code.
 */
#define EMG_N_CHANNELS         1

#define EMG_CH_AGONIST         0      /* biceps brachii */
#if EMG_N_CHANNELS > 1
#define EMG_CH_ANTAGONIST      1      /* triceps brachii, Phase 2 */
#endif

#define EMG_SAMPLE_RATE_HZ     2000               /* per channel */
#define EMG_TOTAL_CONV_HZ      (EMG_SAMPLE_RATE_HZ * EMG_N_CHANNELS)
#define EMG_DMA_FRAME_SAMPLES  64                 /* per channel, ~32 ms */

#define IMU_SAMPLE_RATE_HZ     100
#define IMU_PERIOD_MS          (1000 / IMU_SAMPLE_RATE_HZ)

#define FEATURE_RATE_HZ        50                 /* internal analysis rate */
#define ANALYSIS_PERIOD_MS     (1000 / FEATURE_RATE_HZ)

#define FEATURE_TX_RATE_HZ     20                 /* feature frames on air  */
#define FEATURE_TX_DECIMATE    (FEATURE_RATE_HZ / FEATURE_TX_RATE_HZ)

/* ────────────────────────────────────────────────────────────────────────
 * DSP
 * ──────────────────────────────────────────────────────────────────────── */

#define EMG_HPF_HZ             20.0f    /* electrode drift + motion artefact */
#define EMG_LPF_HZ             450.0f
#define EMG_NOTCH_HZ           60.0f
#define EMG_NOTCH_Q            30.0f
#define EMG_NOTCH_HARMONIC     0        /* set 1 to add a 180 Hz notch */

#define EMG_RMS_WINDOW_MS      150      /* envelope smoothing window */
#define EMG_RMS_WINDOW_SAMPLES ((EMG_SAMPLE_RATE_HZ * EMG_RMS_WINDOW_MS) / 1000)

#define MDF_FFT_SIZE           512      /* 256 ms at 2 kSPS */
#define MDF_OVERLAP            256      /* 50 % */
#define MDF_MIN_ACTIVATION     0.15f    /* %MVC below which MDF is meaningless */

#define EMG_CLIP_MARGIN        0.01f    /* within 1 % of a rail counts as clipped */

/* The envelope is zeroed below rest × this multiple, so that noise does not
 * read as weak activation. activation.c places its thresholds on the same
 * scale; the two must use one constant or the muscle-on gate stops meaning
 * what calibration measured. */
#define EMG_NOISE_FLOOR_MULT   1.5f

/* ────────────────────────────────────────────────────────────────────────
 * Muscle activation detector [PRD §5.4]
 *
 * Replaces a fixed %MVC threshold, which cannot adapt to a session's own noise
 * floor. Rest mean and sigma both come from calibration step 1, per channel.
 *
 * The hysteresis matters as much as the thresholds: a single-threshold
 * detector chatters at the boundary, and chatter on this signal means
 * repetitions starting and abandoning at random.
 * ──────────────────────────────────────────────────────────────────────── */

#define ACT_ON_SIGMA           3.0f     /* rest mean + 3σ turns activation on  */
#define ACT_OFF_SIGMA          2.0f     /* below rest mean + 2σ turns it off   */
#define ACT_ON_CONFIRM_MS      50
#define ACT_OFF_CONFIRM_MS     100

/* If calibration produced no usable sigma (a degenerate rest capture), fall
 * back to this fraction of MVC so the detector still gates rather than failing
 * open. Failing open would silently restore the behaviour this replaces. */
#define ACT_FALLBACK_MVC_FRAC  0.10f

/* Floor on the normalised ON threshold. A very quiet rest capture can put 3σ
 * below the noise floor the DSP already zeroes, which would make the gate fire
 * on any non-zero sample — the opposite of gating. */
#define ACT_MIN_THRESH         0.02f

/* ────────────────────────────────────────────────────────────────────────
 * IMU fusion
 * ──────────────────────────────────────────────────────────────────────── */

#define MADGWICK_BETA          0.08f    /* tune on bench data in week 1 */

/* Rest-phase re-anchor: both IMUs quiet for this long re-levels to gravity. */
#define ZUPT_GYRO_DPS          3.0f
#define ZUPT_ACCEL_TOL_G       0.05f
#define ZUPT_HOLD_MS           300

/* ────────────────────────────────────────────────────────────────────────
 * Repetition cycle [PRD §5.4]
 *
 * A repetition begins when the biceps activates AND the arm rises past the
 * start threshold. It is counted when the arm has returned below the finish
 * threshold and been held still there for hold_duration_ms.
 *
 * Counting on the return means the score covers the whole movement including
 * the eccentric phase, and the confirming hold supplies the stationary moment
 * that both the haptic and the gravity re-anchor need.
 *
 * Thresholds are angles against the therapist's target, not fractions of
 * measured ROM: the therapist prescribes what the patient should reach, which
 * is not the same as what they currently can.
 * ──────────────────────────────────────────────────────────────────────── */

#define REP_TARGET_ANGLE_DEG   110.0f   /* therapist-set */
#define REP_PEAK_FRAC          0.80f    /* "target reached" = 80 % of target */
#define REP_START_ANGLE_DEG    15.0f    /* raise to 20 if extension is limited */
#define REP_FINISH_ANGLE_DEG   10.0f    /* 5° hysteresis below start           */

#define REP_HOLD_MS            1000     /* confirming hold, range 300..3000 */
#define REP_HOLD_MS_MIN        300
#define REP_HOLD_MS_MAX        3000
#define REP_PHASE_TIMEOUT_MS   10000    /* per-phase abandon time */

/* A hold means stationary, not merely "inside the band". The timer does not
 * start until the limb has settled below this, and restarts if it moves off
 * again. Without this the window begins while the patient is still travelling,
 * which both shortens the real hold and makes the steadiness measure punish
 * anyone who curls further past the band edge. */
#define REP_HOLD_MAX_VEL_DPS   15.0f

/* Direction reversal is taken from a low-passed velocity rather than a fixed
 * negative rate, which jitters at the top of a slow curl. */
#define REP_VEL_LPF_HZ         5.0f

/* Tempo window, start threshold to finish threshold, excluding the hold. */
#define REP_TEMPO_MIN_S        1.5f
#define REP_TEMPO_MAX_S        3.5f

/* Session structure */
#define REP_TARGET_DEFAULT     20       /* 1..50 */
#define REP_TARGET_MIN         1
#define REP_TARGET_MAX         50
#define SET_COUNT_DEFAULT      3
#define REST_SECONDS_DEFAULT   60

/* Start-position gate: the upper arm must be near its calibration attitude
 * before a repetition can arm, so a curl begun mid-hike is not counted clean. */
#define START_POS_UPPER_ARM_TOL_DEG  15.0f

/* ────────────────────────────────────────────────────────────────────────
 * Compensation detection — evaluated during the moving phases only
 * ──────────────────────────────────────────────────────────────────────── */

#define COMP_SHOULDER_HIKE_DEG     20.0f   /* [PRD §5.5] */
#define COMP_TRUNK_LEAN_DEG        10.0f   /* COMMON-MODE rotation of both IMUs */

/* Two rotation axes must point this nearly the same way before the movement
 * counts as common mode rather than as the two segments moving separately. */
#define COMMON_MODE_AXIS_DOT       0.70f
#define COMP_ARM_SWING_DPS         30.0f
#define COMP_ARM_SWING_SUSTAIN_MS  200
#define COMP_CONFIRM_MS            30      /* attitude thresholds confirm fast */

/* Sudden jolt: an acceleration spike on either IMU excludes that segment from
 * scoring rather than letting it read as a movement fault [PRD §5.5]. */
#define COMP_JOLT_G                2.5f

/* ────────────────────────────────────────────────────────────────────────
 * Grading [PRD §5.5]
 *
 * Four components, equal weight by default. Steadiness during the confirming
 * hold is computed and reported but does NOT contribute to the default score;
 * it is available as an optional fifth component.
 * ──────────────────────────────────────────────────────────────────────── */

#define GRADE_W_RANGE          0.25f
#define GRADE_W_TEMPO          0.25f
#define GRADE_W_SMOOTHNESS     0.25f

/* Co-contraction needs an antagonist envelope, which the single-channel
 * prototype does not have. Weighted zero here; grading normalises by the
 * weights actually in force, so the three remaining components take a third
 * each rather than the best achievable score being capped at 75. Phase 2
 * restores it along with the second channel. */
#if EMG_N_CHANNELS > 1
#define GRADE_W_COCONTRACTION  0.25f
#else
#define GRADE_W_COCONTRACTION  0.00f
#endif

#define GRADE_W_HOLD_STEADY    0.00f    /* optional fifth component, off */

#define PENALTY_SHOULDER_HIKE  20.0f
#define PENALTY_TRUNK_LEAN     15.0f
#define PENALTY_ARM_SWING      15.0f

/* Smoothness: count of velocity peaks exceeding this fraction of the
 * repetition's own peak velocity. A single peak scores 100; each additional
 * peak costs SMOOTH_PEAK_COST of the component [PRD §5.5]. */
#define SMOOTH_PEAK_FRAC       0.10f
#define SMOOTH_PEAK_COST       0.25f

/* Velocity peaks recorded per repetition. A movement with more corrections
 * than this already scores zero on smoothness, so the excess is not worth
 * storing. */
#define REP_MAX_VEL_PEAKS      32

/* Co-contraction: antagonist activation as a fraction of agonist, evaluated
 * only while the agonist is active, each normalised against its own calibrated
 * maximum. Zero overlap scores 100; at or above this ratio scores 0. */
#define COCON_ZERO_SCORE_RATIO 0.50f

/* ────────────────────────────────────────────────────────────────────────
 * Fatigue
 * ──────────────────────────────────────────────────────────────────────── */

#define FATIGUE_MDF_SLOPE_THRESH  -0.5f  /* Hz per repetition */
#define FATIGUE_CONSEC_REPS       3

/* ────────────────────────────────────────────────────────────────────────
 * Calibration protocol [PRD §5.3]
 *
 * Six steps, each separately commanded so a failed step can be repeated on its
 * own without restarting the protocol. Capture totals ~19 s, about 30 s
 * including prompts — against a Must of "under 30 s" in PRD §3.2.
 * ──────────────────────────────────────────────────────────────────────── */

#define CALIB_REST_MS          5000     /* step 1: rest baseline + gyro bias */
#define CALIB_STRAIGHT_MS      2000     /* step 2: comfortable-straight pose  */
#define CALIB_MVC_MS           3000     /* steps 3,4: per attempt             */
#define CALIB_MVC_WINDOW_MS    500      /* strongest window within an attempt */
#define CALIB_MVC_WINDOW_SAMPLES ((FEATURE_RATE_HZ * CALIB_MVC_WINDOW_MS) / 1000)
#define CALIB_MVC_ATTEMPTS     3        /* best of three                      */
#define CALIB_SWEEP_MS         6000     /* step 5: two slow full-range curls  */

/* Stillness gate for steps 1 and 2. Movement during the rest step corrupts
 * gyroscope bias and therefore the joint angle for the whole session, with no
 * obvious symptom; the gate exists to prevent exactly that [PRD §10.2]. */
#define CALIB_STILL_GYRO_DPS   5.0f
#define CALIB_STILL_ACCEL_TOL  0.08f    /* g, deviation from 1 g */
#define CALIB_STILL_GRACE_MS   400      /* brief wobble tolerated before reject */

/* Below this multiple of the rest baseline, a measured MVC is not believable. */
#define CALIB_MVC_MIN_SNR      3.0f

/* Contact check limits for step 0 [PRD §5.3]. */
#define CALIB_CONTACT_MS       4000

/* Single-channel placement test: the biceps envelope while the elbow is
 * moving must exceed its level while still by this factor. A pair on the
 * muscle belly clears it comfortably; a lifted, misplaced or dead electrode
 * does not. */
#define DON_MOVING_DPS         10.0f
#define DON_MIN_ACTIVE_RATIO   1.8f
#define CALIB_MAX_CLIP_COUNT   5        /* clipped samples tolerated in step 0 */
#define CALIB_MAX_MAINS_FRAC   0.25f    /* 60 Hz energy as a fraction of total */

#define CALIB_PROFILE_STALE_DAYS  14
#define NVS_NAMESPACE          "rehabsense"
#define NVS_KEY_CALIB          "calib"
#define NVS_KEY_CONFIG         "config"

/* ────────────────────────────────────────────────────────────────────────
 * Haptics — Adafruit 1201 ERM via DRV2605L
 *
 * ACTUATOR DECISION: the ERM is the production actuator for this project.
 * An ERM's vibration frequency is coupled to its amplitude, so "stronger" also
 * means "faster" and cannot carry independent meaning. Every pattern is
 * therefore distinguished by RHYTHM — pulse count, width and gap — and every
 * cue plays at ONE consistent amplitude, which is also easier for a patient to
 * learn than a set of intensity gradations [PRD §5.6].
 *
 * The one exception is the rest cue, which is a deliberate ramp: a change in
 * character, not a gradation, so it cannot be mistaken for a rep signal.
 *
 * Minimum gap between pulses is 60 ms — that is what active braking through
 * the driver buys. Without it the floor would be ~120 ms. The shortest gap any
 * pattern below asks for is 70 ms, so all of them clear it.
 * ──────────────────────────────────────────────────────────────────────── */

#define HAPTIC_PWM_HZ          20000
#define HAPTIC_PWM_RES_BITS    10
#define HAPTIC_PWM_ZERO_DUTY   512      /* 50 % = no drive in PWM input mode */
#define HAPTIC_MIN_GAP_MS      60
#define HAPTIC_OVERDRIVE_MS    20       /* kick at pulse onset */

/* Pattern timings [PRD §5.6]. */
#define HAP_CLEAN_MS           100      /* one sharp click                    */
#define HAP_FLAGGED_PULSE_MS   80       /* three pulses, 80 on / 80 off       */
#define HAP_FLAGGED_GAP_MS     80
#define HAP_SETDONE_PULSE_MS   70       /* two 70 ms pulses, 70 ms gaps,      */
#define HAP_SETDONE_GAP_MS     70       /*   then one 500 ms pulse            */
#define HAP_SETDONE_FINAL_MS   500
#define HAP_REST_RAMP_MS       1000     /* one ramp up and down               */
#define HAP_FAULT_PULSE_MS     300      /* two 300 ms pulses, 300 ms apart    */
#define HAP_FAULT_GAP_MS       300
#define HAP_TICK_MS            40       /* button acknowledgement             */

/* Soft click at 80 % of the target angle: "you may begin the return."
 * Deliberately the shortest and lightest cue in the set, because it fires
 * mid-movement where everything else fires at a stationary moment — it has to
 * read as a waypoint, not as a result. */
#define HAP_SOFT_CLICK_MS      30
#define HAP_SOFT_CLICK_LEVEL   0.55f

/* After the repetition that completes the set, the set-complete pattern
 * follows the per-repetition pattern after this gap, so the patient receives
 * both the quality result and confirmation that the set is finished. */
#define HAP_SET_COMPLETE_GAP_MS 300

/* A fault cue must finish before the enable pin is cut, or the fault state
 * silences its own warning [PRD §5.2]. Two 300 ms pulses with a 300 ms gap is
 * 900 ms; allow a margin. */
#define HAPTIC_FAULT_CUE_MS    900
#define HAPTIC_MUTE_DELAY_MS   (HAPTIC_FAULT_CUE_MS + 100)

/* Adafruit 1201 ERM. 2-5 V part; 3.0 V rated with a 3.3 V clamp.
 * TODO(hardware): confirm against the datasheet during bring-up. Wrong values
 * here produce a weak or buzzy actuator. */
#define ERM_RATED_VOLTAGE_V    3.0f
#define ERM_OVERDRIVE_CLAMP_V  3.3f

/* ────────────────────────────────────────────────────────────────────────
 * Buffering
 *
 * Raw payload ≈ 10.6 kB/s:
 *   EMG  2 ch × 2000 Hz × 2 B = 8000 B/s
 *   IMU  2 × 100 Hz × 12 B    = 2400 B/s
 *   Features 20 Hz            ≈  160 B/s
 * ──────────────────────────────────────────────────────────────────────── */

#define TIER1_SECONDS          8        /* live ring in internal SRAM */
#define TIER2_SECONDS          600      /* session store in PSRAM, 10 min */

#define TIER1_EMG_SAMPLES      (EMG_SAMPLE_RATE_HZ * TIER1_SECONDS)
#define TIER2_EMG_SAMPLES      (EMG_SAMPLE_RATE_HZ * TIER2_SECONDS)
#define TIER1_IMU_SAMPLES      (IMU_SAMPLE_RATE_HZ * TIER1_SECONDS)
#define TIER2_IMU_SAMPLES      (IMU_SAMPLE_RATE_HZ * TIER2_SECONDS)

/* ────────────────────────────────────────────────────────────────────────
 * Battery
 * ──────────────────────────────────────────────────────────────────────── */

#define VBAT_DIVIDER_RATIO     2.0f
#define VBAT_FULL_MV           4200
#define VBAT_EMPTY_MV          3300
#define VBAT_LOW_PCT           15       /* finish the set, then stop and save */
#define VBAT_SAMPLE_COUNT      8        /* averaged per housekeeping tick */

/* ────────────────────────────────────────────────────────────────────────
 * BLE
 *
 * Frames are sized to fit 180 bytes, not the 244 a 247-byte MTU allows:
 * macOS caps ATT MTU at 185 and bleak exposes no portable MTU request.
 * ──────────────────────────────────────────────────────────────────────── */

#define BLE_DEVICE_NAME        "RehabSense"
#define BLE_FRAME_MAX_BYTES    180
#define BLE_FRAME_HEADER_BYTES 14

/* Samples per EMG frame. Derived from the channel count so the frame stays
 * the same size whichever front end is fitted: each sample is 2 B per
 * channel, so 80 samples of one channel and 40 of two both come to
 * 14 + 160 = 174 B — inside the 180 B budget either way.
 *
 * Frame rate falls out of it: 2 kSPS / 80 = 25 frames/s on one channel,
 * 2 kSPS / 40 = 50 frames/s on two. */
#define BLE_EMG_BATCH          (80 / EMG_N_CHANNELS)
#define BLE_IMU_BATCH          6        /*  6 × 24 B + 14 = 158 B, 16.7/s     */

_Static_assert(BLE_FRAME_HEADER_BYTES +
                   BLE_EMG_BATCH * EMG_N_CHANNELS * 2 <= BLE_FRAME_MAX_BYTES,
               "EMG frame does not fit the 180-byte budget");

#define BLE_CONN_ITVL_MIN_MS   15
#define BLE_CONN_ITVL_MAX_MS   30
#define BLE_CONN_TIMEOUT_MS    4000
#define BLE_PREFERRED_MTU      247

/* ────────────────────────────────────────────────────────────────────────
 * Task priorities and core affinity
 *
 * The NimBLE host runs on core 0. Everything latency-sensitive goes on core 1
 * so radio activity cannot pre-empt it.
 * ──────────────────────────────────────────────────────────────────────── */

#define CORE_SENSOR            1
#define CORE_COMMS             0

#define PRIO_HAPTIC            22
#define PRIO_EMG_DSP           20
#define PRIO_IMU               18
#define PRIO_ANALYSIS          16
#define PRIO_BLE_TX            12
#define PRIO_STORAGE            8
#define PRIO_HOUSEKEEPING       5

#define STACK_EMG_DSP          8192
#define STACK_IMU              4096
#define STACK_ANALYSIS         6144
#define STACK_HAPTIC           2048
#define STACK_BLE_TX           6144
#define STACK_STORAGE          4096
#define STACK_HOUSEKEEPING     3072

#define QUEUE_DEPTH_FRAMES     4        /* overrun sets a flag, never blocks */

#endif /* REHAB_CONFIG_H */
