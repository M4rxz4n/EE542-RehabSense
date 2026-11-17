// sampler.h - the 100 Hz sampling tick shared by calibration and sessions.
#pragma once

void sampler_reset();                    // restart the 10 ms timebase (after a pause)
// Wait for the next 10 ms tick (keeping haptics running), then read every sensor.
// gU/gF (optional) receive raw gyro in deg/s for calibration.
void sampler_tick(float *gU = nullptr, float *gF = nullptr);
