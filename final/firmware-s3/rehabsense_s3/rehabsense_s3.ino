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
    pins.h      new map for the S3, selecting board (DevKitC-1 or XIAO) and
                IMU bus (two I2C buses or one SPI bus) at compile time
    imu.cpp     both wirings behind one imu_begin()/imu_update() contract
    haptic.cpp  two DRV2605Ls and two ERMs, one per bus, with a motor target
                per cue; one motor still works and says so
    emg.cpp     ADC resolution pinned and attenuation set for the S3's ADC1
    sampler.cpp the 10 ms wait now yields, because the control loop is a task
    this file   both I2C buses started here, a colour status LED, and the
                control loop pinned to core 1

  Every behaviour, threshold, printed line and Bluetooth byte is unchanged.
  The session viewer, the Flutter app and rehab_client.py all talk to this
  exactly as they talked to v5. The one felt difference is that the
  guided-pace beat now plays on the forearm motor rather than everywhere -
  one column of the table in haptic.cpp if that is wrong.

  Two wirings, and why
  --------------------
  The breadboard (what Rusha is building, and what the wiring diagram draws)
  puts the IMUs on two I2C buses. The custom PCB puts them on one SPI bus -
  its schematic nets are CS_IMU1/CS_IMU2/SCK/MISO/MOSI. Both are real, so
  both are here:

    default                      one SPI bus, the custom PCB
    -DRS_IMU_BUS=RS_IMU_I2C      two I2C buses, the breadboard

  Nothing above imu.cpp knows which one it got.

  The two DRV2605Ls split the same way, and for the same reason - 0x5A is
  fixed, so two of them cannot answer on one bus. The PCB puts both behind a
  TCA9543A 2-channel I2C switch (haptic.kicad_sch: one TCA9543APWR, two
  DRV2605LDGSTs, nets SDA_H1 / SCL_H1 / SDA_H2); the breadboard gives each
  its own bus. RS_HAPTIC_MUX in pins.h selects, and follows the IMU bus by
  default, so the one flag above picks the whole architecture. Nothing above
  haptic.cpp knows which it got either.

  What the PCB has that this firmware does not yet drive
  -----------------------------------------------------
  The EMG path, and it is not a difference of bus. The prototype and the
  breadboard read a MyoWare 2.0 module's envelope on ADC1. The PCB has no
  MyoWare: emg.kicad_sch is its own front end - two TL074 quad op-amps, two
  3.5 mm electrode jacks, gain and filter jumpers - feeding an ADS131M02, a
  two-channel 24-bit delta-sigma ADC on the SPI bus with an LTC6903
  programmable oscillator for its clock (adc.kicad_sch). Two channels, so the
  PRD's Phase 2 triceps channel is already on the board.

  RS_EMG_SRC in pins.h is the seam for it, and selecting the PCB's source
  fails the build on purpose with the list of what it needs. See pins.h and
  emg.cpp: every effort and fatigue figure the sleeve reports comes from this
  one signal, so a guessed gain or sample rate does not produce a bad reading,
  it produces a confident wrong answer.

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
    imu.*        both BMI270s (I2C or SPI), elbow angle and velocity
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

  Wiring, with -DRS_IMU_BUS=RS_IMU_I2C, on the ESP32-S3-DevKitC-1 breadboard
    I2C bus 0 (Wire):  SDA GPIO8,  SCL GPIO9
                       upper-arm BMI270 0x68  +  DRV2605L 0x5A -> ERM M1
    I2C bus 1 (Wire1): SDA GPIO17, SCL GPIO18
                       forearm BMI270 0x68    +  DRV2605L 0x5A -> ERM M2
      One 4.7k pull-up per line per bus, to 3V3. Both BMI270 breakouts keep
      their ADR jumper open (0x68) - the buses are what separates them.
    MyoWare 2.0 ENV -> GPIO4 (ADC1_CH3), MyoWare powered from 3V3
    Status LED: on-board WS2812 on GPIO48 (GPIO38 on DevKitC-1 v1.1; build
      with -DRS_LED_PIN=38 if it stays dark). BOOT button: GPIO0.
    Spare: GPIO5 (where the diagram suggests MyoWare RAW), GPIO6.
    Do not wire: GPIO0/3/45/46 (strapping), 19/20 (USB), 26-32 (flash),
      33-37 (octal PSRAM), 43/44 (UART console).

  On the XIAO the same build moves to the pins that leave the module: I2C
  bus 0 on GPIO5/6 [D4/D5], bus 1 on GPIO8/9 [D9/D10], and the plain
  active-LOW LED on GPIO21 instead of a WS2812. pins.h does that from
  ARDUINO_XIAO_ESP32S3; there is nothing to edit.

  Build
    Arduino IDE, board "XIAO_ESP32S3" (or "ESP32S3 Dev Module" on the DevKitC).
    The default build is the PCB: SPI IMUs, TCA9543A haptics, MyoWare on ADC1.
    For the breadboard, add -DRS_IMU_BUS=RS_IMU_I2C.
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
// Two kinds of LED, one vocabulary. The DevKitC-1 has a single addressable
// WS2812 and no plain LED; the XIAO has a plain active-LOW LED and no WS2812.
// pins.h picks one at compile time.
//
// Rhythm carries the state on both, because rhythm is what the plain LED has
// and because colour alone is no use to a red-green colour-blind user. Colour
// is added on top where there is colour to add, which is how the ESP-IDF
// firmware uses the same part. The app's troubleshooting text promises "the
// status LED should be lit", so something has to drive it either way.
//
//   state                  rhythm                      colour
//   --------------------   -------------------------   ------
//   IMU fault              5 Hz                        red
//   calibrating            4 Hz                        amber
//   waiting to calibrate   1 Hz                        blue
//   auto-paused            one blink every 2.4 s       magenta
//   session done           slow, even                  cyan
//   resting between sets   double blink                amber
//   counting reps          solid                       green

