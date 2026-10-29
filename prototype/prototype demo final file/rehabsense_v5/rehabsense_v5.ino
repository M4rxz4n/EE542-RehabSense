/*
  RehabSense v5
  = pnh_step5_adaptive_target + Bluetooth LE (team protocol, see BLE_PROTOCOL.md)
  pnh_step5_adaptive_target = prototype_new_haptics + step 1: false-curl detection + step 2: muscle fatigue
    + step 3: auto-pause + step 4: guided pace + step 5: adaptive target
    [FC1] adaptive biceps-on threshold (rest + 3 SD, PRD)
    [FC2] passive lift (biceps not working) -> not counted
    [FC3] swinging / momentum -> flagged, -15
    [FC4] shoulder hiking or leaning (upper arm tilts > 20 deg) -> flagged, -20
    [FC5] dropping the arm instead of lowering -> flagged, -10
    [FC6] rep not finished within 10 s -> partial (PRD)
    [FT1] per-rep range, time and biceps effort vs the session's first 3 reps
    [FT2] one sign (range < 85%, effort > 125%, time > 140%) -> gentle note
    [FT3] two or more signs -> set ends early, rest +30 s
    [FT4] second fatigue stop -> session ends
    [AP1] arm still for 60 s between reps -> session pauses, live data stops
    [AP2] move the arm or press BOOT -> "Welcome back!", counts kept
    [GP1] beats on the motor: UP 2 (tick), HOLD 2 (steady buzz), DOWN 2 (double tick), RELAX 2
    [GP2] the next UP waits until the arm is straight
    [GP3] after each cycle: "Right on the beat" or one tip. Command b turns the pace on/off
    [AT1] target from saved progress, capped at today's comfortable bend + 15 deg
    [AT2] session end: >= 80% of reps at target -> +5 deg next time; < 50% -> -5 deg
    [AT3] therapist lock: t<deg> sets and locks, tl toggles the lock
    [AT4] tr clears saved progress, t? shows it
  ESP32 DevKit + 2x BMI270 + MyoWare 2.0 + DRV2605L + ERM motor

  Same behaviour as v2, split into modules, with the six PRD haptic patterns.
  Calibration waits for you: type c (or press BOOT), then n to move through the
  three steps, then g to start the reps. Between sets the live data stops and a
  60 s countdown runs with strong buzzes (start, "Ready!" at 10 s, "Rep start!").

  Files (Arduino IDE tabs)
    pins.h       every pin number
    params.*     therapist/host settings + fixed constants
    quat.*       quaternion maths, Madgwick filter
    imu.*        both BMI270s, elbow angle and velocity
    emg.*        MyoWare biceps channel
    emgtest.*    EMG signal-quality test (command e)
    haptic.*     the six vibration patterns
    sampler.*    the 100 Hz sampling tick
    calib.*      calibration steps
    rep.*        repetition state machine
    score.*      per-rep grading
    fatigue.*    muscle fatigue indicators (step 2)
    autopause.*  pause when the arm stays still (step 3)
    pace.*       guided pace beats (step 4)
    progress.*   adaptive target saved in flash (step 5)
    comms.*      Serial Monitor commands and plotter output (Bluetooth commands too)
    rs_log.*     everything printed goes to Serial AND to the Bluetooth Messages characteristic
    rs_proto.*   team BLE byte formats (from the EE542-RehabSense repo, via rehabsense_v4)
    ble.*        Bluetooth LE service: features, events, status, settings, commands

  Wiring
    I2C bus 1 (GPIO21 SDA, GPIO22 SCL): upper-arm BMI270 0x68, DRV2605L 0x5A
    I2C bus 2 (GPIO25 SDA, GPIO26 SCL): forearm BMI270 0x68
    MyoWare ENV -> GPIO34, MyoWare powered from 3V3

  Serial Monitor 115200. Type ? for commands.
  Libraries: SparkFun BMI270 Arduino Library, Adafruit DRV2605 Library,
             NimBLE-Arduino 2.x (h2zero). Partition scheme: "Huge APP (3MB No OTA)"
             if the sketch is too big for the default partition.
  Bluetooth: advertises as "RehabSense". Works the same with or without a connection.
*/

