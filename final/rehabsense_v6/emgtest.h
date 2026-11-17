// emgtest.h - EMG signal-quality test (Serial command "e").
//
// Samples the MyoWare at 1 kHz: 3 s relaxed, then 3 s maximum squeeze, and reports
//   rest level and noise (standard deviation), mains hum at 60 and 120 Hz,
//   contraction level, signal-to-noise ratio, and clipping at the ADC limit.
#pragma once
#include <stdint.h>

// Running statistics for one phase. Pure maths, no hardware, so it can be unit-tested.
struct EmgStats {
  double n = 0, mean = 0, m2 = 0;     // Welford mean / variance
  float  mn = 1e9f, mx = -1e9f;
  uint32_t clipped = 0;
  // Goertzel accumulators for 60 Hz and 120 Hz (sampled at fs)
  double fs = 1000.0, x0 = 0;
  double s1a = 0, s2a = 0, s1b = 0, s2b = 0;
  bool first = true;

  void   add(float mv);
  float  sd() const;
  float  humRms(double hz) const;      // RMS of the 60 or 120 Hz component, mV
};

void emg_test();   // blocking; prompts with haptic ticks
