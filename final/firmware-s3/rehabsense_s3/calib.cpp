#include <Arduino.h>
#include <ctype.h>
#include <string.h>
#include "rs_log.h"
#include "calib.h"
#include "imu.h"
#include "emg.h"
#include "haptic.h"
#include "rep.h"
#include "sampler.h"
#include "params.h"
#include "autopause.h"
#include "pace.h"
#include "progress.h"
#include "pins.h"
#include "ble.h"
#include "rs_proto.h"
#include "comms.h"

bool calibrated = false;
bool calibrating = false;
static bool autoMode = false;    // started from the app: steps move on by themselves after 3 s

// Bluetooth: run app commands that are safe mid-calibration; true if the app aborted
static bool aborted() {
  ble_tick();                    // keep status and live data flowing during countdowns
  ble_poll(true);
  return calibAbort;
}

static bool countdown(const char *msg, int secs = 3) {   // false if the app aborted
  Log.printf("\n>> %s in %d...", msg, secs);
  for (int i = secs - 1; i >= 0; i--) {
    haptic_play(HP_TICK);
    for (int k = 0; k < 10; k++) { haptic_wait(100); if (aborted()) { Log.println(); return false; } }
    if (i > 0) Log.printf(" %d...", i);
  }
  Log.println(" go");
  sampler_reset();
  return true;
}

// Wait for one of the keys in `allowed` (Serial Monitor or Bluetooth text), or the
// BOOT button, which counts as the first key in `allowed`. The sensors keep running.
// Started from the app (autoMode): moves on by itself after 3 s.
// Returns 0 if the app aborted calibration.
static char waitKey(const char *allowed, const char *prompt) {
  Log.printf(">> %s\n", prompt);
  while (Serial.available()) Serial.read();          // drop anything typed earlier
  bool lastBtn = digitalRead(PIN_BUTTON);
  uint32_t btnChanged = millis(), lastNote = millis(), started = millis();
  if (autoMode) Log.println(">> (started from the app: moving on in 3 s)");
  sampler_reset();
  for (;;) {
    sampler_tick();
    if (aborted()) return 0;
    if (autoMode && millis() - started > 3000) { haptic_play(HP_TICK); return allowed[0]; }
    for (int c; (c = Serial.available() ? Serial.read() : comms_read_injected()) >= 0; ) {
      char ch = tolower((char)c);
      if (ch && strchr(allowed, ch)) { haptic_play(HP_TICK); return ch; }
    }
    bool btn = digitalRead(PIN_BUTTON);
    if (btn != lastBtn && millis() - btnChanged > 30) {
      btnChanged = millis();
      lastBtn = btn;
      if (btn == LOW) {
        haptic_play(HP_TICK);
        while (digitalRead(PIN_BUTTON) == LOW) sampler_tick();   // wait for release, so it isn't read twice
        for (int i = 0; i < 5; i++) sampler_tick();              // 50 ms debounce
        return allowed[0];
      }
    }
    if (millis() - lastNote > 15000) { Log.printf(">> %s\n", prompt); lastNote = millis(); }
  }
}

// Straight-arm reference: up to 3 tries. Fails if either IMU turns faster than
// 20 deg/s during the 2 s hold, or the angle isn't ~0 just after saving.
// Returns false after 3 failed tries; the old reference is kept.
bool calib_straight() {
  for (int attempt = 1; attempt <= 3; attempt++) {
    if (!countdown("Let your arm hang down, as straight as is comfortable. Keep it still for 2 s")) return false;
    Quat acc = {0, 0, 0, 0};
    float worst = 0;
    for (int i = 0; i < 2 * (int)SAMPLE_HZ; i++) {
      sampler_tick();
      if (i % 10 == 0 && aborted()) return false;
      worst = fmaxf(worst, gyroMagDeg);
      Quat r = imu_relative();
      if (r.w < 0) r = {-r.w, -r.x, -r.y, -r.z};   // keep the same hemisphere
      acc.w += r.w; acc.x += r.x; acc.y += r.y; acc.z += r.z;
    }
    if (worst > 20.0f) {
      Log.printf("Try %d of 3: your arm moved a little (%.0f deg/s).\n", attempt, worst);
      haptic_play(HP_REP_FLAGGED);
      continue;
    }
    Quat old = qCal;
    float nq = sqrtf(acc.w * acc.w + acc.x * acc.x + acc.y * acc.y + acc.z * acc.z);
    qCal = {acc.w / nq, acc.x / nq, acc.y / nq, acc.z / nq};
    for (int i = 0; i < (int)(SAMPLE_HZ / 2); i++) sampler_tick();   // 0.5 s, still straight
    if (angleDeg > 5.0f) {
      // Should read ~0 right after saving. If not, the arm moved or bent during the hold.
      Log.printf("Try %d of 3: that reads %.1f deg instead of ~0, so the arm probably moved.\n",
                    attempt, angleDeg);
      qCal = old;
      haptic_play(HP_REP_FLAGGED);
      continue;
    }
    imu_save_upper_pose();                           // [FC4] reference for shoulder / lean checks
    Log.printf("Straight-arm reference saved (0 deg). Angle now %.1f deg\n", angleDeg);
    return true;
  }
  return false;
}

