// haptic.h - the six RehabSense vibration patterns.
//
// An ERM motor can't change frequency separately from strength, so patterns
// differ by rhythm. The DRV2605L runs in real-time playback mode: firmware
// sets motor strength over I2C and times every pulse itself.
//
// Only one pattern plays at a time. A higher-priority pattern interrupts a
// lower one; anything else waits in a single queue slot.
#pragma once
#include <stdint.h>
#include <Wire.h>

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

bool        haptic_begin(TwoWire &bus);
void        haptic_play(HapticPattern p);
// Play `first`, then `then` after `gapMs` (e.g. last rep, then set complete after 300 ms)
void        haptic_play_then(HapticPattern first, HapticPattern then, uint16_t gapMs);
void        haptic_stop();
void        haptic_update();       // call at least every few ms
bool        haptic_busy();
const char *haptic_name(HapticPattern p);
uint32_t    haptic_duration_ms(HapticPattern p);
void        haptic_wait(uint32_t ms);  // delay() that keeps patterns playing
