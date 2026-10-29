// score.h - per-rep grading.
// Today: range of motion and tempo. Smoothness, deductions and the
// "not measured" co-contraction slot arrive on Fri 24 Oct.
#pragma once

struct RepScore {
  int  rom;          // 0..100, peak / target
  int  tempo;        // 0..100, 100 inside the tempo window
  int  total;        // 0..100, mean of the parts above
  bool tempoOk;
  const char *tempoText;  // "ok", "too fast", "slow"
  bool flagged;      // rep counts, but was rushed: "form flagged" pattern
};

RepScore score_rep(float peakDeg, float durationS);
