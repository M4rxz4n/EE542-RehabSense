/*
  RehabSense prototype demo
  ESP32 DevKit + SparkFun BMI270 (0x68) + Adafruit DRV2605L (0x5A) + ERM motor
*/
// #include <Arduino.h>
#include <Wire.h>
#include "SparkFun_BMI270_Arduino_Library.h"
#include "Adafruit_DRV2605.h"

// ---------- Settings you can change ----------
const float START_DEG  = 20.0;   // angle where a rep "starts"
const float TARGET_DEG = 60.0;   // angle you must reach for the rep to count
const float HYST_DEG   = 5.0;    // must drop this far below START_DEG to finish
const float SMOOTHING  = 0.15;   // 0..1, lower = smoother but slower

const uint8_t BUZZ_TARGET = 1;   // DRV2605 effect: strong click
const uint8_t BUZZ_REP    = 47;  // DRV2605 effect: strong buzz

// ---------- Hardware ----------
BMI270 imu;
Adafruit_DRV2605 drv;

// ---------- Rep state machine ----------
enum State { ST_REST, ST_RISING, ST_PEAK, ST_RETURNING };
State state = ST_REST;
int reps = 0;
int partials = 0;
float peakDeg = 0;

float angleDeg = 0;
bool firstSample = true;
unsigned long lastSampleMs = 0;
unsigned long lastPrintMs = 0;

void buzz(uint8_t effect) {
  drv.setWaveform(0, effect);
  drv.setWaveform(1, 0);         // end of sequence
  drv.go();
}

void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println("\nRehabSense demo starting...");

  Wire.begin(21, 22);
  Wire.setClock(400000);

  while (imu.beginI2C(BMI2_I2C_PRIM_ADDR) != BMI2_OK) {   // 0x68
    Serial.println("BMI270 not found at 0x68 - check wiring. Retrying...");
    delay(1000);
  }
  Serial.println("BMI270 OK");

  while (!drv.begin(&Wire)) {
    Serial.println("DRV2605L not found at 0x5A - check wiring. Retrying...");
    delay(1000);
  }
  drv.useERM();
  drv.selectLibrary(1);
  drv.setMode(DRV2605_MODE_INTTRIG);
  Serial.println("DRV2605L OK");

  buzz(BUZZ_REP);   // startup buzz = everything works
  Serial.println("Ready. Tilt the IMU board up past the target and back down.");
}

void updateReps() {
  switch (state) {
    case ST_REST:
      if (angleDeg > START_DEG) { state = ST_RISING; peakDeg = angleDeg; }
      break;

    case ST_RISING:
      peakDeg = max(peakDeg, angleDeg);
      if (angleDeg >= TARGET_DEG) {
        state = ST_PEAK;
        buzz(BUZZ_TARGET);
      } else if (angleDeg < START_DEG - HYST_DEG) {
        state = ST_REST;
        partials++;
        Serial.printf("# Partial rep (peak %.0f deg)\n", peakDeg);
      }
      break;

    case ST_PEAK:
      peakDeg = max(peakDeg, angleDeg);
      if (angleDeg < peakDeg - 5.0) state = ST_RETURNING;
      break;

    case ST_RETURNING:
      if (angleDeg < START_DEG - HYST_DEG) {
        reps++;
        state = ST_REST;
        buzz(BUZZ_REP);
        Serial.printf("# Rep %d counted (peak %.0f deg)\n", reps, peakDeg);
      }
      break;
  }
}

void loop() {
  unsigned long now = millis();
  if (now - lastSampleMs < 10) return;     // 100 Hz
  lastSampleMs = now;

  if (imu.getSensorData() != BMI2_OK) return;

  float ax = imu.data.accelX;
  float ay = imu.data.accelY;
  float az = imu.data.accelZ;

  // Tilt of the board's X axis away from flat, in degrees.
  // If tilting doesn't change the angle, swap ax for ay here.
  float raw = atan2(ax, sqrt(ay * ay + az * az)) * 180.0 / PI;
  raw = fabs(raw);

  if (firstSample) { angleDeg = raw; firstSample = false; }
  angleDeg += SMOOTHING * (raw - angleDeg);   // simple low-pass filter

  updateReps();

  if (now - lastPrintMs >= 50) {   // 20 Hz output for Serial Plotter
    lastPrintMs = now;
    Serial.printf("angle:%.1f target:%.0f start:%.0f reps:%d\n",
                  angleDeg, TARGET_DEG, START_DEG, reps);
  }
}
