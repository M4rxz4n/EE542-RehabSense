/*
 * ble_service.h — RehabSense GATT service
 *
 * THIS IS THE INTERFACE CONTRACT with the Python host client. Freeze it
 * before either side writes code against it. Everything is little-endian.
 *
 * Service   A5B10001-7C4E-4D9A-9E3F-1D2C3B4A5968
 *   0002  Control            write
 *   0003  Raw stream         notify
 *   0004  Events + features  notify
 *   0005  Device status      read, notify
 *   0006  Backfill           notify
 *   0007  Calibration record read, write
 *
 * Frames fit 180 bytes, not the 244 a 247-byte MTU allows: macOS caps ATT MTU
 * at 185 and bleak exposes no portable MTU request, so the conservative size
 * keeps one firmware working against any host.
 */

#ifndef BLE_SERVICE_H
#define BLE_SERVICE_H

#include "esp_err.h"
#include "rehab_types.h"
#include "emg_dsp.h"
#include "fusion.h"

/* ── Frame types ─────────────────────────────────────────────────────── */
#define FRAME_TYPE_EMG       0x01
#define FRAME_TYPE_IMU       0x02
#define FRAME_TYPE_FEATURES  0x03
#define FRAME_TYPE_EVENT     0x04

/* ── Control opcodes ─────────────────────────────────────────────────── */
#define CMD_START_SESSION        0x01   /* u8 exercise id          */
#define CMD_STOP_SESSION         0x02
#define CMD_START_CALIBRATION    0x03   /* u8 phase                */
#define CMD_ABORT_CALIBRATION    0x04
#define CMD_REQUEST_RECALIBRATION 0x05
#define CMD_ACK_SEQ              0x06   /* u32 highest contiguous  */
#define CMD_REQUEST_BACKFILL     0x07   /* u32 start, u32 end      */
#define CMD_SET_CONFIG           0x08   /* TLV                     */
#define CMD_GET_CONFIG           0x09
#define CMD_HAPTIC_TEST          0x0A   /* u8 pattern id           */
#define CMD_SET_TIME             0x0B   /* u64 host epoch us       */
#define CMD_POWER_OFF            0x0C

/* 14-byte header shared by every stream frame. */
typedef struct __attribute__((packed)) {
    uint8_t  type;
    uint32_t seq;
    uint64_t t_us;
    uint8_t  n;
} frame_header_t;

_Static_assert(sizeof(frame_header_t) == BLE_FRAME_HEADER_BYTES,
               "frame header must be 14 bytes — check packing");

typedef struct __attribute__((packed)) {
    uint8_t  fw_state;
    uint8_t  fault_code;
    uint8_t  battery_pct;
    uint16_t battery_mv;
    uint8_t  signal_quality[EMG_N_CHANNELS];
    uint32_t seq_oldest;
    uint32_t seq_newest;
    uint32_t clip_count[EMG_N_CHANNELS];
    uint8_t  flags;              /* bit0 psram_backed, bit1 gap_occurred */
    uint16_t rep_count;
    int64_t  host_time_offset_us;
} device_status_t;

/* Commands arrive here; the state machine owns what happens next. */
typedef void (*ble_command_cb_t)(uint8_t opcode, const uint8_t *payload,
                                 size_t len);

esp_err_t ble_service_init(ble_command_cb_t on_command);
void      ble_service_start_advertising(void);
bool      ble_is_connected(void);

/* Publishers. Each returns ESP_ERR_INVALID_STATE when no host is subscribed,
 * which the caller treats as normal rather than an error: a dropped link must
 * not change anything about the exercise. */
esp_err_t ble_notify_emg(const emg_frame_t *frames, size_t n, uint32_t seq);
esp_err_t ble_notify_imu(const imu_sample_t *upper, const imu_sample_t *fore,
                         size_t n, uint32_t seq);
esp_err_t ble_notify_features(const features_t *f, uint32_t seq);
esp_err_t ble_notify_event(const rehab_event_t *evt);
esp_err_t ble_notify_backfill(const emg_frame_t *frames, size_t n, uint32_t seq);

void ble_update_status(const device_status_t *status);

#endif /* BLE_SERVICE_H */
