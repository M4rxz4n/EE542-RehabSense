/*
 * rehab_config.h — RehabSense firmware configuration
 *
 * Single source of truth for the pin map and every tunable constant.
 * Hardware target: ESP32-S3-DevKitC-1 v1.1, module ESP32-S3-WROOM-1 N8R8
 *                  (8 MB flash, 8 MB octal PSRAM)
 *
 * Design doc: "RehabSense Firmware Design — Prototype v0.1"
 *
 * The design invariant: channel-to-muscle mapping, electrode sites, thresholds,
 * hold durations and scoring weights are all configuration. Changing which
 * muscle pair is measured touches this file only.
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
 * ──────────────────────────────────────────────────────────────────────── */

#define EMG_N_CHANNELS         2
#define EMG_SAMPLE_RATE_HZ     2000               /* per channel */
#define EMG_TOTAL_CONV_HZ      (EMG_SAMPLE_RATE_HZ * EMG_N_CHANNELS)
#define EMG_DMA_FRAME_SAMPLES  64                 /* per channel, ~32 ms */

#define IMU_SAMPLE_RATE_HZ     100
#define IMU_PERIOD_MS          (1000 / IMU_SAMPLE_RATE_HZ)

#define FEATURE_RATE_HZ        50                 /* envelope + angle output */
#define ANALYSIS_PERIOD_MS     (1000 / FEATURE_RATE_HZ)

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

/* ────────────────────────────────────────────────────────────────────────
 * IMU fusion
 * ──────────────────────────────────────────────────────────────────────── */

#define MADGWICK_BETA          0.08f    /* tune on bench data in week 1 */

/* Rest-phase re-anchor: both IMUs quiet for this long re-levels to gravity. */
#define ZUPT_GYRO_DPS          3.0f
#define ZUPT_ACCEL_TOL_G       0.05f
#define ZUPT_HOLD_MS           300

/* ────────────────────────────────────────────────────────────────────────
 * Repetition cycle — hold-gated
 *
 * Bands are fractions of the patient's calibrated ROM, never absolute angles.
 * ──────────────────────────────────────────────────────────────────────── */

#define REP_EXTENDED_BAND_FRAC 0.10f    /* angle_min .. angle_min + 10 % ROM */
#define REP_FLEXED_BAND_FRAC   0.85f    /* angle_min + 85 % ROM .. angle_max */
#define REP_HOLD_MS            1000     /* hold at each end to count         */
#define REP_PHASE_TIMEOUT_MS   10000    /* concentric/eccentric abandon time */

/* A hold means stationary, not merely "inside the band". The timer does not
 * start until the limb has settled below this, and restarts if it moves off
 * again. Without this the 1 s window begins while the patient is still
 * travelling, which both shortens the real hold and makes the steadiness
 * measure punish anyone who curls further past the band edge. */
#define REP_HOLD_MAX_VEL_DPS   15.0f

/* Start-position gate */
#define START_POS_UPPER_ARM_TOL_DEG  15.0f

/* ────────────────────────────────────────────────────────────────────────
 * Compensation detection — evaluated during CONCENTRIC and ECCENTRIC only
 * ──────────────────────────────────────────────────────────────────────── */

#define COMP_SHOULDER_HIKE_DEG     15.0f
#define COMP_TRUNK_LEAN_DEG        10.0f
#define COMP_ARM_SWING_DPS         30.0f
#define COMP_ARM_SWING_SUSTAIN_MS  200
#define COMP_CONFIRM_MS            30      /* attitude thresholds confirm fast */

/* ────────────────────────────────────────────────────────────────────────
 * Grading — weights sum to 1.0, penalties subtract, result clamped 0..100
 * ──────────────────────────────────────────────────────────────────────── */

#define GRADE_W_RANGE          0.40f
#define GRADE_W_ACTIVATION     0.25f
#define GRADE_W_SMOOTHNESS     0.20f
#define GRADE_W_HOLD_STEADY    0.15f

#define PENALTY_SHOULDER_HIKE  20.0f
#define PENALTY_TRUNK_LEAN     15.0f
#define PENALTY_ARM_SWING      15.0f
#define PENALTY_COCONTRACTION  15.0f    /* scaled by how far over threshold */

