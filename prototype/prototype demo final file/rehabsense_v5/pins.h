// pins.h - every pin number in one place.
// When the board changes (S3 DevKit or the carrier PCB), only this file changes.
#pragma once
#include <stdint.h>

// I2C bus 1: upper-arm IMU (0x68) + DRV2605L haptic driver (0x5A)
constexpr int PIN_I2C1_SDA = 21;
constexpr int PIN_I2C1_SCL = 22;

// I2C bus 2: forearm IMU (0x68, its own bus)
constexpr int PIN_I2C2_SDA = 25;
constexpr int PIN_I2C2_SCL = 26;

constexpr uint32_t I2C_HZ = 400000;

// MyoWare 2.0 ENV output (biceps). ADC1 pin, so it keeps working with BLE on.
constexpr int PIN_EMG_BICEPS = 34;

// Used from Sat 25 Oct (device states, button, LED)
constexpr int PIN_BUTTON = 0;   // BOOT button on the DevKit
constexpr int PIN_LED    = 2;   // onboard LED
