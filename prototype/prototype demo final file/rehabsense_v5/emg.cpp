#include <Arduino.h>
#include "emg.h"
#include "params.h"
#include "pins.h"

float emgMv = 0, emgPct = 0;
float emgRestMv = 0, emgMaxMv = 1000;
float emgRestSd = 0;
bool  emgOn = false;
float emgOnMv = 0, emgOffMv = 0;
static uint16_t aboveMs = 0, belowMs = 0;

void emg_begin() {
  analogSetPinAttenuation(PIN_EMG_BICEPS, ADC_11db);
  emgMv = emg_read_mv();
}

float emg_read_mv() {
  uint32_t sum = 0;
  for (int i = 0; i < 4; i++) sum += analogReadMilliVolts(PIN_EMG_BICEPS);
  return sum / 4.0f;
}

void emg_update() {
  emgMv += EMG_SMOOTH * (emg_read_mv() - emgMv);
  float span = max(emgMaxMv - emgRestMv, 50.0f);
  emgPct = constrain((emgMv - emgRestMv) / span * 100.0f, 0.0f, 150.0f);

  // [FC1] Adaptive biceps-on (PRD): on above rest + 3 SD for 50 ms, off below
  // rest + 2 SD for 100 ms. Floors of 5% / 3% of the calibrated span stop a very
  // quiet rest recording from making the check too touchy.
  emgOnMv  = emgRestMv + max(3.0f * emgRestSd, 0.05f * span);
  emgOffMv = emgRestMv + max(2.0f * emgRestSd, 0.03f * span);
  const uint16_t tickMs = (uint16_t)(1000.0f / SAMPLE_HZ);
  if (emgMv > emgOnMv)  { aboveMs += tickMs; belowMs = 0; }
  else if (emgMv < emgOffMv) { belowMs += tickMs; aboveMs = 0; }
  else { aboveMs = 0; belowMs = 0; }
  if (!emgOn && aboveMs >= 50)  emgOn = true;
  if (emgOn  && belowMs >= 100) emgOn = false;
}
