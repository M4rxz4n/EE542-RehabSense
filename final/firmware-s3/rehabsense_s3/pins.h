// pins.h - every pin number in one place.
//
// Target: ESP32-S3. The custom PCB is the architecture this firmware is built
// for; the breadboard is a bring-up configuration kept alongside it, because
// the board exists and someone is wiring it this week.
//
//   Board       how it is chosen                    what it is
//   ---------   ---------------------------------   --------------------------
//   XIAO        ARDUINO_XIAO_ESP32S3, which the    the sleeve, and the module
//               Seeed board variant defines        the PCB carries
//   DevKitC-1   anything else                      the breadboard, and the
//                                                  board the PRD names
//
//   IMU bus     how it is chosen                    what it is
//   ---------   ---------------------------------   --------------------------
//   SPI x1      the default                        the custom PCB. Schematic
//                                                  nets CS_IMU1 / CS_IMU2 /
//                                                  SCK / MISO / MOSI
//   I2C x2      -DRS_IMU_BUS=RS_IMU_I2C            the breadboard, per the
//                                                  wiring diagram
//
// The haptic topology follows the IMU bus by default, so the one flag above
// selects the whole architecture. See RS_HAPTIC_MUX below.
//
// Why either wiring needs two of something
// ----------------------------------------
// Both BMI270s answer to 0x68 and the DRV2605L's address is fixed at 0x5A with
// no strap, so no single I2C bus can hold two of either. On the PCB the IMUs
// move to SPI and the two motors sit behind an I2C switch. On the breadboard
// there are two I2C buses instead, pairing each IMU with the motor on the same
// limb - upper arm together, forearm together - which is the lead dressing
// that makes sense on a sleeve.
//
// Pins deliberately avoided on both boards: GPIO19-20 (USB), GPIO26-32 (flash),
// GPIO33-37 (octal PSRAM - the DevKitC's N8R8 and the XIAO's ESP32-S3R8 are
// both octal, so these are free on neither), and GPIO45/46 (strapping).
#pragma once
#include <stdint.h>

// ---- Board ---------------------------------------------------------------
#if defined(ARDUINO_XIAO_ESP32S3) || defined(RS_BOARD_XIAO)
  #define RS_BOARD_IS_XIAO 1
#else
  #define RS_BOARD_IS_XIAO 0
#endif

// ---- Which bus the two BMI270s hang off ---------------------------------
// SPI is the default: it is what the PCB, the PRD and the ESP-IDF reference
// firmware all specify. I2C is the breadboard, one flag away.
#define RS_IMU_I2C 1
#define RS_IMU_SPI 2
#ifndef RS_IMU_BUS
  #define RS_IMU_BUS RS_IMU_SPI
#endif

// ---- The two I2C buses ---------------------------------------------------
//
// Bus 0 is Wire, bus 1 is Wire1. In I2C mode each carries one BMI270 and one
// DRV2605L; in SPI mode they carry the DRV2605Ls alone.
//
// 400 kHz is the DRV2605L's limit and the BMI270 is happy to 1 MHz, so the bus
// runs at the slower of the two. imu.cpp retries at 100 kHz, which is what
// turns a long breadboard lead from a silent failure into a named one.
// In SPI mode the IMUs take the bus pins below, so the I2C pairs move off
// them. Keeping one map for both would put bus 0 on top of MISO and MOSI,
// which compiles perfectly and does not work.
#if RS_BOARD_IS_XIAO
  #if RS_IMU_BUS == RS_IMU_I2C
    constexpr int PIN_I2C0_SDA = 5;   // XIAO D4
    constexpr int PIN_I2C0_SCL = 6;   // XIAO D5
    constexpr int PIN_I2C1_SDA = 8;   // XIAO D9
    constexpr int PIN_I2C1_SCL = 9;   // XIAO D10
  #else
    constexpr int PIN_I2C0_SDA = 5;   // XIAO D4
    constexpr int PIN_I2C0_SCL = 6;   // XIAO D5
    // D6/D7 are UART0, but the console on this board is USB CDC, so they are
    // free as plain GPIOs. This is the only configuration that needs them.
    constexpr int PIN_I2C1_SDA = 43;  // XIAO D6
    constexpr int PIN_I2C1_SCL = 44;  // XIAO D7
  #endif
