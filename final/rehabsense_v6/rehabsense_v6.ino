/*
  RehabSense v6
  = v5 moved to the ESP32-S3-DevKitC-1, with everything digital on I2C and two haptic motors.
  Behaviour is the same as v5: calibration, rep counting, FC1-FC6, FT1-FT4, AP1-AP2,
  GP1-GP3, AT1-AT4 and Bluetooth LE (team protocol, see BLE_PROTOCOL.md).

  What changed from v5 (only pins.h, haptic.h, haptic.cpp and this file):
    - Pins for the S3: I2C bus 0 on GPIO8/9, bus 1 on GPIO17/18, biceps envelope on GPIO4.
    - Second DRV2605L on bus 1. Both motors play every pattern together.
      If the second driver isn't found, the sleeve runs with one motor.

  ESP32-S3-DevKitC-1 + 2x BMI270 + 2x DRV2605L + 2x ERM motor + EMG envelope on GPIO4
  (MyoWare 2.0 ENV, or ENV_A from the custom analog board: same pin, no firmware change).

  Calibration waits for you: type c (or press BOOT), then n to move through the
  three steps, then g to start the reps. Between sets the live data stops and a
  60 s countdown runs with strong buzzes (start, "Ready!" at 10 s, "Rep start!").

  Files (Arduino IDE tabs)
    pins.h       every pin number
    params.*     therapist/host settings + fixed constants
    quat.*       quaternion maths, Madgwick filter
    imu.*        both BMI270s, elbow angle and velocity
    emg.*        biceps envelope channel
    emgtest.*    EMG signal-quality test (command e)
    haptic.*     the vibration patterns, on both motors
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
    I2C bus 0 (GPIO8 SDA, GPIO9 SCL):   upper-arm BMI270 0x68, DRV2605L #1 0x5A
    I2C bus 1 (GPIO17 SDA, GPIO18 SCL): forearm BMI270 0x68, DRV2605L #2 0x5A (4-wire cable)
    EMG envelope -> GPIO4 (MyoWare ENV, powered from 3V3; or ENV_A from the custom board)

  Arduino IDE: board "ESP32S3 Dev Module". Plug into the UART port with
  "USB CDC On Boot" disabled, so Serial works as in v5.
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
  Log.println("\n# RehabSense v6 (v5 on ESP32-S3, all I2C, two haptic motors: FC1-FC6, FT1-FT4, AP1-AP2, GP1-GP3, AT1-AT4)");

  imu_begin();                       // also starts both I2C buses
  while (!haptic_begin(Wire, &Wire1)) {
    Log.println("DRV2605L #1 not found at 0x5A on GPIO8/9. Check wiring...");
    delay(1000);
  }
  if (haptic_second_ok()) Log.println("# Haptic driver #2 found on GPIO17/18: both motors active");
  else Log.println("# Haptic driver #2 NOT found at 0x5A on GPIO17/18: running with one motor");
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