#define COCONTRACTION_THRESHOLD 0.35f   /* antagonist/agonist activation ratio */

/* ────────────────────────────────────────────────────────────────────────
 * Fatigue
 * ──────────────────────────────────────────────────────────────────────── */

#define FATIGUE_MDF_SLOPE_THRESH  -0.5f  /* Hz per repetition */
#define FATIGUE_CONSEC_REPS       3

/* ────────────────────────────────────────────────────────────────────────
 * Calibration protocol
 * ──────────────────────────────────────────────────────────────────────── */

#define CALIB_REST_MS          10000
#define CALIB_MVC_ATTEMPTS     3
#define CALIB_MVC_HOLD_MS      5000
#define CALIB_MVC_REST_MS      15000
#define CALIB_NEUTRAL_MS       5000
#define CALIB_ROM_SWEEP_REPS   2

/* Below this multiple of the rest baseline, a measured MVC is not believable. */
#define CALIB_MVC_MIN_SNR      3.0f

#define CALIB_PROFILE_STALE_DAYS  14
#define NVS_NAMESPACE          "rehabsense"
#define NVS_KEY_CALIB          "calib"

/* ────────────────────────────────────────────────────────────────────────
 * Haptics — Adafruit 1201 ERM via DRV2605L
 *
 * Patterns are distinguished by RHYTHM, not intensity: an ERM's vibration
 * frequency is coupled to its amplitude, so "stronger" also means "faster"
 * and cannot carry independent meaning.
 *
 * Minimum gap between pulses is 60 ms — that is what active braking through
 * the driver buys. Without it the floor would be ~120 ms.
 * ──────────────────────────────────────────────────────────────────────── */

#define HAPTIC_PWM_HZ          20000
#define HAPTIC_PWM_RES_BITS    10
#define HAPTIC_PWM_ZERO_DUTY   512      /* 50 % = no drive in PWM input mode */
#define HAPTIC_MIN_GAP_MS      60

/* TODO(hardware): confirm from the Adafruit 1201 datasheet before writing
 * auto-calibration. The 1201 runs 2-5 V; 3.0 V rated with a 3.3 V clamp is the
 * starting assumption. Wrong values here produce a weak or buzzy actuator. */
#define ERM_RATED_VOLTAGE_V    3.0f
#define ERM_OVERDRIVE_CLAMP_V  3.3f

/* ────────────────────────────────────────────────────────────────────────
 * Buffering
 *
 * Raw payload ≈ 10.4 kB/s:
 *   EMG  2 ch × 2000 Hz × 2 B = 8000 B/s
 *   IMU  2 × 100 Hz × 12 B    = 2400 B/s
 * ──────────────────────────────────────────────────────────────────────── */

#define TIER1_SECONDS          8        /* live ring in internal SRAM */
#define TIER2_SECONDS          600      /* session store in PSRAM, 10 min */

#define TIER1_EMG_SAMPLES      (EMG_SAMPLE_RATE_HZ * TIER1_SECONDS)
#define TIER2_EMG_SAMPLES      (EMG_SAMPLE_RATE_HZ * TIER2_SECONDS)
#define TIER1_IMU_SAMPLES      (IMU_SAMPLE_RATE_HZ * TIER1_SECONDS)
#define TIER2_IMU_SAMPLES      (IMU_SAMPLE_RATE_HZ * TIER2_SECONDS)

/* ────────────────────────────────────────────────────────────────────────
 * BLE
 *
 * Frames are sized to fit 180 bytes, not the 244 a 247-byte MTU allows:
 * macOS caps ATT MTU at 185 and bleak exposes no portable MTU request.
 * ──────────────────────────────────────────────────────────────────────── */

#define BLE_DEVICE_NAME        "RehabSense"
#define BLE_FRAME_MAX_BYTES    180
#define BLE_FRAME_HEADER_BYTES 14

#define BLE_EMG_BATCH          40       /* 40 × 4 B + 14 = 174 B, 50 frames/s */
#define BLE_IMU_BATCH          6        /*  6 × 24 B + 14 = 158 B, 16.7/s     */

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