struct Rgb { uint8_t r, g, b; };

static constexpr Rgb LED_FAULT   = {255,   0,   0};
static constexpr Rgb LED_CALIB   = {255, 150,   0};
static constexpr Rgb LED_WAIT    = {  0,  90, 255};
static constexpr Rgb LED_PAUSED  = {220,   0, 200};
static constexpr Rgb LED_DONE    = {  0, 200, 200};
static constexpr Rgb LED_REST    = {255, 150,   0};
static constexpr Rgb LED_COUNT   = {  0, 255,  40};

// Only ever write on a change. The RGB write is a timed bit sequence and the
// plain write is a register poke, but both sit inside the 100 Hz control loop,
// and neither needs doing a hundred times a second to look the same.
static void ledShow(bool on, Rgb c) {
#if RS_LED_IS_RGB
  static int16_t lastR = -1, lastG = -1, lastB = -1;
  uint8_t r = on ? (uint8_t)((uint16_t)c.r * LED_BRIGHTNESS / 255) : 0;
  uint8_t g = on ? (uint8_t)((uint16_t)c.g * LED_BRIGHTNESS / 255) : 0;
  uint8_t b = on ? (uint8_t)((uint16_t)c.b * LED_BRIGHTNESS / 255) : 0;
  if (r == lastR && g == lastG && b == lastB) return;
  lastR = r; lastG = g; lastB = b;
  // rgbLedWrite is what the Arduino-ESP32 core 3.x calls the function the
  // wiring diagram names neopixelWrite; the old name still works but is
  // deprecated, and this build is warning-clean.
  rgbLedWrite(PIN_LED, r, g, b);
#else
  (void)c;
  static int8_t last = -1;
  if ((int8_t)on == last) return;
  last = (int8_t)on;
  digitalWrite(PIN_LED, (on == !LED_ACTIVE_LOW) ? HIGH : LOW);
#endif
}

// Lit from the first instant, before anything can fail.
static void ledBegin() {
#if RS_LED_IS_RGB
  rgbLedWrite(PIN_LED, 0, 0, 0);        // a WS2812 powers up with whatever it last held
  ledShow(true, LED_WAIT);
#else
  pinMode(PIN_LED, OUTPUT);
  ledShow(true, LED_WAIT);
#endif
}

