#include <Arduino.h>
#include <string.h>
#include <stdio.h>
#include "rs_log.h"
#include "rep.h"
#include "imu.h"
#include "emg.h"
#include "haptic.h"
#include "score.h"
#include "params.h"
#include "fatigue.h"
#include "ble.h"
#include "rs_proto.h"

RepState repState = ST_REST;
int reps = 0, partials = 0;
int rejected = 0, flaggedReps = 0;    // [FC2] not counted (passive), reps with a form flag
int repsAtTarget = 0, fatigueStopCount = 0;   // [AT2]
int setNo = 1, repsInSet = 0;
bool resting = false, sessionDone = false;

static float    peakDeg = 0;
static uint32_t repStartMs = 0;
static uint32_t stallStartMs = 0;   // when the arm stopped rising low down (0 = not stalled)
static uint32_t restEndMs = 0, restCueMs = 0, lastRestNoteMs = 0;
static bool     restCuePlayed = false;
static uint32_t retStartMs = 0;    // when lowering began (stuck-return warning)
static float    lowest = 999;
static bool     warned = false;

// ---- per-rep false-curl tracking (step 1) ----
enum { FL_SWING = 1, FL_SHOULDER = 2, FL_DROP = 4 };
static uint8_t  flags = 0;
static uint32_t liftSamples = 0, onSamples = 0;   // [FC2]
static uint16_t swingMs = 0;                      // [FC3]
static float    maxTilt = 0, maxDropDps = 0;      // [FC4] [FC5]
static bool     needLow = false;                  // [FC6] after a timeout, wait for a straight arm
static float    emgSum = 0;                       // [FT1] sum of EMG % during the lift
static int      fatigueStops = 0;                 // [FT3] [FT4]
static bool     tiredNoted = false;               // [FT2] one gentle note per set
static int      restLen = 60;                     // length of the current rest, s
static int      partialStreak = 0;                // [FT2] partials in a row
static void startRest(int secs);

static void sessionSummary() {
  Log.printf("#   Partials %d, not counted (passive) %d, flagged form %d\n", partials, rejected, flaggedReps);
  Log.println("# Type r to start a new session.");
}

// [FT3] [FT4] Fatigue: end the set early with a longer rest, or end the session
static void fatigueStop(HapticPattern repCue) {
  fatigueStops++;
  fatigueStopCount = fatigueStops;
  if (fatigueStops >= P.fat_max_stops) {                          // [FT4]
    haptic_play_then(repCue, HP_SET_COMPLETE, 300);
    sessionDone = true;
    ble_set_complete(repsInSet);
    Log.printf("\n# [FT4] Your muscles are tired. Let's stop for today: %d reps, great work.\n", reps);
    sessionSummary();
  } else if (setNo >= P.sets) {
    haptic_play_then(repCue, HP_SET_COMPLETE, 300);
    sessionDone = true;
    ble_set_complete(repsInSet);
    Log.printf("\n# SESSION COMPLETE: %d reps (last set ended early: fatigue). Excellent work, rest your arm now.\n", reps);
    sessionSummary();
  } else {
    Log.println("#   [FT3] Signs of muscle fatigue. Let's end this set early and rest a bit longer.");
    haptic_play_then(repCue, HP_REST, 300);                        // "rest now" swell
    startRest(P.rest_s + P.fat_extra_rest_s);
  }
}

static void flagText(uint8_t f, char *out, size_t n) {
  snprintf(out, n, "%s%s%s%s%s",
           (f & FL_SWING) ? "SWING" : "",
           (f & FL_SWING) && (f & (FL_SHOULDER | FL_DROP)) ? "+" : "",
           (f & FL_SHOULDER) ? "SHOULDER" : "",
           (f & FL_SHOULDER) && (f & FL_DROP) ? "+" : "",
           (f & FL_DROP) ? "DROP" : "");
}

void rep_reset() { repState = ST_REST; }
void rep_clear() {
  reps = 0; partials = 0; repState = ST_REST;
  rejected = 0; flaggedReps = 0; needLow = false;
  fatigueStops = 0; tiredNoted = false; partialStreak = 0;
  repsAtTarget = 0; fatigueStopCount = 0;
  fat_reset_session();
  setNo = 1; repsInSet = 0; resting = false; sessionDone = false;
}

// Bluetooth START during a rest: end the rest now (the next set starts with "Rep start!")
void rep_skip_rest() {
  if (!resting) return;
  restCueMs = restEndMs = millis();
  Log.println("# Rest ended early from the app.");
}

