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

// =========================================================================
// Where the signal comes from. Two sources, one contract: emg_begin() sets up
// the hardware and emg_read_mv() returns the envelope in millivolts. Nothing
// below this line knows which it got, and neither does any other module - the
// rep counter, the fatigue indicators and the printed effort percentages all
// work from emgMv.
//
// RS_EMG_SRC in pins.h selects, and says why the PCB's source is not written.
// =========================================================================

#if RS_EMG_SRC == RS_EMG_ADC1

void emg_begin() {
  // ESP32-S3 defaults to 13-bit; the original board gave 12. Pinned explicitly
  // so the numbers in a log mean the same thing whichever board produced it.
  // analogReadMilliVolts() applies the chip's own eFuse calibration either way,
  // so the millivolts this module works in are unaffected - but the raw counts
  // printed by the EMG test are not, and those get compared between boards.
  analogReadResolution(12);
  // Full attenuation: the MyoWare ENV output swings to its 3.3 V rail on a hard
  // squeeze, and a clipped maximum silently flattens every effort percentage
  // derived from it. The enum kept its original name; on the S3 it is 12 dB.
  analogSetPinAttenuation(PIN_EMG_BICEPS, ADC_11db);
  emgMv = emg_read_mv();
}

float emg_read_mv() {
  uint32_t sum = 0;
  for (int i = 0; i < 4; i++) sum += analogReadMilliVolts(PIN_EMG_BICEPS);
  return sum / 4.0f;
}

#elif RS_EMG_SRC == RS_EMG_ADS131M02

// The PCB's front end, which is not a MyoWare and not on ADC1. See pins.h for
// why this is a build failure rather than a stub: a wrong number here is not a
// wrong reading, it is a wrong effort percentage, a wrong fatigue verdict and a
// wrong rep count, all of which look entirely plausible.
#error "RS_EMG_ADS131M02 is not implemented. The PCB's EMG path needs, from the \
board rather than from the schematic's net names: (1) the ADS131M02's CS pin, \
(2) its DRDY pin, (3) the CLKIN rate the LTC6903 is programmed to, and (4) the \
front end's gain and the ADC's oversampling ratio. It also needs a decision \
about the second channel, since the part has two and the board brings out two \
electrode jacks. Supply those and this backend is a small module; guess them \
and every number the sleeve reports is confidently wrong. Build without \
-DRS_EMG_SRC to use the MyoWare path on ADC1."

#else
  #error "RS_EMG_SRC must be RS_EMG_ADC1 or RS_EMG_ADS131M02 (see pins.h)."
#endif

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
