// autopause.h - pause the session when the arm stays still (step 3).
//
// [AP1] Between reps (not mid-rep, not during a set rest), if both IMUs stay
//       still for autopause_s seconds, the session pauses: live data stops,
//       a "rest now" swell plays, and a reminder prints every minute.
// [AP2] Moving the arm (lifting it, or any clear movement) or pressing BOOT
//       resumes: "Welcome back!" with the rep-start buzz. Counts are kept.
#pragma once

bool ap_paused();
void ap_reset();
// Call once per loop while a session is running. buttonPressed: BOOT was pressed.
// Returns true while paused (the caller then skips rep counting and live data).
bool ap_update(bool buttonPressed);
