#include <Arduino.h>
#include <SPI.h>
#include "rs_log.h"
#include "SparkFun_BMI270_Arduino_Library.h"
#include "imu.h"
#include "params.h"
#include "pins.h"

static BMI270 imuUpperDev;
static BMI270 imuForeDev;

Quat  qUpper = {1, 0, 0, 0};
Quat  qFore  = {1, 0, 0, 0};
Quat  qCal   = {1, 0, 0, 0};
float imuBeta = BETA_SETTLE;
float biasU[3] = {0, 0, 0};
float biasF[3] = {0, 0, 0};
float angleDeg = 0, velDeg = 0;
float angle3dDeg = 0;
float gyroMagDeg = 0;
float upperGyroDeg = 0;
float upperTiltDeg = 0;
static float dUcal[3] = {0, 0, 1};   // upper arm's down vector in the straight-arm pose
bool  imuOk = true;
float imuRawU[6] = {0}, imuRawF[6] = {0};   // accel g, gyro deg/s (Bluetooth IMU frames)

static float prevAngle = 0;

// The BMI270 powers up listening on I2C and only commits to SPI on the first
// rising edge of its chip select. Bosch's driver does a throwaway read to
// provoke that, but it does it *inside* bmi2_init, so a sensor that has not yet
// switched can fail the chip-ID check once and be reported missing when it is
// merely still in I2C mode. One deliberate edge here removes that whole class
// of false negative.
static void nudgeIntoSpiMode(int csPin) {
  pinMode(csPin, OUTPUT);
  digitalWrite(csPin, HIGH);
  delayMicroseconds(5);
  digitalWrite(csPin, LOW);
  delayMicroseconds(5);
  digitalWrite(csPin, HIGH);
  delay(2);
}

// Starting a BMI270 is not just a register read: it also uploads an 8 KB
// configuration image, which fails on a long or loose lead even when the chip
// answers perfectly. So: say exactly what happened, and step the clock down
// before blaming the wiring, because a marginal lead usually works at 1 MHz
// and not at 8.
static void startImu(BMI270 &dev, int csPin, const char *name, const char *pinLabel) {
  const uint32_t rates[3] = {SPI_HZ_FAST, SPI_HZ_SLOW, SPI_HZ_LAST};
  for (int round = 1; ; round++) {
    for (uint32_t hz : rates) {
      nudgeIntoSpiMode(csPin);
      int8_t rc = dev.beginSPI(csPin, hz, SPI);
      if (rc == BMI2_OK) {
        if (hz != SPI_HZ_FAST)
          Log.printf("%s BMI270 started on CS %s, SPI %lu kHz (not the full %lu kHz: check that lead).\n",
                     name, pinLabel, (unsigned long)(hz / 1000), (unsigned long)(SPI_HZ_FAST / 1000));
        return;
      }
      Log.printf("%s BMI270 on CS %s at SPI %lu kHz didn't start (error %d: %s).\n",
                 name, pinLabel, (unsigned long)(hz / 1000), rc,
                 rc == BMI2_E_COM_FAIL      ? "communication failed part-way" :
                 rc == BMI2_E_DEV_NOT_FOUND ? "no BMI270 answering: chip ID wrong or nothing on MISO" :
                 rc == BMI2_E_NULL_PTR      ? "driver set up wrong (a bug, not your wiring)" :
                                              "setup failed, usually the 8 KB config upload on a long or loose lead");
    }
    Log.printf("%s BMI270: nothing usable on CS %s. Check 3V3, GND, SCK GPIO%d, SDI GPIO%d, SDO GPIO%d,\n"
               "  and that this breakout is strapped for SPI (ADR jumper fully open, I2C pull-ups cut).\n",
               name, pinLabel, PIN_SPI_SCK, PIN_SPI_MOSI, PIN_SPI_MISO);
    if (round % 4 == 0)
      Log.println("Still trying. If the other IMU started, the bus itself is fine and it is this sensor's CS or power. "
                  "Unplug USB for 5 s (a full power cycle), then try again.");
    delay(1000);
  }
}

void imu_begin() {
  // Both chip selects idle high before the bus starts, so neither sensor sees
  // a spurious frame while the other is being set up.
  pinMode(PIN_IMU_UPPER_CS, OUTPUT);
  digitalWrite(PIN_IMU_UPPER_CS, HIGH);
  pinMode(PIN_IMU_FORE_CS, OUTPUT);
  digitalWrite(PIN_IMU_FORE_CS, HIGH);

  // Pins passed explicitly: the sketch must not depend on which board variant
  // the IDE happens to have selected. -1 for SS because each sensor drives its
  // own chip select.
  SPI.begin(PIN_SPI_SCK, PIN_SPI_MISO, PIN_SPI_MOSI, -1);

  startImu(imuUpperDev, PIN_IMU_UPPER_CS, "Upper-arm", "GPIO1 (D0)");
  startImu(imuForeDev, PIN_IMU_FORE_CS, "Forearm", "GPIO2 (D1)");
}

