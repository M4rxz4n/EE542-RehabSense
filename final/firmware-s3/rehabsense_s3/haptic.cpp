#include <Arduino.h>
#include <Wire.h>
#include "Adafruit_DRV2605.h"
#include "pins.h"
#include "rs_log.h"
#include "haptic.h"

// One driver per motor. Both sit at 0x5A - the DRV2605L's address is fixed and
// has no strap - so they cannot answer on one bus. Two hardware answers to
// that, selected by RS_HAPTIC_MUX in pins.h: two separate MCU buses (the
// breadboard), or one bus through a TCA9543A 2-channel switch (the PCB).
struct Motor {
  Adafruit_DRV2605 drv;
  bool             ok;
  int16_t          lastLevel;
};

static Motor motors[RS_HAPTIC_COUNT];
static uint8_t foundMask = 0;

#if RS_HAPTIC_MUX

static uint8_t muxAddr = 0;      // 0 until found
static int8_t  muxCh   = -1;     // which channel is currently selected

// Point the switch at one motor. Cached, because at 100 Hz an uncached
// select would double the I2C traffic for no benefit; the DRV2605L writes
// are themselves skipped when the level has not changed.
static bool muxSelect(uint8_t idx) {
  if (!muxAddr) return false;
  if (muxCh == (int8_t)idx) return true;
  const uint8_t ctrl = idx == 0 ? HAPTIC_MUX_CH0 : HAPTIC_MUX_CH1;
  Wire.beginTransmission(muxAddr);
  Wire.write(ctrl);                        // the control byte, no register pointer
  if (Wire.endTransmission() != 0) {
    muxCh = -1;                            // force a retry next time
    return false;
  }
  muxCh = (int8_t)idx;
  return true;
}

// A1/A0 strapping is not readable from the schematic, so try all four and say
// which answered.
static bool muxFind() {
  for (uint8_t a = HAPTIC_MUX_ADDR_FIRST; a <= HAPTIC_MUX_ADDR_LAST; a++) {
    Wire.beginTransmission(a);
    if (Wire.endTransmission() != 0) continue;
    muxAddr = a;
    muxCh = -1;
    if (a != HAPTIC_MUX_ADDR)
      Log.printf("Haptics: TCA9543A found at 0x%02X, not the expected 0x%02X. "
                 "Build with -DHAPTIC_MUX_ADDR=0x%02X to skip this scan.\n",
                 a, (unsigned)HAPTIC_MUX_ADDR, a);
    return true;
  }
  Log.printf("Haptics: no TCA9543A answering at 0x%02X-0x%02X on GPIO%d (SDA) / "
             "GPIO%d (SCL). Both motors are behind it, so neither can be reached.\n",
             HAPTIC_MUX_ADDR_FIRST, HAPTIC_MUX_ADDR_LAST, PIN_I2C0_SDA, PIN_I2C0_SCL);
  return false;
}

#else
static inline bool muxSelect(uint8_t) { return true; }
#endif

// One step: motor strength moves linearly from `from` to `to` over `ms`.
// Strength is the DRV2605L real-time value: 0 = off, 127 = full forward.
struct Step { uint8_t from, to; uint16_t ms; };

static const Step P_REP[]   = {{127, 127, 100}};
static const Step P_FLAG[]  = {{127, 127, 80}, {0, 0, 80}, {127, 127, 80}, {0, 0, 80}, {127, 127, 80}};
static const Step P_SET[]   = {{127, 127, 70}, {0, 0, 70}, {127, 127, 70}, {0, 0, 150}, {127, 127, 500}};
static const Step P_REST[]  = {{35, 127, 500}, {127, 35, 500}};
static const Step P_FAULT[] = {{127, 127, 300}, {0, 0, 300}, {127, 127, 300}};
static const Step P_TICK[]  = {{127, 127, 40}};
static const Step P_SETL[]  = {{127, 127, 1000}};
static const Step P_CNT[]   = {{127, 127, 200}};
static const Step P_READY[] = {{127, 127, 200}, {0, 0, 150}, {127, 127, 200}};
static const Step P_GO[]    = {{127, 127, 700}};
static const Step P_HOLD[]  = {{75, 75, 980}};                     // back to back = continuous
static const Step P_DOWN[]  = {{127, 127, 40}, {0, 0, 70}, {127, 127, 40}};

// `home` is the motor a cue plays on when nobody asks for one in particular.
// Everything is HM_BOTH - the felt behaviour the one-motor sleeve was tuned
// against - except the guided-pace beat, which belongs on the forearm because
// the forearm is the part the beat is asking to move.
struct PatDef { const Step *steps; uint8_t n; uint8_t prio; HapticMotor home; const char *name; };
#define PAT(a) a, (uint8_t)(sizeof(a) / sizeof(a[0]))

