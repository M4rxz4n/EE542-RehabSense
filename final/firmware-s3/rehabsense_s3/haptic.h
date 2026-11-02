// haptic.h - the thirteen RehabSense vibration patterns, on two motors.
//
// An ERM motor can't change frequency separately from strength, so patterns
// differ by rhythm. Both DRV2605Ls run in real-time playback mode: firmware
// sets motor strength over I2C and times every pulse itself.
//
// Only one pattern plays at a time, on one or both motors. A higher-priority
// pattern interrupts a lower one; anything else waits in a single queue slot.
// That is unchanged from the single-motor build - what the second motor adds is
// *where* a cue is felt, not a second thing happening at once.
//
// Where each cue goes
// -------------------
// Almost everything plays on both motors, which is what the one-motor sleeve
// felt like and what the team tuned against. The exception is the guided-pace
// beat: up/hold/down guide the forearm, the only part of the arm that moves in
// a curl, so they play on the forearm motor alone. That is the whole reason the
// hardware grew a second motor, and it is one column of the table in
// haptic.cpp if it turns out to feel wrong on the bench.
#pragma once
#include <stdint.h>
#include "pins.h"      // RS_HAPTIC_COUNT: how many channels this build has

// How many motors this build drives, as a value rather than a macro, so
// callers do not all have to know about pins.h.
constexpr uint8_t HAPTIC_CHANNELS = RS_HAPTIC_COUNT;

enum HapticPattern : uint8_t {
  HP_NONE         = 0,
  HP_REP_OK       = 1,  // one sharp click, 100 ms
  HP_REP_FLAGGED  = 2,  // three pulses, 80 ms on / 80 ms off
  HP_SET_COMPLETE = 3,  // two 70 ms pulses, then one 500 ms pulse
  HP_REST         = 4,  // one 1000 ms ramp up and down
  HP_FAULT        = 5,  // two 300 ms pulses, 300 ms apart
  HP_TICK         = 6,  // one 40 ms tick (button press, prompts)
  HP_SET_LONG     = 7,  // strong long buzz, 1000 ms: set complete, rest begins
  HP_COUNT_START  = 8,  // strong single buzz, 200 ms: rest countdown starts
  HP_READY        = 9,  // strong double buzz, 2 x 200 ms: "Ready!" 10 s left
  HP_GO           = 10, // strong long buzz, 700 ms: "Rep start!"
  HP_HOLD         = 11, // [GP1] steady gentle buzz for one beat ("hold" beat)
  HP_DOWN         = 12, // [GP1] two quick ticks ("down" beat)
  HP_COUNT        = 13
};

// Which motor a cue is felt on. HM_DEFAULT means "wherever this pattern
// normally plays", and it is deliberately zero: a zero byte from an older app
// build, or from any caller that does not care, behaves exactly as before.
enum HapticMotor : uint8_t {
  HM_DEFAULT = 0,
  HM_UPPER   = 1,   // upper-arm motor, M1, I2C bus 0
  HM_FORE    = 2,   // forearm motor,   M2, I2C bus 1
  HM_BOTH    = 3
};

// Brings up every DRV2605L this build expects (see RS_HAPTIC_COUNT in pins.h)
// and reports whether at least one answered. A build that finds only one motor
// runs every cue on that one rather than going silent, and says so.
bool haptic_begin();

void haptic_play(HapticPattern p);                      // the pattern's own home
void haptic_play(HapticPattern p, HapticMotor m);        // somewhere specific
// Play `first`, then `then` after `gapMs` (e.g. last rep, then set complete after 300 ms)
void haptic_play_then(HapticPattern first, HapticPattern then, uint16_t gapMs);
void haptic_stop();
void haptic_update();       // call at least every few ms
bool haptic_busy();

const char *haptic_name(HapticPattern p);
uint32_t    haptic_duration_ms(HapticPattern p);
void        haptic_wait(uint32_t ms);  // delay() that keeps patterns playing

// What actually came up, for the console banner, the `h?` listing and the app's
// developer tab. `haptic_motors_found` is a bitmask of (1 << (HM_x - 1)).
uint8_t     haptic_motors_found();
uint8_t     haptic_motor_count();
const char *haptic_motor_name(HapticMotor m);
HapticMotor haptic_home(HapticPattern p);