// Bluetooth STOP: end the session now; counts are kept until r / START
void rep_stop() {
  if (sessionDone) return;
  resting = false;
  repState = ST_REST;
  sessionDone = true;
  haptic_play(HP_SET_COMPLETE);
  Log.printf("\n# SESSION STOPPED from the app: %d reps.\n", reps);
  sessionSummary();
}

void rep_after_pause() {
  repState = ST_REST;
  partialStreak = 0;
  fat_new_set();          // a long pause is a rest: compare the next reps afresh
}

// One short, encouraging line after each rep, for the patient
static void encourage(const RepScore &s) {
  if (s.flagged)                Log.println("#   Good effort. Slow down a little: about 2 s up, 2-3 s down.");
  else if (s.rom < 85)          Log.println("#   Good rep. Try to bend a little further if it's comfortable.");
  else if (!s.tempoOk)          Log.println("#   Good rep. Nice and steady, take the time you need.");
  else                          Log.println("#   Great rep!");
}

// Rest between sets: the live data stops and a countdown runs instead.
//   "Set 1 of 3 complete..."  strong long buzz
//   60                        strong single buzz (countdown starts)
//   59 ... 11                 one number per second, silent
//   Ready! 10                 strong double buzz
//   9 ... 1                   silent
//   Rep start!                strong long buzz, live data resumes
static int lastShown = -1;

static void startRest(int secs) {
  resting = true;
  restLen = secs;
  restCueMs = millis() + 1500;                        // countdown starts after the long buzz
  restEndMs = restCueMs + (uint32_t)secs * 1000;
  lastShown = -1;
  lastRestNoteMs = millis();
  ble_set_complete(repsInSet);
  Log.printf("\nSet %d of %d complete. Well done! Rest for %d s: let your arm relax.\n",
                setNo, P.sets, secs);
}

static void updateRest() {
  uint32_t now = millis();
  if (now < restCueMs) return;                        // still on the set-complete buzz
  if (now < restEndMs) {
    int left = (int)((restEndMs - now + 999) / 1000); // whole seconds left, rest_s .. 1
    if (left != lastShown) {
      lastShown = left;
      if (left == restLen)   { Log.printf("%d\n", left); haptic_play(HP_COUNT_START); }
      else if (left == 10)   { Log.printf("Ready! %d\n", left); haptic_play(HP_READY); }
      else                     Log.printf("%d\n", left);
    }
    static uint32_t lastMoveNoteMs = 0;
    if (angleDeg > 0.5f * P.target_deg && now - lastMoveNoteMs >= 5000) {
      Log.println("(Still resting: these curls don't count. Let your arm relax.)");
      lastMoveNoteMs = now;
    }
    return;
  }
  resting = false;
  setNo++;
  repsInSet = 0;
  repState = ST_REST;
  tiredNoted = false;
  fat_new_set();
  haptic_play(HP_GO);
  Log.printf("Rep start! Set %d of %d\n\n", setNo, P.sets);
}

