#include <Arduino.h>
#include "sampler.h"
#include "imu.h"
#include "emg.h"
#include "haptic.h"
#include "params.h"
#include "ble.h"

static uint32_t lastTickUs = 0;

void sampler_reset() { lastTickUs = micros(); }

void sampler_tick(float *gU, float *gF) {
  const uint32_t periodUs = (uint32_t)(DT * 1e6f);
  while (micros() - lastTickUs < periodUs) haptic_update();  // pulse timing stays accurate
  lastTickUs += periodUs;
  if (micros() - lastTickUs > periodUs) lastTickUs = micros(); // fell behind: resync
  imu_update(gU, gF);
  emg_update();
  haptic_update();
  ble_tick();                      // Bluetooth features 50 Hz, IMU frames, status 1 Hz
}
