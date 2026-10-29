// fatigue.h - muscle fatigue indicators from the EMG envelope and the IMUs (step 2).
//
// [FT1] Each counted rep stores peak angle, duration and biceps effort
//       (average EMG % during the lift, divided by the peak angle).
//       Baseline = the session's first 3 counted reps.
// [FT2] After each rep, the last 3 reps of the current set are compared with
//       the baseline. Signs of fatigue:
//         RANGE   peak angle below 85% of baseline
//         EFFORT  effort per degree above 125% of baseline (same curl needs more muscle)
//         SLOW    duration above 140% of baseline
// [FT3] Two or more signs: the set ends early with a longer rest.
// [FT4] A second fatigue stop in the same session ends the session.
//
// These are indicators of performance dropping, not a direct measure of muscle
// fatigue; the EMG median-frequency method needs the MyoWare RAW output (Phase 2).
#pragma once

struct FatigueResult {
  bool  ready;        // baseline set and enough reps in this set to compare
  float rangePct, effortPct, timePct;   // last 3 reps vs baseline, %
  int   signs;        // 0..3
  bool  range, effort, slow;
};

void          fat_reset_session();
void          fat_new_set();
FatigueResult fat_after_rep(float peakDeg, float durS, float meanEmgPct);
