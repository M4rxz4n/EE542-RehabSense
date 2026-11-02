#include <Arduino.h>
#include "fatigue.h"
#include "params.h"

struct RepM { float peak, dur, effort; };

static RepM base[3];
static int  baseN = 0;
static RepM last[3];          // ring of the current set's last 3 reps
static int  lastN = 0, lastI = 0;
static int  postN = 0;        // reps in this set that came after the baseline

void fat_reset_session() { baseN = 0; lastN = 0; lastI = 0; postN = 0; }
void fat_new_set()       { lastN = 0; lastI = 0; postN = 0; }

static RepM mean(const RepM *a, int n) {
  RepM m = {0, 0, 0};
  for (int i = 0; i < n; i++) { m.peak += a[i].peak; m.dur += a[i].dur; m.effort += a[i].effort; }
  m.peak /= n; m.dur /= n; m.effort /= n;
  return m;
}

FatigueResult fat_after_rep(float peakDeg, float durS, float meanEmgPct) {
  RepM r = {peakDeg, durS, meanEmgPct / max(peakDeg, 1.0f)};
  bool usedForBase = false;
  if (baseN < 3) { base[baseN++] = r; usedForBase = true; }   // [FT1] baseline
  last[lastI] = r; lastI = (lastI + 1) % 3; if (lastN < 3) lastN++;
  if (!usedForBase) postN++;

  FatigueResult f = {};
  // Compare only once the baseline is full and the last 3 reps all came after it
  if (baseN < 3 || postN < 3) return f;
  RepM b = mean(base, 3), l = mean(last, 3);
  f.ready     = true;
  f.rangePct  = l.peak / b.peak * 100.0f;
  f.effortPct = l.effort / max(b.effort, 1e-6f) * 100.0f;
  f.timePct   = l.dur / b.dur * 100.0f;
  f.range  = f.rangePct  < P.fat_range_pct;
  f.effort = f.effortPct > P.fat_effort_pct && f.rangePct <= 100.0f;   // more muscle without more range
  f.slow   = f.timePct   > P.fat_slow_pct;
  f.signs  = f.range + f.effort + f.slow;
  return f;
}
