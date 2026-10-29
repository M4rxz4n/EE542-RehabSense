// rs_log.h - everything the sleeve prints for people goes through Log.
//
// Log writes to the Serial Monitor exactly as before AND, line by line, to the
// Bluetooth Messages characteristic (000A), so the session viewer receives the
// same REP / Partial / [FC] / [FT] / calibration lines it reads from a Serial
// log. The 20 Hz live data lines are NOT sent this way: Bluetooth carries them
// as binary feature frames (team protocol), which the viewer turns back into
// "t: angle: emg:" lines itself.
#pragma once
#include <Arduino.h>

class TeeLog : public Print {
 public:
  size_t write(uint8_t c) override;
  size_t write(const uint8_t *buf, size_t n) override;
 private:
  char   line[200];
  size_t len = 0;
};

extern TeeLog Log;
