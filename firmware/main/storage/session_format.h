/*
 * session_format.h — on-the-wire layout of a downloaded session
 *
 * THIS IS THE INTERFACE CONTRACT with the host downloader. Everything here is
 * little-endian and explicitly packed, and host/rehab_session.py must agree
 * byte for byte. The _Static_asserts below exist so that a field added on one
 * side and forgotten on the other fails the build rather than silently
 * shifting every field after it — the same class of bug that already bit
 * device_status_t once.
 *
 * Why these are not the in-memory structs
 * ---------------------------------------
 * features_t carries a 64-bit absolute timestamp and seven floats, 48 bytes
 * with padding. At 50 Hz for ten minutes that is 1.4 MB of PSRAM to say what
 * 22 bytes of scaled integers say just as well: the sample index gives the
 * time, and no quantity here is known to better than three significant
 * figures. Fixed point also means the host parses with one struct.Struct and
 * no float-endianness questions.
 *
 * Scale factors are named once, here, and repeated in the manifest the device
 * serves, so a host that is a version behind can still read the file
 * correctly rather than silently mis-scaling it.
 */

#ifndef SESSION_FORMAT_H
#define SESSION_FORMAT_H

#include <stdint.h>
#include "rehab_config.h"

/* Bumped whenever any layout below changes. The manifest reports it and the
 * host refuses a file it does not understand. */
#define SESSION_FORMAT_VERSION   1

/* Fixed-point scales. Host divides by these. */
#define SCALE_ENVELOPE    1000.0f   /* %MVC × 1000, so 1.000 = full MVC */
#define SCALE_MDF           10.0f   /* Hz × 10                          */
#define SCALE_ANGLE         10.0f   /* degrees × 10                     */
#define SCALE_ACCEL       1000.0f   /* g × 1000                         */
#define SCALE_GYRO          10.0f   /* deg/s × 10                       */
#define SCALE_FRACTION    1000.0f   /* dimensionless 0..1 × 1000        */
#define SCALE_SECONDS     1000.0f   /* seconds × 1000, i.e. ms          */

/* ── EMG ─────────────────────────────────────────────────────────────────
 * Raw, full rate, exactly as acquired. No timestamp per sample: sample i
 * is at t_start_us + i × (1e6 / EMG_SAMPLE_RATE_HZ), which is true because
 * the ADC runs in continuous DMA mode off a hardware clock. This is the
 * whole reason the acquisition clock is never adjusted to match a phone. */
typedef struct __attribute__((packed)) {
    int16_t ch[EMG_N_CHANNELS];
} rec_emg_t;

_Static_assert(sizeof(rec_emg_t) == 2 * EMG_N_CHANNELS, "rec_emg_t packing");

/* ── IMU ─────────────────────────────────────────────────────────────────
 * Both sensors, accelerometer then gyroscope, upper arm then forearm.
 * Index 0 is the upper-arm sensor throughout the system. */
typedef struct __attribute__((packed)) {
    int16_t accel[2][3];          /* g × SCALE_ACCEL      */
    int16_t gyro[2][3];           /* deg/s × SCALE_GYRO   */
} rec_imu_t;

_Static_assert(sizeof(rec_imu_t) == 24, "rec_imu_t packing");

/* ── Derived features ────────────────────────────────────────────────────
 * The device's own calculations at FEATURE_RATE_HZ. The physician view shows
 * these rather than recomputing from raw, because the device is authoritative
 * for rep state, counts and compensation — if a host ever disagrees, that is a
 * firmware bug to fix, not a discrepancy to paper over in the UI.
 *
 * t_ms is relative to the session start, which keeps it in 32 bits for any
 * session length that fits in PSRAM and makes the record independent of the
 * device's boot time. */
typedef struct __attribute__((packed)) {
    uint32_t t_ms;
    int16_t  envelope[EMG_N_CHANNELS];   /* %MVC × SCALE_ENVELOPE */
    int16_t  mdf[EMG_N_CHANNELS];        /* Hz × SCALE_MDF        */
    int16_t  elbow_angle;                /* deg × SCALE_ANGLE     */
    int16_t  upper_arm_dev;              /* deg × SCALE_ANGLE     */
    uint16_t rep_count;
    uint8_t  rep_state;
    uint8_t  comp_flags;
    uint8_t  sig_flags;
    uint8_t  activation_on;
} rec_feature_t;

_Static_assert(sizeof(rec_feature_t) == 14 + 4 * EMG_N_CHANNELS,
               "rec_feature_t packing — update rehab_session.py to match");

/* ── Events ──────────────────────────────────────────────────────────────
 * The async event log, verbatim payloads. Fixed size per record so the host
 * can index straight into the file rather than walking it. */
typedef struct __attribute__((packed)) {
    uint32_t t_ms;
    uint8_t  id;                  /* event_id_t */
    uint8_t  payload_len;
    uint8_t  payload[16];
} rec_event_t;

_Static_assert(sizeof(rec_event_t) == 22, "rec_event_t packing");

/* ── Repetition results ──────────────────────────────────────────────────
 * One per completed repetition, including flagged ones. Nothing is silently
 * discarded, so an abandoned attempt appears in the event log even though it
 * produces no record here. */
typedef struct __attribute__((packed)) {
    uint32_t t_start_ms;
    uint32_t t_end_ms;
    uint16_t index;               /* 1-based within the set */
    int16_t  peak_angle;          /* deg × SCALE_ANGLE      */
    int16_t  rom_fraction;        /* × SCALE_FRACTION       */
    int16_t  tempo_ms;            /* ms, capped at int16    */
    int16_t  activation;          /* mean %MVC × SCALE_ENVELOPE */
    int16_t  cocontraction;       /* × SCALE_FRACTION       */
    int16_t  smoothness;          /* × SCALE_FRACTION       */
    int16_t  hold_steadiness;     /* × SCALE_FRACTION       */
    uint16_t comp_flags;
    uint8_t  velocity_peaks;
    uint8_t  score;               /* 0..100 */
} rec_rep_t;

_Static_assert(sizeof(rec_rep_t) == 28, "rec_rep_t packing");

#endif /* SESSION_FORMAT_H */
