/*
  RehabSense S3 - the shipping sleeve firmware
  ============================================

  This is rehabsense_v5 (the hardware-proven prototype firmware) retargeted
  from the ESP32 Dev Module to the ESP32-S3. Developed on the
  ESP32-S3-DevKitC-1 v1.1 (N8R8), the board the PRD and the firmware design
  doc name; the shipping sleeve is the Seeed Studio XIAO ESP32S3. One build
  serves both - see pins.h for why every pin here is inside the XIAO's header.

  What changed from v5, and nothing else did
  ------------------------------------------
    pins.h      new map for the S3 / XIAO (see that file for the reasoning)
    imu.cpp     both BMI270s moved from two I2C buses to one SPI bus with a
                chip select each, as the PRD and the ESP-IDF firmware specify
    emg.cpp     ADC resolution pinned and attenuation set for the S3's ADC1
    sampler.cpp the 10 ms wait now yields, because the control loop is a task
    this file   I2C started here (imu_begin no longer owns it), the control
                loop pinned to core 1, and a status LED

  Every behaviour, threshold, printed line, Bluetooth byte and haptic pattern
  is unchanged. The session viewer, the Flutter app and rehab_client.py all
  talk to this exactly as they talked to v5.

  Memory: the XIAO's ESP32-S3R8 carries 512 KB SRAM and 8 MB octal PSRAM -
  the same as the DevKitC-1 N8R8, so there is no budget to re-cut here. This
  sketch's own state is a few kilobytes of filter and rep-counter variables
  and NimBLE's buffers; it never approached the original ESP32's 520 KB and
  does not approach the S3's either. PSRAM is not used and is not needed.

  Both cores
  ----------
  Core 1 runs the control task below: the 100 Hz sample tick, fusion, the rep
  state machine and the haptic pulse timing - everything whose correctness is
  a matter of timing. Core 0 is left to NimBLE's host and controller tasks,
  which is where the Arduino ESP32 core already pins them. So a radio event
  can no longer stretch a haptic gap or delay a sample, which was the open
  risk the ESP-IDF firmware's README lists under "Haptic pattern timing
  margin". Nothing is shared across the two: the Bluetooth layer is driven
  from the control task and NimBLE's own queues carry it over.

  Features (all inherited unchanged from v5 = pnh_step5_adaptive_target + BLE)
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
    [GP1] beats on the motor: UP 2 (tick), HOLD 2 (buzz), DOWN 2 (double tick), RELAX 2
    [GP2] the next UP waits until the arm is straight
    [GP3] after each cycle: "Right on the beat" or one tip. Command b toggles
    [AT1] target from saved progress, capped at today's comfortable bend + 15 deg
    [AT2] session end: >= 80% of reps at target -> +5 deg next time; < 50% -> -5 deg
    [AT3] therapist lock: t<deg> sets and locks, tl toggles the lock
    [AT4] tr clears saved progress, t? shows it

  Files (Arduino IDE tabs)
    pins.h       every pin number
    params.*     therapist/host settings + fixed constants
    quat.*       quaternion maths, Madgwick filter
    imu.*        both BMI270s over SPI, elbow angle and velocity
    emg.*        MyoWare biceps channel
    emgtest.*    EMG signal-quality test (command e)
    haptic.*     the vibration patterns
    sampler.*    the 100 Hz sampling tick
    calib.*      calibration steps
    rep.*        repetition state machine
    score.*      per-rep grading
    fatigue.*    muscle fatigue indicators
    autopause.*  pause when the arm stays still
    pace.*       guided pace beats
    progress.*   adaptive target saved in flash
    comms.*      Serial Monitor commands and plotter output (Bluetooth too)
    rs_log.*     everything printed goes to Serial AND to the BLE Messages char
    rs_proto.*   team BLE byte formats
    ble.*        Bluetooth LE service: features, events, status, settings, commands

  Wiring (XIAO ESP32S3 pin labels in brackets)
    SPI bus, both BMI270s: SCK GPIO7 [D8], SDO->MISO GPIO8 [D9], SDI<-MOSI GPIO9 [D10]
      upper-arm BMI270 CS GPIO1 [D0]      forearm BMI270 CS GPIO2 [D1]
      Each breakout strapped for SPI: ADR jumper fully open, I2C pull-ups cut.
    I2C, DRV2605L at 0x5A: SDA GPIO5 [D4], SCL GPIO6 [D5]
    MyoWare 2.0 ENV -> GPIO4 [D3] (ADC1), MyoWare powered from 3V3
    Status LED: on-board user LED GPIO21. BOOT button: GPIO0.

  Build
    Arduino IDE, board "XIAO_ESP32S3" (or "ESP32S3 Dev Module" on the DevKitC).
    Libraries: SparkFun BMI270 Arduino Library, Adafruit DRV2605 Library,
               NimBLE-Arduino 2.x (h2zero).
    Both boards carry 8 MB of flash, so the default partition scheme fits -
    the "Huge APP" workaround v5 needed on a 4 MB ESP32 is no longer required.
    Serial Monitor 115200 (USB CDC). Type ? for commands.
  Bluetooth: advertises as "RehabSense". Works the same with or without a host.
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

// ---- Status LED --------------------------------------------------------
//
// The DevKitC-1 has an addressable WS2812 and the ESP-IDF firmware uses it as
// a colour-coded state display. The XIAO has one plain LED, so state is
// carried by rhythm instead of colour. The app's own troubleshooting text
// tells people "the status LED should be lit", so something has to drive it.

static void ledWrite(bool on) {
  digitalWrite(PIN_LED, (on == !LED_ACTIVE_LOW) ? HIGH : LOW);
}

static void ledUpdate() {
  uint32_t t = millis();
  bool on;
  if (!imuOk)                 on = (t % 200) < 100;                  // fault: 5 Hz
  else if (calibrating)       on = (t % 250) < 125;                  // calibrating: 4 Hz
  else if (!calibrated)       on = (t % 1000) < 500;                 // waiting: 1 Hz
  else if (ap_paused())       on = (t % 2400) < 120;                 // paused: a blink every 2.4 s
  else if (sessionDone)       on = (t % 3000) < 1500;                // done: slow
  else if (resting)           on = (t % 1200) < 100 || ((t % 1200) >= 250 && (t % 1200) < 350);
  else                        on = true;                             // counting reps: solid
  ledWrite(on);
}

// ---- Setup ------------------------------------------------------------

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

// One pass of the control loop. This was loop() in v5, unchanged except for
// the LED; it now runs in the pinned task below instead of Arduino's loopTask.
static void controlStep() {
  comms_poll();
  sampler_tick();
  ble_poll(false);                   // commands from the app / session viewer
  ledUpdate();

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

// Core 1. Priority 3 puts it above Arduino's loopTask (1) and the idle task,
// and below NimBLE's, which live on core 0 anyway.
static void controlTask(void *) {
  sampler_reset();
  for (;;) controlStep();
}

void setup() {
  Serial.begin(115200);
  delay(500);
  Log.println("\n# RehabSense S3 (v5 feature set: FC1-FC6, FT1-FT4, AP1-AP2, GP1-GP3, AT1-AT4)");
  Log.printf("# Board: ESP32-S3, %d kB SRAM free, PSRAM %d kB\n",
             (int)(ESP.getFreeHeap() / 1024), (int)(ESP.getPsramSize() / 1024));

  pinMode(PIN_LED, OUTPUT);
  ledWrite(true);                    // lit from the first instant, as the app's help text promises
  pinMode(PIN_BUTTON, INPUT_PULLUP); // BOOT button starts calibration

  // The IMUs own SPI; the haptic driver owns I2C. v5 had imu_begin() start
  // both I2C buses because both IMUs were on them, which is no longer true,
  // so the haptic bus is started here where it belongs.
  Wire.begin(PIN_I2C_SDA, PIN_I2C_SCL);
  Wire.setClock(I2C_HZ);

  imu_begin();                       // blocks until both BMI270s answer on SPI
  while (!haptic_begin(Wire)) {
    Log.printf("DRV2605L not found at 0x5A on GPIO%d (SDA) / GPIO%d (SCL). Check wiring...\n",
               PIN_I2C_SDA, PIN_I2C_SCL);
    delay(1000);
  }
  emg_begin();
  comms_begin();
  prog_begin();                      // [AT1] saved target from earlier sessions
  ble_begin();                       // Bluetooth: advertise as "RehabSense"
  Log.println("# Upper IMU, forearm IMU and haptic driver OK");
  comms_help();

  haptic_play(HP_TICK);              // startup tick = haptics work
  haptic_wait(300);

  // No calibration at boot: the user may still be putting the sleeve on or
  // opening the Serial Monitor. Calibration starts on "c" or the BOOT button.
  xTaskCreatePinnedToCore(controlTask, "rs_control", 8192, nullptr, 3, nullptr, 1);
}

void loop() {
  // Everything happens in controlTask on core 1. Arduino's loopTask has no
  // work left, so it sleeps rather than competing for the core.
  vTaskDelay(pdMS_TO_TICKS(1000));
}
