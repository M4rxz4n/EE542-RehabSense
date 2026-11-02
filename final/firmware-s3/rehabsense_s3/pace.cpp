#include <Arduino.h>
#include "rs_log.h"
#include "pace.h"
#include "imu.h"
#include "haptic.h"
#include "params.h"

enum PacePhase { PH_REST, PH_UP, PH_HOLD, PH_DOWN };

static PacePhase phase = PH_REST;
static int       beat = 0;              // beats done in this phase
static uint32_t  beatStartMs = 0;
static uint32_t  waitNoteMs = 0;

// How well this cycle kept to the beat
static bool topInTime, heldTop, downInTime;
static float holdMin;

static const char *NAMES[] = {"REST", "UP", "HOLD", "DOWN"};
const char *pace_phase_name() { return NAMES[phase]; }

static int beatsIn(PacePhase p) {
  switch (p) {
    case PH_UP:   return P.up_beats;
    case PH_HOLD: return P.hold_beats;
    case PH_DOWN: return P.down_beats;
    default:      return P.rest_beats;
  }
}

static void cue(PacePhase p) {
  if (p == PH_UP)   haptic_play(HP_TICK);
  if (p == PH_HOLD) haptic_play(HP_HOLD);
  if (p == PH_DOWN) haptic_play(HP_DOWN);
}

static void enter(PacePhase p) {
  phase = p;
  beat = 0;
  beatStartMs = millis();
  switch (p) {
    case PH_UP:   Log.printf("# [GP1] >> UP: pull up and squeeze (%d beats)\n", P.up_beats); break;
    case PH_HOLD: Log.printf("# [GP1] >> HOLD at the top (%d beats)\n", P.hold_beats); holdMin = angleDeg; break;
    case PH_DOWN: Log.printf("# [GP1] >> DOWN: lower slowly (%d beats)\n", P.down_beats); break;
    case PH_REST: Log.printf("# [GP1] >> RELAX, arm straight (%d beats)\n", P.rest_beats); break;
  }
  cue(p);
}

static void reportCycle() {
  if (topInTime && heldTop && downInTime) { Log.println("#   [GP3] Right on the beat. Well done!"); return; }
  if (!topInTime)  Log.println("#   [GP3] Try to reach the top by the end of UP.");
  else if (!heldTop) Log.println("#   [GP3] Try to keep your arm up for the whole HOLD.");
  if (!downInTime) Log.println("#   [GP3] Try to be straight again by the end of DOWN.");
}

void pace_reset() {
  phase = PH_REST;
  beat = 0;
  beatStartMs = millis();
  waitNoteMs = millis();
}

void pace_update() {
  if (!P.pace_on) return;
  const float topDeg    = P.peak_fraction * P.target_deg;
  const float straight  = P.start_deg - P.hyst_deg;
  uint32_t now = millis();

  if (phase == PH_HOLD) holdMin = min(holdMin, angleDeg);

  if (now - beatStartMs > 3u * P.beat_ms) beatStartMs = now - P.beat_ms;  // loop was blocked: resync, no burst
  if (now - beatStartMs < (uint32_t)P.beat_ms) return;   // still inside this beat
  beatStartMs += P.beat_ms;
  beat++;

  if (beat < beatsIn(phase)) {            // next beat of the same phase
    cue(phase);
    return;
  }

  // Phase finished: check the arm, then move on
  switch (phase) {
    case PH_REST:
      if (angleDeg > straight) {          // not straight yet: wait, silently
        beat = beatsIn(PH_REST) - 1;      // re-check next beat
        if (now - waitNoteMs > 5000) {
          Log.printf("# [GP2] Waiting: straighten and relax your arm (now %.0f deg)\n", angleDeg);
          waitNoteMs = now;
        }
        return;
      }
      enter(PH_UP);
      break;
    case PH_UP:
      topInTime = angleDeg >= topDeg;
      enter(PH_HOLD);
      break;
    case PH_HOLD:
      heldTop = holdMin >= topDeg - 10.0f;
      enter(PH_DOWN);
      break;
    case PH_DOWN:
      downInTime = angleDeg <= straight + 10.0f;   // a little leeway at the bottom
      reportCycle();
      waitNoteMs = now;
      enter(PH_REST);
      break;
  }
}