#else
  #if RS_IMU_BUS == RS_IMU_I2C
    constexpr int PIN_I2C0_SDA = 8;   // DevKitC-1, per the wiring diagram
    constexpr int PIN_I2C0_SCL = 9;
    constexpr int PIN_I2C1_SDA = 17;
    constexpr int PIN_I2C1_SCL = 18;
  #else
    constexpr int PIN_I2C0_SDA = 15;  // clear of SCK/MISO/MOSI below
    constexpr int PIN_I2C0_SCL = 16;
    constexpr int PIN_I2C1_SDA = 17;
    constexpr int PIN_I2C1_SCL = 18;
  #endif
#endif
constexpr uint32_t I2C_HZ      = 400000;
constexpr uint32_t I2C_HZ_SLOW = 100000;

// Kept under the old names so nothing downstream has to care that the single
// haptic bus became bus 0 of two.
constexpr int PIN_I2C_SDA = PIN_I2C0_SDA;
constexpr int PIN_I2C_SCL = PIN_I2C0_SCL;

// ---- BMI270 addresses ----------------------------------------------------
// Both breakouts ship strapped to 0x68. 0x69 is tried as a fallback so a board
// with its ADR jumper closed still comes up instead of reporting a dead sensor.
constexpr uint8_t IMU_ADDR_PRIMARY  = 0x68;
constexpr uint8_t IMU_ADDR_FALLBACK = 0x69;

// ---- The SPI bus, the PCB's sensor bus -----------------------------------
//
// One bus, a chip select per device. On the XIAO these are D8/D9/D10. Unused
// when RS_IMU_BUS is RS_IMU_I2C.
//
// CAUTION, these numbers are provisional. The PCB schematic names its nets -
// CS_IMU1, CS_IMU2, SCK, MISO, MOSI - but its GPIO assignment cannot be read
// out of net names alone. Check them against the board before the first
// flash; everything else about this configuration is from the schematic.
constexpr int PIN_SPI_SCK  = 7;
constexpr int PIN_SPI_MISO = 8;   // BMI270 SDO
constexpr int PIN_SPI_MOSI = 9;   // BMI270 SDI

constexpr int PIN_IMU_UPPER_CS = 1;   // schematic net CS_IMU1
constexpr int PIN_IMU_FORE_CS  = 2;   // schematic net CS_IMU2

// The BMI270 takes 10 MHz. Start high and fall back: a long or loose lead fails
// the 8 KB configuration blob upload before it fails a register read, so the
// fallback is what names the fault.
constexpr uint32_t SPI_HZ_FAST = 8000000;
constexpr uint32_t SPI_HZ_SLOW = 1000000;
constexpr uint32_t SPI_HZ_LAST = 100000;

// ---- How many haptic channels this build drives --------------------------
// Two in every configuration. The tightest is a XIAO wired for SPI, which
// needs ten of its eleven header pins (three bus, two chip select, four I2C,
// one EMG) and gets there only by using D6/D7; D2 is left over.
//
// The code still handles one, because one is what a sleeve has when a
// DRV2605L does not answer, and haptic_begin() reports that rather than
// going silent.
#define RS_HAPTIC_COUNT 2

// DRV2605L, fixed address, one per bus.
constexpr uint8_t HAPTIC_ADDR = 0x5A;

// ---- How the two DRV2605Ls are reached -----------------------------------
//
// Two ways, because the breadboard and the PCB solve the same problem
// differently. The problem is that the DRV2605L's 0x5A is fixed with no strap,
// so two of them cannot answer on one bus.
//
//   RS_HAPTIC_MUX 0  two separate I2C buses, one DRV2605L on each.
//                    The breadboard, as the wiring diagram draws it.
//   RS_HAPTIC_MUX 1  one bus into a TCA9543A 2-channel I2C switch, one
//                    DRV2605L downstream of each channel. The custom PCB:
//                    haptic.kicad_sch has a TCA9543APWR, two DRV2605LDGSTs
//                    and the nets SDA_H1 / SCL_H1 / SDA_H2, which is this
//                    arrangement and not two MCU buses.
//
// Defaults to the mux in SPI mode, since that is the PCB, and to two buses
// otherwise. Override either way with -DRS_HAPTIC_MUX=0 or =1.
#ifndef RS_HAPTIC_MUX
  #if RS_IMU_BUS == RS_IMU_SPI
    #define RS_HAPTIC_MUX 1
  #else
    #define RS_HAPTIC_MUX 0
  #endif
#endif

// TCA9543A base address. A1/A0 select 0x70-0x73; which one the PCB straps
// cannot be read out of the schematic's net names, so this is a starting
// guess. haptic_begin() scans all four and reports which it found, so a wrong
// guess here costs one line on the console rather than an afternoon.
#ifndef HAPTIC_MUX_ADDR
  #define HAPTIC_MUX_ADDR 0x70
