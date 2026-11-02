// progress.h - adaptive target, saved in the ESP32's flash between sessions (step 5).
//
// [AT1] At calibration the target comes from the saved progress, capped at
//       today's comfortable bend + 15 deg so a bad day is never pushed too far.
//       First session (nothing saved): target = today's comfortable bend.
// [AT2] At the end of a session: if >= 80% of reps reached the full target and
//       there was no fatigue stop, the next target goes up 5 deg; if < 50% did,
//       or there were more partials than reps, it eases 5 deg; otherwise it stays.
// [AT3] Therapist lock: t<deg> (e.g. t100) sets and locks the target; tl toggles
//       the lock. A locked target is used as it is and never changes on its own.
// [AT4] tr clears the saved progress; t? shows it.
#pragma once

void  prog_begin();                                  // load from flash (setup)
float prog_choose_target(float comfortableBendDeg);  // [AT1] called in calibration step 3
void  prog_session_end(int reps, int repsAtTarget, int partials, bool fatigueStopped);  // [AT2]
bool  prog_command(const char *cmd);                 // [AT3] [AT4] t..., true if handled
