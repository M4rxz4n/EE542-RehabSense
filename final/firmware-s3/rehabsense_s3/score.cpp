#include <Arduino.h>
#include "score.h"
#include "params.h"

RepScore score_rep(float peakDeg, float durationS) {
  RepScore s;
  s.rom = (int)constrain(peakDeg / P.target_deg * 100.0f, 0.0f, 100.0f);

  float outside = 0;   // seconds outside the tempo window
  float perSec = 25.0f;
  if (durationS < P.tempo_min_s)      { outside = P.tempo_min_s - durationS; s.tempoText = "too fast"; }
  else if (durationS > P.tempo_max_s) { outside = durationS - P.tempo_max_s; s.tempoText = "slow";
                                        perSec = 5.0f; }   // slow is safe: small deduction only
  else                                  s.tempoText = "ok";
  s.tempoOk = outside == 0;
  s.tempo = (int)constrain(100.0f - perSec * outside, 50.0f, 100.0f);

  s.total = (s.rom + s.tempo) / 2;
  s.flagged = P.flag_too_fast && durationS < P.tempo_min_s;   // rushing = momentum, not control
  return s;
}
