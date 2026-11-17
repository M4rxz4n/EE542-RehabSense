// emg.h - MyoWare biceps channel.
#pragma once

extern float emgMv;              // smoothed reading, mV
extern float emgPct;             // % of calibrated maximum contraction
extern float emgRestMv, emgMaxMv;  // set by calibration
extern float emgRestSd;          // rest noise (SD, mV), set by calibration
extern bool  emgOn;              // [FC1] biceps "on": adaptive, with hysteresis and timing
extern float emgOnMv, emgOffMv;  // current on / off thresholds, mV

void  emg_begin();
float emg_read_mv();             // one averaged raw reading
void  emg_update();              // smoothing + % of max
