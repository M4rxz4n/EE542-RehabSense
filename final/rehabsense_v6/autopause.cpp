#include <Arduino.h>
#include "rs_log.h"
#include "autopause.h"
#include "imu.h"
#include "rep.h"
#include "haptic.h"
#include "params.h"

static bool     paused = false;
static uint32_t stillSinceMs = 0, pausedAtMs = 0, lastNoteMs = 0;
static uint16_t moveMs = 0;

bool ap_paused() { return paused; }
void ap_reset()  { paused = false; stillSinceMs = millis(); moveMs = 0; }

bool ap_update(bool buttonPressed) {
  uint32_t now = millis();

  if (!paused) {
    // Only between reps, and not while resting between sets or after the session
    bool eligible = repState == ST_REST && !resting && !sessionDone;
    bool still = gyroMagDeg < P.ap_still_dps;
    if (!eligible || !still) { stillSinceMs = now; return false; }
    if (now - stillSinceMs >= (uint32_t)P.autopause_s * 1000) {      // [AP1]
      paused = true;
      pausedAtMs = lastNoteMs = now;
      moveMs = 0;
      haptic_play(HP_REST);
      Log.printf("\n[AP1] Paused: no movement for %d s. Take as long as you need.\n", P.autopause_s);
      Log.println("[AP1] Move your arm or press BOOT to carry on.");
    }
    return false;
  }

  // Paused: wait for clear movement or the button
  if (gyroMagDeg > P.ap_wake_dps) moveMs += (uint16_t)(1000.0f / SAMPLE_HZ); else moveMs = 0;
  bool lifted = angleDeg > P.start_deg + 10.0f;
  if (buttonPressed || moveMs >= 100 || lifted) {                    // [AP2]
    paused = false;
    stillSinceMs = now;
    rep_after_pause();
    haptic_play(HP_GO);
    Log.printf("[AP2] Welcome back! (paused %lu s) Carry on with set %d: %d of %d done.\n\n",
                  (unsigned long)((now - pausedAtMs) / 1000), setNo, repsInSet, P.reps_per_set);
    return false;
  }
  if (now - lastNoteMs >= 60000) {
    Log.printf("[AP1] Still paused (%lu min). Move your arm or press BOOT to carry on.\n",
                  (unsigned long)((now - pausedAtMs) / 60000));
    lastNoteMs = now;
  }
  return true;
}