void rep_update() {
  if (sessionDone) {
    static uint32_t lastDoneNoteMs = 0;
    if (angleDeg > 0.5f * P.target_deg && millis() - lastDoneNoteMs >= 10000) {
      Log.println("# Session is complete, so curls aren't counted. Type r to start a new session.");
      lastDoneNoteMs = millis();
    }
    return;
  }
  if (resting) { updateRest(); return; }

  const float peakThresh = P.peak_fraction * P.target_deg;
  const float finishDeg  = P.start_deg - P.hyst_deg;
  const uint32_t now     = millis();

  // [FC6] Timeout: a rep that isn't finished within rep_timeout_s becomes a partial
  if (repState != ST_REST && now - repStartMs > (uint32_t)(P.rep_timeout_s * 1000)) {
    if (peakDeg >= 0.5f * P.target_deg) {
      partials++;
      ble_partial(repsInSet + 1, peakDeg);
      Log.printf("# Partial rep (peak %.0f deg, needed %.0f)\n", peakDeg, peakThresh);
      Log.printf("#   [FC6] That rep took longer than %.0f s, so it wasn't counted. Straighten your arm to start again.\n",
                    P.rep_timeout_s);
    }
    repState = ST_REST;
    needLow = true;
  }

  // While a rep is in progress (lift and top): biceps use, swinging, shoulder
  if (repState == ST_RISING || repState == ST_PEAK) {
    liftSamples++;
    if (emgOn) onSamples++;                                        // [FC2]
    emgSum += emgPct;                                              // [FT1]
    if (upperGyroDeg > P.swing_dps) {                              // [FC3]
      swingMs += (uint16_t)(1000.0f / SAMPLE_HZ);
      if (swingMs >= P.swing_ms) flags |= FL_SWING;
    } else swingMs = 0;
  }
  if (repState != ST_REST) {
    maxTilt = max(maxTilt, upperTiltDeg);                          // [FC4]
    if (upperTiltDeg > P.shoulder_deg) flags |= FL_SHOULDER;
  }

  switch (repState) {
    case ST_REST:                                     // 1: start
      if (needLow) {                                  // after a timeout: straighten first
        if (angleDeg < finishDeg) needLow = false;
        break;
      }
      // Starts on movement alone; whether the biceps did the work is checked
      // at the end [FC2], so a passive lift is reported instead of ignored.
      if (angleDeg > P.start_deg) {
        repState = ST_RISING;
        peakDeg = angleDeg;
        repStartMs = now;
        stallStartMs = 0;
        flags = 0; liftSamples = 0; onSamples = 0; swingMs = 0; emgSum = 0;
        maxTilt = 0; maxDropDps = 0;
        ble_evt(wire::E_REP_START);
      }
      break;

    case ST_RISING:
      peakDeg = max(peakDeg, angleDeg);
      if (angleDeg >= peakThresh) {                   // 2: target reached
        repState = ST_PEAK;
        if ((now - repStartMs) / 1000.0f < P.lift_min_s) flags |= FL_SWING;   // [FC3] momentum
        if (P.target_tick && !P.pace_on) haptic_play(HP_TICK);
      } else if (angleDeg < finishDeg) {              // 5: back down without reaching the target
        repState = ST_REST;
        if (peakDeg >= 0.5f * P.target_deg) {        // a real attempt, not a shift between reps
          partials++;
          ble_partial(repsInSet + 1, peakDeg);
          Log.printf("# Partial rep (peak %.0f deg, needed %.0f)\n", peakDeg, peakThresh);
          Log.println("#   That one didn't quite reach the target. Rest a moment if you need to.");
          if (++partialStreak >= 3) {                 // [FT2] can't reach the target any more
            partialStreak = 0;
            Log.println("#   [FT2] Three reps in a row didn't reach the target: that's a sign of fatigue.");
            ble_fatigue(9, (uint16_t)reps);           // 9 = partial streak
            fatigueStop(HP_NONE);
          }
        }
      } else if (angleDeg < 0.5f * P.target_deg && fabsf(velDeg) < 3.0f) {   // paused, not lowering
        // Resting low down (e.g. pausing at 30 deg between reps): not a curl yet.
        // After stall_s go back to rest, so the rep timer restarts when you really lift.
        if (!stallStartMs) stallStartMs = now;
        else if (now - stallStartMs > (uint32_t)(P.stall_s * 1000)) repState = ST_REST;
      } else {
        stallStartMs = 0;
      }
      break;

    case ST_PEAK:
      peakDeg = max(peakDeg, angleDeg);
      // Turning back: moving down, or clearly below the top even if very slowly
      if (velDeg < P.return_vel || angleDeg < peakDeg - 15.0f) {
        repState = ST_RETURNING;
        retStartMs = now; lowest = angleDeg; warned = false;
      }
      break;

    case ST_RETURNING: {
      maxDropDps = max(maxDropDps, -velDeg);                       // [FC5]
      if (-velDeg > P.drop_dps) flags |= FL_DROP;
      // Stuck: the arm comes down but never gets below finishDeg (bad zero, or
      // not straightening). Say so once per rep instead of failing silently.
      lowest = min(lowest, angleDeg);
      if (!warned && now - retStartMs > 8000) {
        Log.printf("# Not counted yet: straighten your arm to below %.0f deg to finish the rep (lowest so far %.0f deg).\n",
                      finishDeg, lowest);
        Log.println("#   If your arm IS straight, the zero is off: hold it straight and type z.");
        warned = true;
      }
      if (angleDeg < finishDeg) {                     // 4: back at the start
        repState = ST_REST;

        // [FC2] Passive lift: the arm went up but the biceps barely worked
        float onRatio = liftSamples ? (float)onSamples / liftSamples : 0;
        if (onRatio < P.passive_min_on) {
          rejected++;
          ble_evt(wire::E_PASSIVE_SWING);
          Log.printf("# NOT COUNTED [FC2]: peak %.0f deg, but the biceps was working for only %.0f%% of the lift (needs %.0f%%).\n",
                        peakDeg, onRatio * 100, P.passive_min_on * 100);
          Log.println("#   It looked like the arm was lifted for you. Lift it with your biceps.");
          break;
        }

        reps++;
        repsInSet++;
        if (peakDeg >= P.target_deg) repsAtTarget++;               // [AT2]
        float dur = (now - repStartMs) / 1000.0f;
        RepScore s = score_rep(peakDeg, dur);
        int ded = 0;                                                // PRD deductions
        if (flags & FL_SWING)    ded += P.ded_swing;
        if (flags & FL_SHOULDER) ded += P.ded_shoulder;
        if (flags & FL_DROP)     ded += P.ded_drop;
        if (ded) { s.total = max(0, s.total - ded); s.flagged = true; }
        if (s.flagged) flaggedReps++;
        char ft[32]; flagText(flags, ft, sizeof ft);

        Log.printf("# REP %d  peak=%.1f deg  duration=%.1f s  rom=%d  tempo=%d (%s)  score=%d%s",
                      reps, peakDeg, dur, s.rom, s.tempo, s.tempoText, s.total,
                      s.flagged ? "  FLAGGED" : "");
        if (flags) Log.printf("  flags=%s", ft);
        Log.printf("  biceps=%.0f%%\n", onRatio * 100);
        if (flags & FL_SWING)
          Log.printf("#   [FC3] Swinging: lift slowly, using your biceps rather than momentum (-%d).\n", P.ded_swing);
        if (flags & FL_SHOULDER)
          Log.printf("#   [FC4] Your upper arm moved %.0f deg: keep your elbow by your side and sit tall (-%d).\n",
                        maxTilt, P.ded_shoulder);
        if (flags & FL_DROP)
          Log.printf("#   [FC5] Lowered at %.0f deg/s: lower slowly, don't let it drop (-%d).\n", maxDropDps, P.ded_drop);
        if (!flags) encourage(s);
        {
          uint16_t comp = ((flags & FL_SHOULDER) ? wire::COMP_SHOULDER : 0) |
                          ((flags & FL_SWING) ? wire::COMP_SWING : 0) |
                          ((flags & FL_DROP) ? wire::COMP_DROP : 0);
          ble_rep((uint16_t)repsInSet, (uint8_t)s.total, (uint8_t)constrain(s.rom, 0, 255), peakDeg, comp,
                  (uint32_t)(dur * 1000));
        }
        Log.printf("#   Set %d: %d of %d\n", setNo, repsInSet, P.reps_per_set);

        // [FT1] [FT2] Fatigue indicators: last 3 reps of this set vs the first 3 of the session
        FatigueResult f = fat_after_rep(peakDeg, dur, liftSamples ? emgSum / liftSamples : 0);
        bool tired2 = false;
        partialStreak = 0;
        if (f.ready) {
          Log.printf("#   [FT1] vs your first reps: range %.0f%%, effort %.0f%%, time %.0f%%%s%s%s\n",
                        f.rangePct, f.effortPct, f.timePct,
                        f.range ? "  RANGE" : "", f.effort ? "  EFFORT" : "", f.slow ? "  SLOW" : "");
          if (f.signs >= 2) {
            tired2 = true;
            ble_fatigue((int16_t)f.signs, (uint16_t)reps);
          } else if (f.signs == 1 && !tiredNoted) {
            tiredNoted = true;
            ble_fatigue(1, (uint16_t)reps);
            Log.printf("#   [FT2] You may be getting tired (%s). Take your time.\n",
                          f.range ? "your range is dropping" : f.effort ? "the same curl needs more effort"
                                                              : "your reps are slowing down");
          }
        }

        bool setDone = repsInSet >= P.reps_per_set;
        bool last = setNo >= P.sets;
        HapticPattern repCue = s.flagged ? HP_REP_FLAGGED : HP_REP_OK;
        if (tired2) {
          fatigueStop(repCue);
        } else if (setDone) {
          haptic_play_then(repCue, last ? HP_SET_COMPLETE : HP_SET_LONG, 300);
          if (last) {
            sessionDone = true;
            ble_set_complete(repsInSet);
            Log.printf("\n# SESSION COMPLETE: %d reps in %d sets. Excellent work, rest your arm now.\n",
                          reps, P.sets);
            sessionSummary();
          } else {
            startRest(P.rest_s);
          }
        } else {
          haptic_play(s.flagged ? HP_REP_FLAGGED : HP_REP_OK);
        }
      }
      break;
    }
  }
}