static const PatDef PATS[HP_COUNT] = {
  {nullptr, 0, 0, HM_BOTH, "none"},
  {PAT(P_REP),   2, HM_BOTH, "rep counted"},
  {PAT(P_FLAG),  2, HM_BOTH, "rep counted, form flagged"},
  {PAT(P_SET),   3, HM_BOTH, "set complete"},
  {PAT(P_REST),  4, HM_BOTH, "rest now"},
  {PAT(P_FAULT), 5, HM_BOTH, "fault"},
  {PAT(P_TICK),  1, HM_BOTH, "tick"},
  {PAT(P_SETL),  3, HM_BOTH, "set complete (long)"},
  {PAT(P_CNT),   3, HM_BOTH, "countdown start (single)"},
  {PAT(P_READY), 3, HM_BOTH, "ready, 10 s left (double)"},
  {PAT(P_GO),    3, HM_FORE, "rep start (long)"},
  {PAT(P_HOLD),  1, HM_FORE, "pace: hold (steady buzz)"},
  {PAT(P_DOWN),  1, HM_FORE, "pace: down (double tick)"},
};

static HapticPattern cur = HP_NONE, pending = HP_NONE;
static HapticMotor   curMotor = HM_BOTH, pendingMotor = HM_DEFAULT;
static uint8_t  stepIdx = 0;
static uint32_t stepStart = 0;
static uint16_t pendingGap = 0;
static uint32_t idleSince = 0;

// Resolve HM_DEFAULT, then fall back onto whatever hardware actually answered.
// A sleeve with one motor fitted plays everything on it rather than dropping
// every forearm cue on the floor.
static HapticMotor resolve(HapticPattern p, HapticMotor m) {
  if (m == HM_DEFAULT) m = PATS[p].home;
  if (foundMask == 0) return m;
  uint8_t want = (m == HM_BOTH) ? 0x3 : (uint8_t)(1 << (m - 1));
  if (want & foundMask) return m;                   // at least one of the asked-for motors exists
  return (foundMask == 0x1) ? HM_UPPER : HM_FORE;   // otherwise use the one that does
}

static bool targets(HapticMotor m, uint8_t idx) {
  if (m == HM_BOTH) return true;
  return (uint8_t)(m - 1) == idx;
}

static void writeMotor(uint8_t idx, uint8_t v) {
  Motor &mo = motors[idx];
  if (!mo.ok || v == mo.lastLevel) return;
  if (!muxSelect(idx)) return;             // no-op unless RS_HAPTIC_MUX
  mo.drv.setRealtimeValue(v);
  mo.lastLevel = v;
}

// Drive the targeted motor(s) to `v` and hold everything else at rest, so a
// forearm-only cue cannot leave the upper-arm motor humming.
static void setLevel(uint8_t v) {
  for (uint8_t i = 0; i < RS_HAPTIC_COUNT; i++)
    writeMotor(i, targets(curMotor, i) ? v : 0);
}

static void allOff() {
  for (uint8_t i = 0; i < RS_HAPTIC_COUNT; i++) writeMotor(i, 0);
}

static void startPattern(HapticPattern p, HapticMotor m) {
  cur = p;
  curMotor = resolve(p, m);
  stepIdx = 0;
  stepStart = millis();
  setLevel(PATS[p].steps[0].from);
}

static bool startOne(uint8_t idx, TwoWire &bus) {
  Motor &mo = motors[idx];
  mo.lastLevel = -1;
  if (!muxSelect(idx)) { mo.ok = false; return false; }
  mo.ok = mo.drv.begin(&bus);
  if (!mo.ok) return false;
  mo.drv.useERM();
  mo.drv.setMode(DRV2605_MODE_REALTIME);
  mo.drv.setRealtimeValue(0);
  mo.lastLevel = 0;
  foundMask |= (uint8_t)(1 << idx);
  return true;
}