Quat imu_relative() { return qMul(qConj(qUpper), qFore); }

// Gravity ("down") direction in the sensor's own frame, from its filter
void imu_down(const Quat &q, float d[3]) {
  d[0] = 2.0f * (q.x * q.z - q.w * q.y);
  d[1] = 2.0f * (q.w * q.x + q.y * q.z);
  d[2] = q.w * q.w - q.x * q.x - q.y * q.y + q.z * q.z;
}

void imu_save_upper_pose() { imu_down(qUpper, dUcal); }

// Rotate vector v by quaternion q
static void rotVec(const Quat &q, const float v[3], float o[3]) {
  Quat r = qMul(qMul(q, Quat{0, v[0], v[1], v[2]}), qConj(q));
  o[0] = r.x; o[1] = r.y; o[2] = r.z;
}

void imu_update(float *gU, float *gF) {
  bool okU = imuUpperDev.getSensorData() == BMI2_OK;
  bool okF = imuForeDev.getSensorData()  == BMI2_OK;
  imuOk = okU && okF;
  if (!imuOk) return;

  const auto &u = imuUpperDev.data;
  const auto &f = imuForeDev.data;
  if (gU) { gU[0] = u.gyroX; gU[1] = u.gyroY; gU[2] = u.gyroZ; }
  if (gF) { gF[0] = f.gyroX; gF[1] = f.gyroY; gF[2] = f.gyroZ; }
  imuRawU[0] = u.accelX; imuRawU[1] = u.accelY; imuRawU[2] = u.accelZ;
  imuRawU[3] = u.gyroX;  imuRawU[4] = u.gyroY;  imuRawU[5] = u.gyroZ;
  imuRawF[0] = f.accelX; imuRawF[1] = f.accelY; imuRawF[2] = f.accelZ;
  imuRawF[3] = f.gyroX;  imuRawF[4] = f.gyroY;  imuRawF[5] = f.gyroZ;

  const float D2R = PI / 180.0f;
  madgwick(qUpper, (u.gyroX - biasU[0]) * D2R, (u.gyroY - biasU[1]) * D2R,
           (u.gyroZ - biasU[2]) * D2R, u.accelX, u.accelY, u.accelZ, imuBeta, DT);
  madgwick(qFore, (f.gyroX - biasF[0]) * D2R, (f.gyroY - biasF[1]) * D2R,
           (f.gyroZ - biasF[2]) * D2R, f.accelX, f.accelY, f.accelZ, imuBeta, DT);

  // Elbow angle from gravity (v3.2).
  // Each filter's "down" direction is corrected by the accelerometer all the
  // time, so it does not drift. Heading (rotation about vertical) is not, and
  // with no magnetometer the two IMUs' headings slowly drift apart; the old
  // full-rotation angle turned that drift, plus forearm twist, into fake bend.
  // Here: the forearm's down vector is mapped into the upper arm's frame using
  // the straight-arm pose (qCal), and the angle to the upper arm's own down
  // vector is the elbow angle. Exact with the upper arm roughly vertical
  // (seated curls, elbow at your side) and unaffected by forearm twist.
  float dU[3], dF[3], dFc[3];
  imu_down(qUpper, dU);
  imu_down(qFore, dF);
  rotVec(qCal, dF, dFc);
  float dot = dU[0] * dFc[0] + dU[1] * dFc[1] + dU[2] * dFc[2];
  dot = constrain(dot, -1.0f, 1.0f);
  angleDeg = constrain(acosf(dot) * 180.0f / PI, 0.0f, P.max_deg);

  // Old full-rotation angle, kept for the detailed log (a3:) to compare
  Quat qCorr = qMul(imu_relative(), qConj(qCal));
  float w = fminf(fabsf(qCorr.w), 1.0f);
  angle3dDeg = 2.0f * acosf(w) * 180.0f / PI;

  // How much either IMU is turning, deg/s (for stillness checks)
  auto mag = [](float a, float b, float c) { return sqrtf(a * a + b * b + c * c); };
  float gu = mag(u.gyroX - biasU[0], u.gyroY - biasU[1], u.gyroZ - biasU[2]);
  float gf = mag(f.gyroX - biasF[0], f.gyroY - biasF[1], f.gyroZ - biasF[2]);
  gyroMagDeg = fmaxf(gu, gf);
  upperGyroDeg = gu;

  // [FC4] Upper-arm tilt from its calibrated pose: shoulder hiking/flexing or leaning
  float c = dU[0] * dUcal[0] + dU[1] * dUcal[1] + dU[2] * dUcal[2];
  upperTiltDeg = acosf(constrain(c, -1.0f, 1.0f)) * 180.0f / PI;

  // Angular velocity, low-passed at VEL_CUTOFF_HZ
  float rawVel = (angleDeg - prevAngle) / DT;
  prevAngle = angleDeg;
  float rc = 1.0f / (2.0f * PI * VEL_CUTOFF_HZ);
  velDeg += (DT / (rc + DT)) * (rawVel - velDeg);
}
