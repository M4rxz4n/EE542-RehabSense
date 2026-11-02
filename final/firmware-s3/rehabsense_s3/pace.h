// pace.h - guided pace: the sleeve beats out each curl (step 4).
//   [GP1] beats  [GP2] next UP waits for a straight arm  [GP3] feedback after each cycle
//
//   UP    up_beats    one tick per beat         pull up, squeeze the biceps
//   HOLD  hold_beats  steady gentle buzz        hold at the top
//   DOWN  down_beats  two quick ticks per beat  lower slowly
//   REST  rest_beats  silent                    relax, arm straight
//
// The next UP only starts once the arm is back straight, so the patient is
// never rushed. After each cycle it says whether the arm kept to the beat.
#pragma once

void pace_reset();     // start again from REST (e.g. after calibration or a set rest)
void pace_update();    // call once per sampler tick while a session is running
const char *pace_phase_name();
