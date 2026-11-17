// pins.h - every pin number in one place.
// v6: ESP32-S3-DevKitC-1, everything digital on I2C (final decision 6 Nov).
#pragma once
#include <stdint.h>

// I2C bus 0 (Wire): upper-arm IMU (0x68) + haptic driver #1 (0x5A)
constexpr int PIN_I2C1_SDA = 8;
constexpr int PIN_I2C1_SCL = 9;

// I2C bus 1 (Wire1): forearm IMU (0x68) + haptic driver #2 (0x5A), over the 4-wire cable
constexpr int PIN_I2C2_SDA = 17;
constexpr int PIN_I2C2_SCL = 18;

constexpr uint32_t I2C_HZ = 400000;

// Biceps envelope. ADC1 pin, so it keeps working with BLE on.
// MyoWare 2.0 ENV and the custom board's ENV_A both go to GPIO4,
// so swapping between them needs no firmware change.
constexpr int PIN_EMG_BICEPS = 4;

// Custom analog board (not read by v6 yet; reserved so nothing else uses them)
constexpr int PIN_ENV_B     = 5;    // triceps envelope, ADC1
constexpr int PIN_RAW_A     = 6;    // RAW_ADC_A, ADC1
constexpr int PIN_RAW_B     = 7;    // RAW_ADC_B, ADC1
constexpr int PIN_ADC_CLK   = 15;   // 1 MHz clock out, through R44
constexpr int PIN_ADC_BITS_A = 16;  // sigma-delta bit stream A, through R30A
constexpr int PIN_ADC_BITS_B = 21;  // sigma-delta bit stream B, through R30B

constexpr int PIN_BUTTON = 0;   // BOOT button on the DevKit
constexpr int PIN_LED    = 48;  // on-board RGB LED (38 on DevKitC-1 v1.1); not used by v6
