#include <math.h>
#include "quat.h"

Quat qMul(const Quat &a, const Quat &b) {
  return {
    a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
    a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
    a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
    a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w
  };
}

Quat qConj(const Quat &q) { return { q.w, -q.x, -q.y, -q.z }; }

void madgwick(Quat &q, float gx, float gy, float gz,
              float ax, float ay, float az, float beta, float dt) {
  float q0 = q.w, q1 = q.x, q2 = q.y, q3 = q.z;
  float qd0 = 0.5f * (-q1 * gx - q2 * gy - q3 * gz);
  float qd1 = 0.5f * ( q0 * gx + q2 * gz - q3 * gy);
  float qd2 = 0.5f * ( q0 * gy - q1 * gz + q3 * gx);
  float qd3 = 0.5f * ( q0 * gz + q1 * gy - q2 * gx);

  float an = sqrtf(ax * ax + ay * ay + az * az);
  if (an > 0.0f) {
    ax /= an; ay /= an; az /= an;
    float _2q0 = 2 * q0, _2q1 = 2 * q1, _2q2 = 2 * q2, _2q3 = 2 * q3;
    float _4q0 = 4 * q0, _4q1 = 4 * q1, _4q2 = 4 * q2;
    float _8q1 = 8 * q1, _8q2 = 8 * q2;
    float q0q0 = q0 * q0, q1q1 = q1 * q1, q2q2 = q2 * q2, q3q3 = q3 * q3;
    float s0 = _4q0 * q2q2 + _2q2 * ax + _4q0 * q1q1 - _2q1 * ay;
    float s1 = _4q1 * q3q3 - _2q3 * ax + 4 * q0q0 * q1 - _2q0 * ay - _4q1
               + _8q1 * q1q1 + _8q1 * q2q2 + _4q1 * az;
    float s2 = 4 * q0q0 * q2 + _2q0 * ax + _4q2 * q3q3 - _2q3 * ay - _4q2
               + _8q2 * q1q1 + _8q2 * q2q2 + _4q2 * az;
    float s3 = 4 * q1q1 * q3 - _2q1 * ax + 4 * q2q2 * q3 - _2q2 * ay;
    float sn = sqrtf(s0 * s0 + s1 * s1 + s2 * s2 + s3 * s3);
    if (sn > 0.0f) {
      qd0 -= beta * s0 / sn; qd1 -= beta * s1 / sn;
      qd2 -= beta * s2 / sn; qd3 -= beta * s3 / sn;
    }
  }
  q0 += qd0 * dt; q1 += qd1 * dt; q2 += qd2 * dt; q3 += qd3 * dt;
  float n = sqrtf(q0 * q0 + q1 * q1 + q2 * q2 + q3 * q3);
  q = { q0 / n, q1 / n, q2 / n, q3 / n };
}
