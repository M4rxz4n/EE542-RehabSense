#include <Arduino.h>
#include "rs_log.h"
#include "emgtest.h"
#include "haptic.h"
#include "sampler.h"
#include "rep.h"
#include "pins.h"
#include "ble.h"

static const float CLIP_MV = 3000.0f;   // ESP32 ADC (11 dB) tops out near 3.1 V

void EmgStats::add(float mv) {
  if (first) { x0 = mv; first = false; }
  n += 1;
  double d = mv - mean;
  mean += d / n;
  m2 += d * (mv - mean);
  if (mv < mn) mn = mv;
  if (mv > mx) mx = mv;
  if (mv >= CLIP_MV) clipped++;
  double x = mv - x0;                   // remove the offset to keep Goertzel precise
  double ca = 2.0 * cos(2.0 * M_PI * 60.0 / fs);
  double cb = 2.0 * cos(2.0 * M_PI * 120.0 / fs);
  double sa = x + ca * s1a - s2a; s2a = s1a; s1a = sa;
  double sb = x + cb * s1b - s2b; s2b = s1b; s1b = sb;
}

float EmgStats::sd() const { return n > 1 ? (float)sqrt(m2 / (n - 1)) : 0; }

float EmgStats::humRms(double hz) const {
  if (n < 2) return 0;
  bool a = hz < 90;
  double s1 = a ? s1a : s1b, s2 = a ? s2a : s2b;
  double c = 2.0 * cos(2.0 * M_PI * hz / fs);
  double power = s1 * s1 + s2 * s2 - c * s1 * s2;
  double amp = 2.0 * sqrt(power > 0 ? power : 0) / n;   // sine peak amplitude
  return (float)(amp / sqrt(2.0));
}

static EmgStats capture(uint32_t ms) {
  EmgStats st;
  uint32_t t = micros();
  for (uint32_t i = 0; i < ms; i++) {                   // 1 sample per ms
    while (micros() - t < 1000) haptic_update();
    t += 1000;
    st.add((float)analogReadMilliVolts(PIN_EMG_BICEPS));
  }
  return st;
}

static void prompt(const char *msg) {
  Log.printf("# %s in 3...", msg);
  for (int i = 2; i >= 0; i--) {
    haptic_play(HP_TICK);
    for (int k = 0; k < 10; k++) { haptic_wait(100); ble_tick(); }   // keep Bluetooth (and the viewer) up to date
    if (i > 0) Log.printf(" %d...", i);
  }
  Log.println(" now");
}

void emg_test() {
  Log.println("\n# === EMG signal-quality test ===");
  Log.println("# Sit still. Laptop on battery, unplugged from the charger.");

  prompt("Relax your arm completely for 3 s");
  haptic_wait(300);                                     // let the arm settle
  Log.println("# Measuring: stay relaxed...");
  ble_tick();
  EmgStats rest = capture(3000);
  haptic_play(HP_TICK);

  prompt("Squeeze your biceps as hard as you can for 3 s");
  Log.println("# Measuring: keep squeezing...");
  ble_tick();
  EmgStats squeeze = capture(3000);
  haptic_play(HP_REP_OK);

  float noise = rest.sd();
  float rise  = (float)(squeeze.mean - rest.mean);
  float snr   = (noise > 0.1f && rise > 0) ? 20.0f * log10f(rise / noise) : 0;
  float h60 = rest.humRms(60), h120 = rest.humRms(120);
  float humPct = noise > 0 ? 100.0f * (h60 * h60 + h120 * h120) / (noise * noise) : 0;

  Log.println("#");
  Log.printf("# REST     mean %6.0f mV   noise (SD) %5.1f mV   range %4.0f..%4.0f mV\n",
                rest.mean, noise, rest.mn, rest.mx);
  Log.printf("#          mains hum: 60 Hz %.1f mV RMS, 120 Hz %.1f mV RMS (%.0f%% of the rest noise)\n",
                h60, h120, humPct);
  Log.printf("# SQUEEZE  mean %6.0f mV   peak %4.0f mV   rise above rest %5.0f mV\n",
                squeeze.mean, squeeze.mx, rise);
  Log.printf("# SNR      %.1f dB (squeeze rise / rest noise)\n", snr);
  Log.println("#");

  // Verdicts
  if (rest.mx < 5 && squeeze.mx < 5)
    Log.println("# FAIL  Signal is flat at 0 V: MyoWare not powered, or ENV not on GPIO34.");
  else if (rest.clipped > 0)
    Log.println("# FAIL  Signal is at the ADC limit even at rest: gain far too high, or an electrode is off.");
  else {
    if (snr >= 20)      Log.println("# PASS  SNR at least 20 dB: clean enough for rep detection and scoring.");
    else if (snr >= 10) Log.println("# WEAK  SNR 10-20 dB: usable, but improve contact or gain (see tips).");
    else                Log.println("# FAIL  SNR under 10 dB: rest and squeeze are hard to tell apart.");
    if (squeeze.clipped > squeeze.n * 0.01)
      Log.printf("# WARN  Squeeze clipped at the ADC limit for %.0f%% of samples: turn the gain down a little.\n",
                    100.0 * squeeze.clipped / squeeze.n);
    if (humPct > 30)
      Log.println("# WARN  Most of the rest noise is mains hum: check the black reference electrode, "
                     "keep leads short and away from cables, unplug the laptop charger.");
    if (rest.mean > 600)
      Log.println("# NOTE  Rest level is high: arm not fully relaxed, or gain set high.");
  }
  Log.println("# Tips: reseat electrodes with fresh gel, reference on the elbow bone, "
                 "red and blue 2-3 cm apart along the muscle, then run e again.");
  Log.println("# === End of EMG test ===\n");

  sampler_reset();
  rep_reset();
}