bool haptic_begin() {
  foundMask = 0;
#if RS_HAPTIC_MUX
  // Both motors are downstream of the switch, so nothing is reachable until
  // it is found. Same bus for both; the channel is what differs.
  muxAddr = 0;
  if (!muxFind()) return false;
  startOne(0, Wire);
  startOne(1, Wire);
#else
  startOne(0, Wire);
  #if RS_HAPTIC_COUNT > 1
  startOne(1, Wire1);
  #endif
#endif

  if (foundMask == 0x3) return true;
  if (foundMask == 0) {
    Log.printf("Haptics: no DRV2605L answering at 0x%02X on either %s. "
               "Check 3V3, GND, SDA, SCL and EN.\n",
               HAPTIC_ADDR, RS_HAPTIC_MUX ? "switch channel" : "bus");
    return false;
  }
#if RS_HAPTIC_COUNT > 1
  // One of two. Say which is missing and where to look, then carry on - a
  // sleeve with one working motor is worth running.
  bool haveUpper = foundMask & 0x1;
  const char *have    = haveUpper ? "upper-arm" : "forearm";
  const char *missing = haveUpper ? "forearm" : "upper-arm";
  #if RS_HAPTIC_MUX
  Log.printf("Haptics: only the %s DRV2605L answered. Nothing at 0x%02X behind "
             "channel %d of the TCA9543A at 0x%02X.\n"
             "  Every cue will play on the %s motor until it is fixed.\n",
             have, HAPTIC_ADDR, haveUpper ? 1 : 0, muxAddr, have);
  #else
  Log.printf("Haptics: only the %s DRV2605L answered. The %s one is not on "
             "GPIO%d (SDA) / GPIO%d (SCL) at 0x%02X.\n"
             "  Every cue will play on the %s motor until it is fixed.\n",
             have, missing,
             haveUpper ? PIN_I2C1_SDA : PIN_I2C0_SDA,
             haveUpper ? PIN_I2C1_SCL : PIN_I2C0_SCL,
             HAPTIC_ADDR, have);
  #endif
  (void)missing;
#endif
  return true;
}

void haptic_play(HapticPattern p, HapticMotor m) {
  if (p == HP_NONE || p >= HP_COUNT) return;
  if (cur == HP_NONE && pending == HP_NONE) { startPattern(p, m); return; }
  if (cur != HP_NONE && PATS[p].prio > PATS[cur].prio) {   // interrupt a lower-priority pattern
    pending = HP_NONE;
    startPattern(p, m);
    return;
  }
  // Otherwise queue it (single slot: keep the higher-priority one)
  if (pending == HP_NONE || PATS[p].prio >= PATS[pending].prio) {
    pending = p;
    pendingMotor = m;
    pendingGap = 150;
  }
}

void haptic_play(HapticPattern p) { haptic_play(p, HM_DEFAULT); }

void haptic_play_then(HapticPattern first, HapticPattern then, uint16_t gapMs) {
  if (first == HP_NONE) { haptic_play(then); return; }
  haptic_play(first);
  if (cur == first) { pending = then; pendingMotor = HM_DEFAULT; pendingGap = gapMs; }
  else haptic_play(then);
}

void haptic_stop() {
  cur = pending = HP_NONE;
  allOff();
}

bool haptic_busy() { return cur != HP_NONE || pending != HP_NONE; }

void haptic_update() {
  uint32_t now = millis();
  if (cur == HP_NONE) {
    if (pending != HP_NONE && now - idleSince >= pendingGap) {
      HapticPattern p = pending;
      HapticMotor   m = pendingMotor;
      pending = HP_NONE;
      pendingMotor = HM_DEFAULT;
      startPattern(p, m);
    }
    return;
  }
  const PatDef &pd = PATS[cur];
  uint32_t el = now - stepStart;
  while (el >= pd.steps[stepIdx].ms) {          // move on to the next step(s)
    stepStart += pd.steps[stepIdx].ms;
    el -= pd.steps[stepIdx].ms;
    if (++stepIdx >= pd.n) {                    // pattern finished
      allOff();
      cur = HP_NONE;
      idleSince = now;
      return;
    }
  }
  const Step &s = pd.steps[stepIdx];
  int level = s.from + ((int)s.to - (int)s.from) * (int)el / (int)s.ms;
  setLevel((uint8_t)level);
}

const char *haptic_name(HapticPattern p) { return p < HP_COUNT ? PATS[p].name : "?"; }

uint32_t haptic_duration_ms(HapticPattern p) {
  if (p == HP_NONE || p >= HP_COUNT) return 0;
  uint32_t t = 0;
  for (uint8_t i = 0; i < PATS[p].n; i++) t += PATS[p].steps[i].ms;
  return t;
}

void haptic_wait(uint32_t ms) {
  uint32_t t0 = millis();
  while (millis() - t0 < ms) { haptic_update(); delay(1); }
}

uint8_t haptic_motors_found() { return foundMask; }

uint8_t haptic_motor_count() {
  uint8_t n = 0;
  for (uint8_t i = 0; i < RS_HAPTIC_COUNT; i++) if (foundMask & (1 << i)) n++;
  return n;
}

const char *haptic_motor_name(HapticMotor m) {
  switch (m) {
    case HM_UPPER: return "upper-arm";
    case HM_FORE:  return "forearm";
    case HM_BOTH:  return "both";
    default:       return "default";
  }
}

HapticMotor haptic_home(HapticPattern p) { return p < HP_COUNT ? PATS[p].home : HM_BOTH; }
