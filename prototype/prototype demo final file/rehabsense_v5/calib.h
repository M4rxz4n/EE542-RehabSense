// calib.h - calibration (rest, straight arm, max contraction).
// Split into separately runnable steps with stillness checks on Fri 24 Oct.
#pragma once

extern bool calibrated;   // false until calibration has completed once
extern bool calibrating;  // true while calibration runs (Bluetooth status: CALIBRATION)

// fromApp: started over Bluetooth, so each step moves on by itself after 3 s
// (keys and BOOT still work). The app can abort it (ABORT_CALIBRATION).
void calibrate(bool fromApp = false);
bool calib_straight();   // straight-arm step only (command z). false if you kept moving
