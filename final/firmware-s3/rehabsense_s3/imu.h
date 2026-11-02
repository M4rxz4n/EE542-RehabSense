// imu.h - both BMI270s, orientation fusion and the elbow angle.
#pragma once
#include "quat.h"

extern Quat  qUpper, qFore;   // orientation of each IMU
extern Quat  qCal;            // relative rotation recorded in the straight-arm pose
extern float imuBeta;         // Madgwick gain in use
extern float biasU[3], biasF[3];  // gyro bias, deg/s
extern float angleDeg;        // elbow angle from gravity, 0 = calibrated straight-arm pose
extern float angle3dDeg;      // old full-rotation angle (drifts), for comparison only
extern float gyroMagDeg;      // fastest turn rate of either IMU, deg/s
extern float upperGyroDeg;    // [FC3] upper-arm turn rate, deg/s (swinging)
extern float upperTiltDeg;    // [FC4] upper-arm tilt from its calibrated pose, deg (shoulder / lean)
void imu_save_upper_pose();   // store the upper arm's pose as the reference (straight-arm step)
extern float velDeg;          // elbow angular velocity, deg/s, low-passed
extern float imuRawU[6], imuRawF[6];  // latest raw samples: accel g, gyro deg/s
extern bool  imuOk;           // false if the last read failed

void imu_begin();             // blocks until both IMUs answer
// Read both IMUs, update fusion, angle and velocity.
// gU/gF (optional) receive the raw gyro in deg/s, before bias removal.
void imu_update(float *gU, float *gF);
Quat imu_relative();          // conj(qUpper) * qFore, without the calibration offset
void imu_down(const Quat &q, float d[3]);  // gravity direction in the sensor frame
