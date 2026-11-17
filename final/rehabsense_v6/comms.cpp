#include <Arduino.h>
#include <ctype.h>
#include <string.h>
#include "rs_log.h"
#include "comms.h"
#include "calib.h"
#include "emgtest.h"
#include "haptic.h"
#include "rep.h"
#include "imu.h"
#include "emg.h"
#include "sampler.h"
#include "params.h"
#include "autopause.h"
#include "pace.h"
#include "progress.h"
#include "ble.h"

static char     buf[24];
static uint8_t  len = 0;
static uint32_t lastCharMs = 0;
static bool     plotOn = true;
static bool     logDetail = false;   // l: add time, velocity, state, reps (for the session viewer)
static uint32_t lastPrintMs = 0;
static HapticPattern mystery = HP_NONE;   // for the blind pattern test

// Commands from Bluetooth (opcode 0x20) are queued here and read exactly as if typed.
static char     inj[128];
static uint8_t  injHead = 0, injTail = 0;

void comms_inject(const char *text) {
  for (const char *p = text; ; p++) {
    char ch = *p ? *p : '\n';                  // each command ends with Enter
    uint8_t nx = (injHead + 1) % sizeof(inj);
    if (nx == injTail) break;                   // full: drop the rest
    inj[injHead] = ch; injHead = nx;
    if (!*p) break;
  }
}

int comms_read_injected() {
  if (injTail == injHead) return -1;
  char ch = inj[injTail];
  injTail = (injTail + 1) % sizeof(inj);
  return (uint8_t)ch;
}

static int nextChar() {                         // Serial first, then Bluetooth
  if (Serial.available()) return Serial.read();
  return comms_read_injected();
}

void comms_help() {
  Log.println(
    "# Commands (type, then Enter):\n"
    "#   c   calibrate: 3 steps, type n (or press BOOT) to move to the next step,\n"
    "#       then g to start the reps\n"
    "#   r   new session (counts and sets to zero)\n"
    "#   b   guided pace on/off (UP tick, HOLD steady buzz, DOWN double tick)\n"
    "#   t?  show target and saved progress   t100  therapist: set and lock target to 100 deg\n"
    "#   tl  lock / unlock the target          tr    clear saved progress\n"
    "#   z   re-zero: hold the arm straight 2 s (no EMG steps)\n"
    "#   e   EMG signal-quality test (3 s relaxed, 3 s squeeze)\n"
    "#   p   plotter output on/off ?   this help   i   status and settings\n"
    "#   (Bluetooth: the app or session viewer can send any of these commands)\n"
    "#   l   detailed logging on/off (adds t, vel, state, reps, a3, on = biceps working,\n"
    "#       ug = upper-arm turn rate, tilt = upper-arm tilt)\n"
    "#   h1  rep counted (1 click)          h2  rep flagged (3 pulses)\n"
    "#   h3  set complete (2 short + long)  h4  rest now (1 s ramp)\n"
    "#   h5  fault (2 long)                 h6  tick (40 ms)\n"
    "#   h7  set complete (long)            h8  countdown start (single)\n"
    "#   h9  ready, 10 s left (double)      h10 rep start (long)\n"
    "#   h11 pace: hold (steady buzz)       h12 pace: down (double tick)\n"
    "#   ha  play all, 1.5 s apart          h0  stop\n"
    "#   hx  blind test: play a random pattern   h?  reveal which one it was");
}

void comms_begin() { randomSeed(esp_random()); }

static void playAll() {
  bool was = plotOn; plotOn = false;
  for (uint8_t p = HP_REP_OK; p < HP_COUNT; p++) {
    Log.printf("# h%d: %s (%lu ms)\n", p, haptic_name((HapticPattern)p),
                  (unsigned long)haptic_duration_ms((HapticPattern)p));
    haptic_play((HapticPattern)p);
    haptic_wait(haptic_duration_ms((HapticPattern)p) + 1500);
  }
  plotOn = was;
  sampler_reset();
}

