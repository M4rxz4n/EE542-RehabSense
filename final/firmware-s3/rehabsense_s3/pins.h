// pins.h - every pin number in one place.
//
// Target: ESP32-S3. Developed on the ESP32-S3-DevKitC-1 v1.1 (N8R8, the board
// the PRD and the firmware design doc name); the shipping sleeve is the Seeed
// Studio XIAO ESP32S3. One pin map serves both, because every pin used here
// exists on the XIAO's 11-pin header.
//
// Why these pins and not the DevKit's own
// ---------------------------------------
// The XIAO breaks out only GPIO1-9 plus GPIO43/44 (the UART console), and has
// an on-board user LED on GPIO21 and a BOOT button on GPIO0. The ESP-IDF
// firmware's map (IMU CS on GPIO10/14, WS2812 on GPIO38) cannot be used: none
// of those three pins leave the XIAO's module. Everything below is inside the
// XIAO's header and is also a plain GPIO on the DevKitC-1, so the same sketch
// runs on either board with no edit.
//
// Pins deliberately avoided on both boards: GPIO19-20 (USB), GPIO26-32 (flash),
// GPIO33-37 (octal PSRAM - both the N8R8 and the XIAO's ESP32-S3R8 are octal,
// so these are not free on either).
//
// GPIO3 (XIAO D2) and the two UART pins are left unused and available.
#pragma once
#include <stdint.h>

// ---- Both BMI270s: one SPI bus, one chip select each --------------------
//
// SPI rather than the prototype's two I2C buses. It matches the PRD and the
// ESP-IDF firmware's design, it costs one pin fewer for two sensors than two
// separate I2C buses did, and the 8 KB configuration blob each BMI270 wants at
// start-up uploads in a few milliseconds instead of a fifth of a second.
//
// These are the XIAO's native SPI pins (D8/D9/D10), passed to SPI.begin()
// explicitly so the sketch does not depend on a board variant's defaults.
constexpr int PIN_SPI_SCK  = 7;   // XIAO D8
constexpr int PIN_SPI_MISO = 8;   // XIAO D9  - BMI270 SDO
constexpr int PIN_SPI_MOSI = 9;   // XIAO D10 - BMI270 SDI

constexpr int PIN_IMU_UPPER_CS = 1;   // XIAO D0, upper-arm BMI270
constexpr int PIN_IMU_FORE_CS  = 2;   // XIAO D1, forearm BMI270

// The BMI270 takes 10 MHz. Start high and fall back: a long or loose lead
// fails the blob upload before it fails a register read, so the fallback is
// what turns a silent wiring fault into a message that names it.
constexpr uint32_t SPI_HZ_FAST = 8000000;
constexpr uint32_t SPI_HZ_SLOW = 1000000;
constexpr uint32_t SPI_HZ_LAST = 100000;

// ---- DRV2605L haptic driver: I2C at 0x5A -------------------------------
// The XIAO's native I2C pair (D4/D5). The driver is addressed over I2C only -
// real-time mode, no PWM line - so the haptics need no further pin.
constexpr int PIN_I2C_SDA = 5;   // XIAO D4
constexpr int PIN_I2C_SCL = 6;   // XIAO D5
constexpr uint32_t I2C_HZ = 400000;

// ---- MyoWare 2.0 ENV output (biceps) -----------------------------------
// GPIO4 is ADC1_CH3. ADC1 matters: ADC2 shares its hardware with the radio and
// reads garbage while Bluetooth is up. This is also the pin the ESP-IDF
// firmware's hardware table already names for the EMG channel, so the two
// firmwares agree about the wiring.
constexpr int PIN_EMG_BICEPS = 4;   // XIAO D3

// Phase 2, when the custom PCB adds the triceps pair: GPIO3 (XIAO D2),
// ADC1_CH2, is held free for it.
constexpr int PIN_EMG_TRICEPS = 3;   // XIAO D2, not fitted yet

// ---- Device states, button, LED ----------------------------------------
constexpr int PIN_BUTTON = 0;   // BOOT button, on-board on both boards
constexpr int PIN_LED    = 21;  // XIAO user LED. Active LOW: LOW lights it.
constexpr bool LED_ACTIVE_LOW = true;
