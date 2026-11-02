// ble.h - Bluetooth LE link, speaking the team protocol from the EE542-RehabSense
// repo (final/firmware/main/ble/ble_service.h, final/python/rehab_protocol.py),
// so Aidan's Python client, the app and the session viewer all work with it.
//
// Service A5B10001-7C4E-4D9A-9E3F-1D2C3B4A5968, characteristics A5B1000N-...:
//   0002 Control       write          opcode + payload (team opcodes, plus 0x20 TEXT)
//   0003 Raw stream    notify         IMU frames (100 Hz, 6 per frame); no raw EMG frames
//   0004 Events        notify         feature frames (50 Hz) and event frames
//   0005 Status        read, notify   device_status_t, 29 bytes
//   0006 Backfill      notify         unused (nothing buffered)
//   0007 Calibration   read, write    calib_record_t, 104 bytes (writes accepted, ignored)
//   0008 Configuration read, notify   TLV block
//   0009 Transfer      read, notify   xfer_info_t (always "failed": no Wi-Fi on this board)
//   000A Messages      notify         every line the sleeve prints for people (see rs_log.h)
// Details: BLE_PROTOCOL.md.
#pragma once
#include <stdint.h>
#include <stddef.h>

extern volatile bool calibAbort;     // set by ABORT_CALIBRATION, checked by calibration

void ble_begin();
bool ble_connected();
void ble_tick();                     // every sampler tick: features 50 Hz, IMU frames, status 1 Hz
void ble_text_line(const char *s, size_t n);   // one printed line, to 000A
// Run the commands the app wrote. During calibration only text keys (n, z, g),
// abort, haptic tests and reads are handled; the rest wait until it finishes.
void ble_poll(bool inCalibration);

// Events (team ids)
void ble_rep(uint16_t indexInSet, uint8_t score, uint8_t romPct, float peakDeg,
             uint16_t compFlags, uint32_t durMs);
void ble_evt(uint8_t id, const uint8_t *payload = nullptr, uint8_t n = 0);
void ble_partial(uint16_t nextIndex, float peakDeg);
void ble_fatigue(int16_t signs, uint16_t reps);
void ble_set_complete(uint16_t repsInSet);       // 0xFFFF = stopped (no payload)
void ble_calib_phase(uint8_t phase, uint8_t pct);
void ble_fault(bool raised);

void ble_send_status();
void ble_send_config();
void ble_refresh_calib();
