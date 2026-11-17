// rep.h - repetition state machine, sets and rests.
// The hold-based 5-state cycle replaces the 4-state cycle on Thu 23 Oct.
#pragma once

enum RepState { ST_REST, ST_RISING, ST_PEAK, ST_RETURNING };

extern RepState repState;
extern int  reps, partials;
extern int  rejected, flaggedReps;  // [FC2] not counted as passive; reps with a form flag
extern int  repsAtTarget;           // [AT2] counted reps that reached the full target
extern int  fatigueStopCount;       // [AT2] fatigue stops this session
extern int  setNo, repsInSet;   // current set (1-based) and reps done in it
extern bool resting;            // in the rest between sets
extern bool sessionDone;        // all sets finished

void rep_reset();     // back to rest; counts unchanged
void rep_clear();     // new session: counts and sets to zero
void rep_update();    // call once per sampler tick
void rep_after_pause();
void rep_skip_rest();     // Bluetooth START during a rest
void rep_stop();          // Bluetooth STOP: end the session now   // [AP2] after an auto-pause: fresh fatigue window, no partial streak
