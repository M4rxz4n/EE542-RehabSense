#include <Arduino.h>
#include "Adafruit_DRV2605.h"
#include "haptic.h"

static Adafruit_DRV2605 drv;
static bool drvOk = false;

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

struct PatDef { const Step *steps; uint8_t n; uint8_t prio; const char *name; };
#define PAT(a) a, (uint8_t)(sizeof(a) / sizeof(a[0]))

static const PatDef PATS[HP_COUNT] = {
  {nullptr, 0, 0, "none"},
  {PAT(P_REP),   2, "rep counted"},
  {PAT(P_FLAG),  2, "rep counted, form flagged"},
  {PAT(P_SET),   3, "set complete"},
  {PAT(P_REST),  4, "rest now"},
  {PAT(P_FAULT), 5, "fault"},
  {PAT(P_TICK),  1, "tick"},
  {PAT(P_SETL),  3, "set complete (long)"},
  {PAT(P_CNT),   3, "countdown start (single)"},
  {PAT(P_READY), 3, "ready, 10 s left (double)"},
  {PAT(P_GO),    3, "rep start (long)"},
  {PAT(P_HOLD),  1, "pace: hold (steady buzz)"},
  {PAT(P_DOWN),  1, "pace: down (double tick)"},
};

static HapticPattern cur = HP_NONE, pending = HP_NONE;
static uint8_t  stepIdx = 0;
static uint32_t stepStart = 0;
static uint16_t pendingGap = 0;
static uint32_t idleSince = 0;
static int16_t  lastLevel = -1;

static void setLevel(uint8_t v) {
  if (v == lastLevel || !drvOk) return;
  drv.setRealtimeValue(v);
  lastLevel = v;
}

static void startPattern(HapticPattern p) {
  cur = p;
  stepIdx = 0;
  stepStart = millis();
  setLevel(PATS[p].steps[0].from);
}

bool haptic_begin(TwoWire &bus) {
  drvOk = drv.begin(&bus);
  if (!drvOk) return false;
  drv.useERM();
  drv.setMode(DRV2605_MODE_REALTIME);
  lastLevel = -1;
  setLevel(0);
  return true;
}

void haptic_play(HapticPattern p) {
  if (p == HP_NONE || p >= HP_COUNT) return;
  if (cur == HP_NONE && pending == HP_NONE) { startPattern(p); return; }
  if (cur != HP_NONE && PATS[p].prio > PATS[cur].prio) {   // interrupt a lower-priority pattern
    pending = HP_NONE;
    startPattern(p);
    return;
  }
  // Otherwise queue it (single slot: keep the higher-priority one)
  if (pending == HP_NONE || PATS[p].prio >= PATS[pending].prio) {
    pending = p;
    pendingGap = 150;
  }
}

void haptic_play_then(HapticPattern first, HapticPattern then, uint16_t gapMs) {
  if (first == HP_NONE) { haptic_play(then); return; }
  haptic_play(first);
  if (cur == first) { pending = then; pendingGap = gapMs; }
  else haptic_play(then);
}

void haptic_stop() {
  cur = pending = HP_NONE;
  setLevel(0);
}

bool haptic_busy() { return cur != HP_NONE || pending != HP_NONE; }

void haptic_update() {
  uint32_t now = millis();
  if (cur == HP_NONE) {
    if (pending != HP_NONE && now - idleSince >= pendingGap) {
      HapticPattern p = pending;
      pending = HP_NONE;
      startPattern(p);
    }
    return;
  }
  const PatDef &pd = PATS[cur];
  uint32_t el = now - stepStart;
  while (el >= pd.steps[stepIdx].ms) {          // move on to the next step(s)
    stepStart += pd.steps[stepIdx].ms;
    el -= pd.steps[stepIdx].ms;
    if (++stepIdx >= pd.n) {                    // pattern finished
      setLevel(0);
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