static void ledUpdate() {
  uint32_t t = millis();
  bool on;
  Rgb  c;
  if (!imuOk)           { on = (t % 200) < 100;   c = LED_FAULT;  }   // fault: 5 Hz
  else if (calibrating) { on = (t % 250) < 125;   c = LED_CALIB;  }   // calibrating: 4 Hz
  else if (!calibrated) { on = (t % 1000) < 500;  c = LED_WAIT;   }   // waiting: 1 Hz
  else if (ap_paused()) { on = (t % 2400) < 120;  c = LED_PAUSED; }   // paused: a blink every 2.4 s
  else if (sessionDone) { on = (t % 3000) < 1500; c = LED_DONE;   }   // done: slow
  else if (resting)     { on = (t % 1200) < 100 || ((t % 1200) >= 250 && (t % 1200) < 350);
                          c = LED_REST; }
  else                  { on = true;              c = LED_COUNT;  }   // counting reps: solid
  ledShow(on, c);
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

  ledBegin();                        // lit from the first instant, as the app's help text promises
  pinMode(PIN_BUTTON, INPUT_PULLUP); // BOOT button starts calibration

  // Both I2C buses come up here, before anything on them. They are shared:
  // in the breadboard wiring each bus carries one BMI270 and one DRV2605L,
  // because both BMI270 breakouts are at 0x68 and the DRV2605L is fixed at
  // 0x5A, so neither chip can share a bus with its twin. imu_begin() and
  // haptic_begin() both assume the buses are already running.
  Wire.begin(PIN_I2C0_SDA, PIN_I2C0_SCL);
  Wire.setClock(I2C_HZ);
  // Wire1 exists for the second BMI270, or for the second DRV2605L when the
  // two are on separate buses. With the PCB's TCA9543A switch both motors are
  // on Wire, so there is nothing for Wire1 to carry and its pins stay free.
#if (RS_IMU_BUS == RS_IMU_I2C) || !RS_HAPTIC_MUX
  Wire1.begin(PIN_I2C1_SDA, PIN_I2C1_SCL);
  Wire1.setClock(I2C_HZ);
#endif
  // Say out loud which build this is. Two boards and two sensor wirings are
  // live at once, and "the firmware is on the wrong one" should take seconds
  // to spot rather than an afternoon.
#if RS_IMU_BUS == RS_IMU_I2C
  Log.printf("# IMUs: I2C, upper on GPIO%d/%d, forearm on GPIO%d/%d, both 0x%02X\n",
             PIN_I2C0_SDA, PIN_I2C0_SCL, PIN_I2C1_SDA, PIN_I2C1_SCL, IMU_ADDR_PRIMARY);
#else
  Log.printf("# IMUs: SPI, SCK GPIO%d MISO GPIO%d MOSI GPIO%d, CS GPIO%d and GPIO%d\n",
             PIN_SPI_SCK, PIN_SPI_MISO, PIN_SPI_MOSI, PIN_IMU_UPPER_CS, PIN_IMU_FORE_CS);
#endif
  Log.printf("# Haptics: %d x DRV2605L at 0x%02X, %s\n",
             (int)RS_HAPTIC_COUNT, HAPTIC_ADDR,
             RS_HAPTIC_MUX ? "behind a TCA9543A switch on bus 0"
                           : "one per I2C bus");
  // Which EMG front end this build expects. Worth its own line: a PCB flashed
  // with the MyoWare path reads an unconnected pin, which looks like a patient
  // who is not trying rather than like a wiring mistake.
  Log.printf("# EMG: %s.  LED: GPIO%d (%s)\n",
             RS_EMG_SRC == RS_EMG_ADC1
               ? "MyoWare 2.0 ENV on ADC1"
               : "ADS131M02 on SPI",
             PIN_LED, RS_LED_IS_RGB ? "WS2812" : "plain");
  if (RS_EMG_SRC == RS_EMG_ADC1)
    Log.printf("#   GPIO%d, ADC1_CH3. The PCB has no MyoWare - if this is the "
               "PCB, this pin is unconnected.\n", PIN_EMG_BICEPS);

  imu_begin();                       // blocks until both BMI270s answer
  while (!haptic_begin()) delay(1000);
  emg_begin();
  comms_begin();
  prog_begin();                      // [AT1] saved target from earlier sessions
  ble_begin();                       // Bluetooth: advertise as "RehabSense"
  Log.printf("# Upper IMU, forearm IMU and %d haptic driver%s OK\n",
             (int)haptic_motor_count(), haptic_motor_count() == 1 ? "" : "s");
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
