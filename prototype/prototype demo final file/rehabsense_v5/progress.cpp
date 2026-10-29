#include <Arduino.h>
#include <Preferences.h>
#include <stdlib.h>
#include <string.h>
#include "rs_log.h"
#include "progress.h"
#include "params.h"

static Preferences prefs;
static float savedTarget = 0;      // 0 = nothing saved yet
static bool  locked = false;
static int   sessions = 0;

static void save() {
  prefs.begin("rehabsense", false);
  prefs.putFloat("target", savedTarget);
  prefs.putBool("locked", locked);
  prefs.putInt("sessions", sessions);
  prefs.end();
}

void prog_begin() {
  prefs.begin("rehabsense", true);
  savedTarget = prefs.getFloat("target", 0);
  locked      = prefs.getBool("locked", false);
  sessions    = prefs.getInt("sessions", 0);
  prefs.end();
  if (savedTarget > 0)
    Log.printf("# [AT1] Saved target %.0f deg%s, %d session(s) so far\n",
                  savedTarget, locked ? " (locked by therapist)" : "", sessions);
}

float prog_choose_target(float bend) {
  float t;
  if (locked && savedTarget > 0) {
    t = savedTarget;
    Log.printf("[AT1] Target %.0f deg (set by your therapist). Today's comfortable bend: %.0f deg\n", t, bend);
  } else if (savedTarget > 0) {
    t = min(savedTarget, bend + 15.0f);
    if (t < savedTarget)
      Log.printf("[AT1] Target %.0f deg: your saved target is %.0f, but today's comfortable bend is %.0f, so it's eased for today\n",
                    t, savedTarget, bend);
    else
      Log.printf("[AT1] Target %.0f deg (from your last session). Today's comfortable bend: %.0f deg\n", t, bend);
  } else {
    t = bend;
    Log.printf("[AT1] First session: target = your comfortable bend, %.0f deg\n", t);
  }
  return constrain(t, 40.0f, 140.0f);
}

void prog_session_end(int reps, int atTarget, int partials, bool fatigueStopped) {
  sessions++;
  float t = P.target_deg, next = t;
  if (locked) {
    Log.printf("[AT2] Target stays at %.0f deg (locked by your therapist).\n", t);
    save();
    return;
  }
  float rate = reps ? (float)atTarget / reps : 0;
  Log.printf("[AT2] %d of %d reps reached the full target of %.0f deg (%.0f%%).\n", atTarget, reps, t, rate * 100);
  if (reps >= 5 && rate >= 0.8f && !fatigueStopped) {
    next = min(t + 5.0f, 140.0f);
    Log.printf("[AT2] Great progress! Next session's target: %.0f deg (+%.0f).\n", next, next - t);
  } else if (reps == 0 || rate < 0.5f || partials > reps) {
    next = max(t - 5.0f, 40.0f);
    Log.printf("[AT2] Next session's target eases to %.0f deg. That's fine: steady practice matters most.\n", next);
  } else {
    Log.printf("[AT2] Next session's target stays at %.0f deg.\n", next);
  }
  savedTarget = next;
  P.target_deg = next;          // also used if a new session starts now with r
  save();
}

bool prog_command(const char *cmd) {
  if (cmd[0] != 't') return false;
  if (!strcmp(cmd, "t?")) {
    Log.printf("# [AT4] Target now %.0f deg, saved %.0f deg, %s, %d session(s)\n",
                  P.target_deg, savedTarget, locked ? "locked" : "adaptive", sessions);
    return true;
  }
  if (!strcmp(cmd, "tl")) {                                   // [AT3]
    locked = !locked;
    if (locked) savedTarget = P.target_deg;
    save();
    Log.printf("# [AT3] Target %s at %.0f deg\n", locked ? "locked" : "unlocked (adaptive)", P.target_deg);
    return true;
  }
  if (!strcmp(cmd, "tr")) {                                   // [AT4]
    savedTarget = 0; locked = false; sessions = 0;
    save();
    Log.println("# [AT4] Saved progress cleared. The next calibration starts fresh.");
    return true;
  }
  if (cmd[1] >= '0' && cmd[1] <= '9') {                      // [AT3] t100
    float v = atof(cmd + 1);
    if (v < 40 || v > 140) { Log.println("# [AT3] Target must be 40-140 deg"); return true; }
    P.target_deg = savedTarget = v;
    locked = true;
    save();
    Log.printf("# [AT3] Target set to %.0f deg and locked (rep counts from %.0f deg)\n",
                  v, P.peak_fraction * v);
    return true;
  }
  return false;
}
