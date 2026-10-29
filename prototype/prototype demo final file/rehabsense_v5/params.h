// params.h - settings.
// Params: values a therapist or the host app will change at run time
//         (over BLE from Sat 25 Oct, saved to flash from Fri 24 Oct).
// The constexpr values below them are fixed signal-processing constants.
#pragma once

struct Params {
  // Defaults chosen for people recovering from a stroke: slow, controlled
  // movement, a target set from the patient's own comfortable range, and
  // regular rests. A therapist should review and adjust them per patient.
  float target_deg    = 90.0f;   // replaced at calibration by the patient's comfortable bend
  float peak_fraction = 0.80f;   // target counts as reached at 80% of target_deg
  float start_deg     = 15.0f;   // a rep starts above this (with biceps on)
  float hyst_deg      = 5.0f;    // a rep finishes below start_deg - hyst_deg
  float max_deg       = 150.0f;  // valid angle range 0..max_deg
  float tempo_min_s   = 3.0f;    // faster than this = swinging, gets flagged
  float tempo_max_s   = 8.0f;    // slower than this is noted, never flagged
  float muscle_on_pct = 10.0f;   // (replaced by the adaptive check [FC1]; kept for the PARAMS line)
  float return_vel    = -3.0f;   // deg/s; slow lowering still counts as lowering
  float stall_s       = 1.0f;    // resting low down this long = not a rep yet
  int   reps_per_set  = 10;
  int   sets          = 3;
  int   rest_s        = 60;      // rest between sets
  bool  target_tick   = true;    // short tick when the target is reached (off while pacing)
  bool  flag_too_fast = true;    // only rushing is flagged; slowness is fine

  // ---- False-curl checks (step 1) ----
  float passive_min_on = 0.60f;  // [FC2] biceps must be on for >= 60% of the lift, else not counted
  float swing_dps      = 30.0f;  // [FC3] upper arm turning faster than this...
  int   swing_ms       = 200;    //       ...for this long during the lift = swinging
  float lift_min_s     = 0.5f;   // [FC3] reaching the target faster than this = momentum
  float shoulder_deg   = 20.0f;  // [FC4] upper arm tilting more than this from its pose = shoulder / lean
  float drop_dps       = 150.0f; // [FC5] lowering faster than this = dropping the arm
  float rep_timeout_s  = 10.0f;  // [FC6] a rep not finished within this = partial (PRD)
  int   ded_swing      = 15;     // score deductions (PRD: momentum -15, shoulder -20)
  int   ded_shoulder   = 20;
  int   ded_drop       = 10;

  // ---- Fatigue (step 2) ----
  float fat_range_pct  = 85.0f;  // [FT2] range below this % of the first reps
  float fat_effort_pct = 125.0f; // [FT2] effort per degree above this %
  float fat_slow_pct   = 140.0f; // [FT2] duration above this %
  int   fat_extra_rest_s = 30;   // [FT3] extra rest after a fatigue stop
  int   fat_max_stops  = 2;      // [FT4] this many fatigue stops end the session

  // ---- Auto-pause (step 3) ----
  int   autopause_s    = 60;     // [AP1] still this long between reps = pause
  float ap_still_dps   = 8.0f;   // [AP1] both IMUs turning slower than this = still
  float ap_wake_dps    = 30.0f;  // [AP2] turning faster than this for 100 ms = resume

  // ---- Guided pace (step 4): the motor beats out each curl (command b on/off) ----
  bool  pace_on        = true;   // [GP1]
  int   beat_ms        = 1000;   // one beat
  int   up_beats       = 2;      // pull up: one tick per beat
  int   hold_beats     = 2;      // hold at the top: steady buzz
  int   down_beats     = 2;      // lower: double tick per beat
  int   rest_beats     = 2;      // relax, arm straight: silence
};

extern Params P;

// ---- Fixed signal-processing constants ----
constexpr float SAMPLE_HZ     = 100.0f;
constexpr float DT            = 1.0f / SAMPLE_HZ;
constexpr float BETA_RUN      = 0.05f;  // Madgwick gain during use
constexpr float BETA_SETTLE   = 2.5f;   // high gain to converge quickly at start
constexpr float VEL_CUTOFF_HZ = 5.0f;   // elbow velocity low-pass
constexpr float EMG_SMOOTH    = 0.2f;   // EMG low-pass (0..1)
