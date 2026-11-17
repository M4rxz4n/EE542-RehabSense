#include <Arduino.h>
#include <Wire.h>
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

// An I2C scanner only checks that something answers at an address. Starting a
// BMI270 also uploads an 8 KB configuration file, which fails on a long or loose
// wire even when the scanner is happy. So: try 0x68 and 0x69 (SDO pin high), say
// exactly what happened, and drop to 100 kHz if 400 kHz doesn't work.
static void startImu(BMI270 &dev, TwoWire &bus, const char *name, int sda, int scl) {
  uint32_t hz = I2C_HZ;
  for (int round = 1; ; round++) {
    bool anyAck = false;
    const uint8_t addrs[2] = {BMI2_I2C_PRIM_ADDR, BMI2_I2C_SEC_ADDR};
    for (uint8_t addr : addrs) {
      bus.beginTransmission(addr);
      if (bus.endTransmission() != 0) continue;           // nothing answers here
      anyAck = true;
      int8_t rc = dev.beginI2C(addr, bus);
      if (rc == BMI2_OK) {
        if (addr != BMI2_I2C_PRIM_ADDR || hz != I2C_HZ)
          Log.printf("%s BMI270 started at 0x%02X, I2C %lu kHz.\n", name, addr, (unsigned long)(hz / 1000));
        return;
      }
      Log.printf("%s BMI270 answers at 0x%02X on GPIO%d/%d but didn't start (error %d: %s).\n", name, addr, sda, scl, rc,
                 rc == -2 ? "communication failed part-way" :
                 rc == -3 ? "chip ID wrong: not a BMI270, or a garbled read" :
                            "setup failed, often the 8 KB config upload on a long or loose wire");
    }
    if (!anyAck)
      Log.printf("%s BMI270: nothing answers at 0x68 or 0x69 on GPIO%d (SDA) / GPIO%d (SCL). Check 3V3, GND, SDA and SCL.\n",
                 name, sda, scl);
    hz = (hz == I2C_HZ) ? 100000 : I2C_HZ;               // alternate 400 kHz and 100 kHz
    bus.setClock(hz);
    if (round % 4 == 0) Log.println("Still trying. If an I2C scanner finds it, unplug USB for 5 s (a full power cycle), then try again.");
    delay(1000);
  }
}

void imu_begin() {
  Wire.begin(PIN_I2C1_SDA, PIN_I2C1_SCL);
  Wire.setClock(I2C_HZ);
  Wire1.begin(PIN_I2C2_SDA, PIN_I2C2_SCL);
  Wire1.setClock(I2C_HZ);

  startImu(imuUpperDev, Wire, "Upper-arm", PIN_I2C1_SDA, PIN_I2C1_SCL);
  startImu(imuForeDev, Wire1, "Forearm", PIN_I2C2_SDA, PIN_I2C2_SCL);
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
