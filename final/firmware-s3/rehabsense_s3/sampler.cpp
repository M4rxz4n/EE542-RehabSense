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
  // Wait out the rest of the 10 ms period, keeping haptic pulse timing accurate.
  //
  // The original spun here without yielding, which was harmless inside
  // Arduino's loopTask. This runs in a task of our own now (see the sketch's
  // control task), so a pure spin would starve core 1's idle task and trip the
  // task watchdog. Yielding at 1 ms granularity costs nothing audible: the
  // shortest haptic step in the whole vocabulary is 40 ms.
  for (;;) {
    uint32_t el = micros() - lastTickUs;
    if (el >= periodUs) break;
    haptic_update();
    if (periodUs - el > 2000) vTaskDelay(1);
  }
  lastTickUs += periodUs;
  if (micros() - lastTickUs > periodUs) lastTickUs = micros(); // fell behind: resync
  imu_update(gU, gF);
  emg_update();
  haptic_update();
  ble_tick();                      // Bluetooth features 50 Hz, IMU frames, status 1 Hz
}