#endif
constexpr uint8_t HAPTIC_MUX_ADDR_FIRST = 0x70;
constexpr uint8_t HAPTIC_MUX_ADDR_LAST  = 0x73;

// The TCA9543A's only register is its control byte, written with no register
// pointer: bit 0 enables channel 0, bit 1 enables channel 1. Both at once
// would put the two DRV2605Ls back on one bus, so exactly one is ever set.
constexpr uint8_t HAPTIC_MUX_CH0 = 0x01;
constexpr uint8_t HAPTIC_MUX_CH1 = 0x02;

// ---- Where the EMG signal comes from -------------------------------------
//
// This is the one part of the architecture where the PCB and everything else
// diverge completely, rather than differing by a bus.
//
//   RS_EMG_ADC1        a MyoWare 2.0 module's ENV output into the ESP32's own
//                      ADC1. The prototype, the breadboard, the PRD's own
//                      hardware table, and every effort percentage anyone has
//                      ever measured. The default.
//
//   RS_EMG_ADS131M02   the custom PCB, which has no MyoWare at all. It has its
//                      own analog front end - emg.kicad_sch: two TL074 quad
//                      op-amps, two 3.5 mm electrode jacks, gain and filter
//                      jumpers - feeding an ADS131M02, a two-channel 24-bit
//                      delta-sigma ADC on the SPI bus, clocked by an LTC6903
//                      programmable oscillator (adc.kicad_sch). Two channels,
//                      so biceps and triceps both: the PRD's Phase 2 channel
//                      is already on the board.
//
// NOT IMPLEMENTED, deliberately. That driver needs four things the schematic's
// net names do not give: the ADS131M02's CS and DRDY pins, the rate the LTC6903
// is set to, and the gain and oversampling the front end is built around.
// Guessing any of them yields plausible numbers that are wrong, which is worse
// than not building - every effort and fatigue figure in the system comes from
// this one signal. So selecting it fails the build with that list, rather than
// shipping a stub that quietly reports zeros.
#define RS_EMG_ADC1      1
#define RS_EMG_ADS131M02 2
#ifndef RS_EMG_SRC
  #define RS_EMG_SRC RS_EMG_ADC1
#endif

// MyoWare 2.0 ENV output, for RS_EMG_ADC1.
// GPIO4 is ADC1_CH3. ADC1 matters: ADC2 shares its hardware with the radio and
// reads garbage while Bluetooth is up. This is the pin the wiring diagram and
// the ESP-IDF firmware's hardware table both name.
constexpr int PIN_EMG_BICEPS = 4;

// Phase 2, when the triceps pair is fitted. GPIO5/GPIO6 are the diagram's
// spares on the DevKitC (GPIO5 is where it suggests MyoWare RAW could go);
// GPIO3 is the free ADC1 pin on the XIAO.
#if RS_BOARD_IS_XIAO
  constexpr int PIN_EMG_TRICEPS = 3;   // XIAO D2, ADC1_CH2
#else
  constexpr int PIN_EMG_TRICEPS = 5;   // ADC1_CH4
#endif

// ---- Button ---------------------------------------------------------------
constexpr int PIN_BUTTON = 0;   // BOOT button, on-board on both boards

// ---- Status LED -----------------------------------------------------------
// The DevKitC-1 has a single WS2812 and no plain LED; the XIAO has a plain
// active-LOW LED and no WS2812. One of the two is compiled in.
//
// GPIO48 is the WS2812 on DevKitC-1 v1.0 and later; v1.1 boards moved it to
// GPIO38. If the LED stays dark, build with -DRS_LED_PIN=38 - nothing else
// about the board differs.
#if RS_BOARD_IS_XIAO
  #define RS_LED_IS_RGB 0
  #ifndef RS_LED_PIN
    #define RS_LED_PIN 21
  #endif
  constexpr bool LED_ACTIVE_LOW = true;
#else
  #define RS_LED_IS_RGB 1
  #ifndef RS_LED_PIN
    #define RS_LED_PIN 48
  #endif
  constexpr bool LED_ACTIVE_LOW = false;   // unused on the RGB path
#endif
constexpr int PIN_LED = RS_LED_PIN;

// A WS2812 at full white is about 60 mA, which is a real fraction of the
// battery budget and unpleasant to look at on a bench. Everything is scaled by
// this.
constexpr uint8_t LED_BRIGHTNESS = 24;   // of 255