#include <Wire.h>
#include "rs_log.h"
#include "pins.h"
#include "params.h"
#include "imu.h"
#include "emg.h"
#include "haptic.h"
#include "sampler.h"
#include "calib.h"
#include "rep.h"
#include "comms.h"
#include "autopause.h"
#include "pace.h"
#include "progress.h"
#include "ble.h"

void setup() {
  Serial.begin(115200);
  delay(500);
  Log.println("\n# RehabSense v5 (pnh_step5_adaptive_target + Bluetooth LE: FC1-FC6, FT1-FT4, AP1-AP2, GP1-GP3, AT1-AT4)");

  imu_begin();                       // also starts both I2C buses
  while (!haptic_begin(Wire)) {
    Log.println("DRV2605L not found at 0x5A on GPIO21/22. Check wiring...");
    delay(1000);
  }
  emg_begin();
  comms_begin();
  prog_begin();                      // [AT1] saved target from earlier sessions
  ble_begin();                       // Bluetooth: advertise as "RehabSense"
  Log.println("# Upper IMU, forearm IMU and haptic driver OK");
  comms_help();

  pinMode(PIN_BUTTON, INPUT_PULLUP);  // BOOT button starts calibration

  haptic_play(HP_TICK);              // startup tick = haptics work
  haptic_wait(300);
  sampler_reset();
  // No calibration at boot: the user may still be putting the sleeve on or
  // opening the Serial Monitor. Calibration starts on "c" or the BOOT button.
}

static bool paceActive = false;      // [GP1] restart the beat cycle whenever counting resumes

// BOOT button, debounced: true once per press
static bool buttonPressed() {
  static bool last = HIGH;
  static uint32_t changedAt = 0;
  bool now = digitalRead(PIN_BUTTON);
  if (now != last && millis() - changedAt > 30) {
    changedAt = millis();
    last = now;
    return now == LOW;
  }
  return false;
}

void loop() {
  comms_poll();
  sampler_tick();
  ble_poll(false);                   // commands from the app / session viewer

  bool btn = buttonPressed();
  // BOOT: resumes an auto-pause [AP2]; otherwise starts calibration
  if (btn && !ap_paused()) { haptic_play(HP_TICK); calibrate(); return; }

  if (!calibrated) {                 // waiting for the user
    static uint32_t lastNote = 0;
    if (millis() - lastNote > 4000) {
      Log.println("# Waiting to calibrate. Put the sleeve on, sit comfortably, then type c (or press BOOT).");
      lastNote = millis();
    }
    return;
  }

  static bool faultShown = false;   // Bluetooth FAULT event on each change
  if (!imuOk != faultShown) { faultShown = !imuOk; ble_fault(faultShown); }
  if (!imuOk) {
    static uint32_t lastWarn = 0, lastCue = 0;
    if (millis() - lastWarn > 1000) { Log.println("# FAULT: IMU read failed"); lastWarn = millis(); }
    if (millis() - lastCue > 5000)  { haptic_play(HP_FAULT); lastCue = millis(); }
    return;
  }
  if (ap_update(btn)) { paceActive = false; return; }   // [AP1] paused: no counting, beats or live data
  rep_update();

  // [AT2] Session just ended: update and save the target for next time
  static bool wasDone = false;
  if (sessionDone && !wasDone) prog_session_end(reps, repsAtTarget, partials, fatigueStopCount > 0);
  wasDone = sessionDone;

  // [GP1] Guided pace runs only while curls are being counted
  bool active = !resting && !sessionDone;
  if (active && !paceActive) pace_reset();
  paceActive = active;
  if (active) pace_update();

  comms_print_live();
}