// Calibration ended without finishing: aborted from the app, or the straight arm failed
static void calibFail(const char *why, uint8_t phase) {
  calibrating = false;
  calibAbort = false;
  autoMode = false;
  imuBeta = BETA_RUN;
  ble_calib_phase(phase, 0);
  ble_calib_phase(wire::CP_FAILED, 0);
  haptic_play(HP_FAULT);
  Log.printf("=== Calibration stopped: %s. Type c (or press BOOT) to calibrate again. ===\n", why);
  sampler_reset();
}

void calibrate(bool fromApp) {
  calibrated = false;
  calibrating = true;
  calibAbort = false;
  autoMode = fromApp;
  ble_tick();                    // STATE_CHANGE -> CALIBRATION straight away
  Log.println("\n=== Calibration ===");
  if (fromApp) Log.println("Started from the app: each step starts by itself after 3 s.");
  else         Log.println("Sit comfortably with your elbow by your side. Type n (or press BOOT) to move on after each step.");
  imuBeta = BETA_SETTLE;

  // 1. Rest, 5 s: EMG rest level + gyro bias
  ble_calib_phase(wire::CP_REST, 0);
  if (!countdown("Step 1 of 3: rest your arm and let it relax completely for 5 s", 5))
    return calibFail("aborted from the app", wire::CP_REST);
  float sumU[3] = {0, 0, 0}, sumF[3] = {0, 0, 0}, emgSum = 0, emgSq = 0;
  int n = 0;
  for (int k = 0; k < 3; k++) biasU[k] = biasF[k] = 0;
  for (int i = 0; i < 5 * (int)SAMPLE_HZ; i++) {
    float gU[3] = {0, 0, 0}, gF[3] = {0, 0, 0};
    sampler_tick(gU, gF);
    if (i % 10 == 0 && aborted()) return calibFail("aborted from the app", wire::CP_REST);
    if (i >= (int)SAMPLE_HZ) {                // skip the first second
      for (int k = 0; k < 3; k++) { sumU[k] += gU[k]; sumF[k] += gF[k]; }
      emgSum += emgMv;
      emgSq  += emgMv * emgMv;
      n++;
    }
  }
  for (int k = 0; k < 3; k++) { biasU[k] = sumU[k] / n; biasF[k] = sumF[k] / n; }
  emgRestMv = emgSum / n;
  emgRestSd = sqrtf(fmaxf(emgSq / n - emgRestMv * emgRestMv, 0.0f));   // [FC1] rest noise
  Log.printf("[FC1] Rest EMG noise %.1f mV (SD)\n", emgRestSd);
  Log.printf("Rest EMG %.0f mV, gyro bias upper %.2f/%.2f/%.2f, fore %.2f/%.2f/%.2f deg/s\n",
             emgRestMv, biasU[0], biasU[1], biasU[2], biasF[0], biasF[1], biasF[2]);
  for (int i = 0; i < (int)SAMPLE_HZ; i++) sampler_tick();   // settle with bias removed
  imuBeta = BETA_RUN;
  haptic_play(HP_REP_OK);
  ble_calib_phase(wire::CP_REST, 100);
  Log.println("Step 1 done.");

  // 2. Straight arm: the 0 deg reference. 3 tries; after that, z gives 3 more
  //    (from the app: 2 more rounds by themselves, then calibration fails).
  if (!waitKey("n", "Type n (or press BOOT) for step 2 of 3: straight arm"))
    return calibFail("aborted from the app", wire::CP_STRAIGHT);
  Log.println("\nStep 2 of 3: straight arm");
  ble_calib_phase(wire::CP_STRAIGHT, 0);
  int rounds = 1;
  while (!calib_straight()) {
    if (calibAbort) return calibFail("aborted from the app", wire::CP_STRAIGHT);
    Log.println("Couldn't get a still, straight arm in 3 tries. Let your arm hang loose and relax.");
    if (fromApp && ++rounds > 3) return calibFail("no still, straight arm in 9 tries", wire::CP_STRAIGHT);
    if (!waitKey("z", "Type z (or press BOOT) to try 3 more times"))
      return calibFail("aborted from the app", wire::CP_STRAIGHT);
  }
  haptic_play(HP_REP_OK);
  ble_calib_phase(wire::CP_STRAIGHT, 100);
  Log.println("Step 2 done.");

  // 3. Comfortable bend + firm squeeze, 6 s: target angle and EMG 100% level.
  //    Never "as hard as you can": maximal effort can trigger spasticity and pain.
  if (!waitKey("n", "Type n (or press BOOT) for step 3 of 3: bend and squeeze"))
    return calibFail("aborted from the app", wire::CP_BICEPS);
  ble_calib_phase(wire::CP_BICEPS, 0);
  if (!countdown("Step 3 of 3: slowly bend your elbow as far as is comfortable, hold it there and squeeze your biceps firmly. Stop if it hurts"))
    return calibFail("aborted from the app", wire::CP_BICEPS);
  float emgPeak = emgRestMv, bendPeak = 0;
  for (int i = 0; i < 6 * (int)SAMPLE_HZ; i++) {
    sampler_tick();
    if (i % 10 == 0 && aborted()) return calibFail("aborted from the app", wire::CP_BICEPS);
    emgPeak  = max(emgPeak, emgMv);
    bendPeak = max(bendPeak, angleDeg);
  }
  emgMaxMv = emgPeak;
  if (emgMaxMv - emgRestMv < 100)
    Log.println("WARNING: very little EMG change. Check electrode contact, or turn up the MyoWare gain.");
  Log.printf("Max contraction EMG %.0f mV\n", emgMaxMv);
  emg_update();   // refresh thresholds with the new max
  Log.printf("[FC1] Biceps counts as working above %.0f mV (%.0f%%), relaxed below %.0f mV\n",
             emgOnMv, (emgOnMv - emgRestMv) / max(emgMaxMv - emgRestMv, 50.0f) * 100.0f, emgOffMv);
  if (bendPeak >= 40.0f) {
    P.target_deg = prog_choose_target(bendPeak);              // [AT1]
    Log.printf("Comfortable bend %.0f deg: target %.0f deg (a rep counts from %.0f deg)\n",
               bendPeak, P.target_deg, P.peak_fraction * P.target_deg);
  } else {
    Log.printf("Comfortable bend only %.0f deg: keeping target %.0f deg. Ask your therapist to set it (t<deg>).\n",
               bendPeak, P.target_deg);
  }
  haptic_play(HP_REP_OK);
  ble_calib_phase(wire::CP_BICEPS, 100);
  Log.println("Step 3 done. Now relax your arm and let it hang straight.");
  Log.println("=== Calibration done ===");
  Log.printf("# PARAMS target=%.0f peak=%.2f start=%.0f hyst=%.0f tempo=%.1f-%.1f muscle=%.0f sets=%dx%d rest=%d\n",
             P.target_deg, P.peak_fraction, P.start_deg, P.hyst_deg,
             P.tempo_min_s, P.tempo_max_s, P.muscle_on_pct, P.sets, P.reps_per_set, P.rest_s);
  ble_calib_phase(wire::CP_DONE, 100);
  ble_refresh_calib();
  ble_send_config();                 // the target may have changed [AT1]

  // 4. Reps start only when the user says so (from the app: after 3 s)
  if (!waitKey("g", "Type g (or press BOOT) to start your reps")) {
    // Calibration itself is complete and kept; only the start was cancelled
    calibrating = false; calibAbort = false; autoMode = false;
    rep_clear(); sessionDone = true; calibrated = true;
    Log.println("# Start cancelled from the app. Type r (or press START in the app) to begin.");
    return;
  }
  calibrating = false;
  autoMode = false;
  rep_clear();
  ap_reset();
  pace_reset();
  calibrated = true;
  haptic_play(HP_GO);
  if (P.pace_on)
    Log.printf("\nRep start! Set 1 of %d: %d curls. Follow the beats: tick = UP, steady buzz = HOLD, double tick = DOWN.\n\n",
               P.sets, P.reps_per_set);
  else
    Log.printf("\nRep start! Set 1 of %d: %d slow curls, about 2 s up, a short pause, 2-3 s down.\n\n",
               P.sets, P.reps_per_set);
  sampler_reset();
}
