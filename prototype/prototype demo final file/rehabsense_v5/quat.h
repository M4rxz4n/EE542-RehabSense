// quat.h - quaternion maths and the Madgwick orientation filter.
#pragma once

struct Quat { float w, x, y, z; };

Quat qMul(const Quat &a, const Quat &b);
Quat qConj(const Quat &q);

// Madgwick 6-axis update. Gyro in rad/s, accel in any unit (it is normalised).
void madgwick(Quat &q, float gx, float gy, float gz,
              float ax, float ay, float az, float beta, float dt);