static void run(const char *cmd) {
  if (!strcmp(cmd, "c"))      { calibrate(); return; }
  if (!strcmp(cmd, "z"))      { calibAbort = false; bool was = plotOn; plotOn = false; if (calib_straight()) haptic_play(HP_REP_OK);
                                else Log.println("# Not saved: couldn't get a still, straight arm in 3 tries. Type z to try again.");
                                plotOn = was; sampler_reset(); return; }
  if (!strcmp(cmd, "b"))      { P.pace_on = !P.pace_on; pace_reset();
                                Log.printf("# [GP1] Guided pace %s\n", P.pace_on ? "on: tick = UP, steady buzz = HOLD, double tick = DOWN" : "off");
                                return; }
  if (!strcmp(cmd, "e"))      { bool was = plotOn; plotOn = false; emg_test(); plotOn = was; return; }
  if (!strcmp(cmd, "r"))      { rep_clear(); ap_reset(); Log.printf("# New session: set 1 of %d\n", P.sets); return; }
  if (!strcmp(cmd, "p"))      { plotOn = !plotOn; Log.printf("# Plotter output %s\n", plotOn ? "on" : "off"); return; }
  if (!strcmp(cmd, "l"))      { logDetail = !logDetail; Log.printf("# Detailed logging %s\n", logDetail ? "on" : "off"); return; }
  if (!strcmp(cmd, "?"))      { comms_help(); return; }
  if (!strcmp(cmd, "i"))      {   // status, for the session viewer when it connects mid-session
    Log.printf("# LIVE calibrated=%d set=%d/%d reps=%d partials=%d resting=%d done=%d paused=%d pace=%d\n",
               calibrated ? 1 : 0, setNo, P.sets, reps, partials, resting ? 1 : 0, sessionDone ? 1 : 0, ap_paused() ? 1 : 0,
               P.pace_on ? 1 : 0);
    Log.printf("# PARAMS target=%.0f peak=%.2f start=%.0f hyst=%.0f tempo=%.1f-%.1f muscle=%.0f sets=%dx%d rest=%d\n",
               P.target_deg, P.peak_fraction, P.start_deg, P.hyst_deg,
               P.tempo_min_s, P.tempo_max_s, P.muscle_on_pct, P.sets, P.reps_per_set, P.rest_s);
    return; }
  if (prog_command(cmd))      return;                       // [AT3] [AT4] t?, tl, tr, t<deg>
  if (!strcmp(cmd, "h0"))     { haptic_stop(); Log.println("# Haptics stopped"); return; }
  if (!strcmp(cmd, "ha"))     { playAll(); return; }
  if (!strcmp(cmd, "hx"))     { mystery = (HapticPattern)random(HP_REP_OK, HP_COUNT);
                                haptic_play(mystery); Log.println("# Played a pattern. Guess, then type h?"); return; }
  if (!strcmp(cmd, "h?"))     { Log.printf("# It was h%d: %s\n", mystery, haptic_name(mystery)); return; }
  if (cmd[0] == 'h' && isdigit(cmd[1])) {
    int n = atoi(cmd + 1);
    if (n >= 1 && n < HP_COUNT) {
      HapticPattern p = (HapticPattern)n;
      haptic_play(p);
      Log.printf("# h%d: %s (%lu ms)\n", n, haptic_name(p), (unsigned long)haptic_duration_ms(p));
      return;
    }
  }
  Log.printf("# Unknown command \"%s\". Type ? for help.\n", cmd);
}

void comms_poll() {
  for (int c; (c = nextChar()) >= 0; ) {
    char ch = (char)c;
    lastCharMs = millis();
    if (ch == '\n' || ch == '\r') {
      if (len) { buf[len] = 0; run(buf); len = 0; }
    } else if (len < sizeof(buf) - 1 && ch != ' ') {
      buf[len++] = ch;
    }
  }
  // Serial Monitor set to "No Line Ending": run after 100 ms of quiet
  if (len && millis() - lastCharMs > 100) { buf[len] = 0; run(buf); len = 0; }
}

void comms_print_live() {
  if (!plotOn || millis() - lastPrintMs < 50) return;   // 20 Hz, like the BLE live rate
  if (resting || sessionDone) return;                   // countdown / session over: no live data
  lastPrintMs = millis();
  if (logDetail)
    Serial.printf("t:%lu angle:%.1f target:%.0f emg:%.0f vel:%.0f state:%d reps:%d a3:%.1f on:%d ug:%.0f tilt:%.0f pace:%s\n",
                  (unsigned long)millis(), angleDeg, P.peak_fraction * P.target_deg, emgPct, velDeg, (int)repState,
                  reps, angle3dDeg, emgOn ? 1 : 0, upperGyroDeg, upperTiltDeg, P.pace_on ? pace_phase_name() : "off");
  else
    Serial.printf("angle:%.1f target:%.0f emg:%.0f\n", angleDeg, P.peak_fraction * P.target_deg, emgPct);
}
