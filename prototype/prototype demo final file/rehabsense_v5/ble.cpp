#include <Arduino.h>
#include <NimBLEDevice.h>
#include <esp_timer.h>
#include <string.h>
#include "ble.h"
#include "rs_proto.h"
#include "rs_log.h"
#include "imu.h"
#include "emg.h"
#include "rep.h"
#include "calib.h"
#include "comms.h"
#include "autopause.h"
#include "haptic.h"
#include "params.h"

#define TEAM_UUID(n) "a5b1" n "-7c4e-4d9a-9e3f-1d2c3b4a5968"

volatile bool calibAbort = false;

struct Cmd { uint8_t len; uint8_t d[127]; };
static QueueHandle_t cmdQ = nullptr;
static NimBLECharacteristic *chCtrl, *chRaw, *chEvents, *chStatus, *chBackfill, *chCalib,
                            *chConfig, *chXfer, *chText;
static volatile bool connected = false;
static volatile bool subRaw = false, subEvents = false, subText = false;   // what the client turned notifications on for
static uint32_t featSeq = 0, imuSeq = 0;
static uint32_t lastFeatMs = 0, lastStatusMs = 0;
static int64_t  hostOffsetUs = 0;
static uint32_t hostEpochS = 0;
static uint8_t  lastFwState = 0xFF;
static bool     rawStream = true;

static float    imuUp[wire::IMU_BATCH][6], imuFo[wire::IMU_BATCH][6];
static uint8_t  imuN = 0;
static uint64_t imuT0 = 0;

static uint64_t nowUs() { return (uint64_t)esp_timer_get_time(); }

// Outgoing queues, drained a little every tick; an item leaves the queue only
// once NimBLE has accepted it.
struct EvOut { uint8_t n; uint8_t b[wire::HEADER_BYTES + 2 + 16]; };
static EvOut    evQ[24];
static uint8_t  evHead = 0, evTail = 0;
static char     txQ[3072];               // printed lines for 000A
static uint16_t txHead = 0, txTail = 0;

// ---- callbacks: run on the Bluetooth task, so they only queue ----

class ServerCB : public NimBLEServerCallbacks {
 public:
  void onConnect(NimBLEServer *s, NimBLEConnInfo &info) override {
    connected = true;
    s->updateConnParams(info.getConnHandle(), 12, 24, 0, 400);   // 15-30 ms interval, 4 s timeout
  }
  void onDisconnect(NimBLEServer *s, NimBLEConnInfo &info, int reason) override {
    connected = false;                       // counting and haptics carry on
    subRaw = subEvents = subText = false;
    NimBLEDevice::startAdvertising();        // so the app or viewer can reconnect
  }
};

static void enqueue(uint8_t prefix, const uint8_t *data, size_t n) {
  if (!cmdQ) return;
  Cmd c;
  size_t k = 0;
  if (prefix) c.d[k++] = prefix;
  if (n > sizeof(c.d) - k) n = sizeof(c.d) - k;
  memcpy(c.d + k, data, n);
  c.len = (uint8_t)(k + n);
  if (c.len) xQueueSend(cmdQ, &c, 0);
}

class ControlCB : public NimBLECharacteristicCallbacks {
 public:
  void onWrite(NimBLECharacteristic *c, NimBLEConnInfo &info) override {
    NimBLEAttValue v = c->getValue();
    if (v.length() && v.data()[0] == wire::C_ABORT_CALIBRATION) calibAbort = true;   // calibration blocks the loop
    enqueue(0, v.data(), v.length());
  }
};
class CalibWriteCB : public NimBLECharacteristicCallbacks {
 public:
  void onWrite(NimBLECharacteristic *c, NimBLEConnInfo &info) override {
    NimBLEAttValue v = c->getValue();
    enqueue(wire::C_INTERNAL_CALIB_WRITE, v.data(), v.length());
  }
};

// Notifications with a custom value go to every connected client whether it
// subscribed or not, and NimBLE has only about 12 buffers for them. So: send only
// what the client asked for (onSubscribe), and queue events and printed lines
// instead of sending a burst at once (bursts used to drop most of the lines).
class SubscribeCB : public NimBLECharacteristicCallbacks {
 public:
  void onSubscribe(NimBLECharacteristic *c, NimBLEConnInfo &info, uint16_t subValue) override {
    bool on = subValue != 0;
    if (c == chRaw) subRaw = on;
    else if (c == chEvents) subEvents = on;
    else if (c == chText) subText = on;
  }
};

static ServerCB     serverCB;
static SubscribeCB  subscribeCB;
static ControlCB    controlCB;
static CalibWriteCB calibCB;

static void notifyChr(NimBLECharacteristic *ch, const uint8_t *b, size_t n) {
  if (connected && ch) ch->notify(b, n);
}

// ---- mappings from this firmware to the team protocol ----

static uint8_t fwState() {
  if (!imuOk)        return wire::S_FAULT;
  if (calibrating)   return wire::S_CALIBRATION;
  if (calibrated && !resting && !sessionDone && !ap_paused()) return wire::S_OPERATIONAL;
  return wire::S_STANDBY;          // waiting, resting between sets, paused, session done
}

static uint8_t teamRepState() {
  switch (repState) {
    case ST_RISING:    return wire::R_CONCENTRIC;
    case ST_PEAK:      return wire::R_PEAK;
    case ST_RETURNING: return wire::R_ECCENTRIC;
    default:           return wire::R_READY;
  }
}

static wire::Config currentConfig() {
  wire::Config c;
  c.rep_target   = (uint8_t)P.reps_per_set;
  c.set_count    = (uint8_t)P.sets;
  c.rest_seconds = (uint16_t)P.rest_s;
  c.target_deg   = P.target_deg;
  c.start_deg    = P.start_deg;
  c.finish_deg   = P.start_deg - P.hyst_deg;
  c.tempo_min    = P.tempo_min_s;
  c.tempo_max    = P.tempo_max_s;
  c.shoulder_deg = P.shoulder_deg;
  c.trunk_deg    = 0;                         // trunk lean not measured separately (part of FC4)
  c.swing_dps    = P.swing_dps;
  c.ded_shoulder = P.ded_shoulder;
  c.ded_trunk    = 0;
  c.ded_swing    = P.ded_swing;
  c.raw_stream   = rawStream ? 1 : 0;
  return c;
}

// ---- setup ----

void ble_begin() {
  cmdQ = xQueueCreate(8, sizeof(Cmd));
  NimBLEDevice::init("RehabSense");
  NimBLEDevice::setMTU(247);
  NimBLEServer *srv = NimBLEDevice::createServer();
  srv->setCallbacks(&serverCB, false);
  NimBLEService *svc = srv->createService(TEAM_UUID("0001"));
  chCtrl     = svc->createCharacteristic(TEAM_UUID("0002"), NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  chRaw      = svc->createCharacteristic(TEAM_UUID("0003"), NIMBLE_PROPERTY::NOTIFY);
  chEvents   = svc->createCharacteristic(TEAM_UUID("0004"), NIMBLE_PROPERTY::NOTIFY);
  chStatus   = svc->createCharacteristic(TEAM_UUID("0005"), NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);
  chBackfill = svc->createCharacteristic(TEAM_UUID("0006"), NIMBLE_PROPERTY::NOTIFY);
  chCalib    = svc->createCharacteristic(TEAM_UUID("0007"), NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::WRITE, 128);
  chConfig   = svc->createCharacteristic(TEAM_UUID("0008"), NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY, 128);
  chXfer     = svc->createCharacteristic(TEAM_UUID("0009"), NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY, 64);
  chText     = svc->createCharacteristic(TEAM_UUID("000a"), NIMBLE_PROPERTY::NOTIFY);
  chCtrl->setCallbacks(&controlCB);
  chCalib->setCallbacks(&calibCB);
  chRaw->setCallbacks(&subscribeCB);
  chEvents->setCallbacks(&subscribeCB);
  chText->setCallbacks(&subscribeCB);
  uint8_t xfer[63] = {0};
  chXfer->setValue(xfer, sizeof(xfer));
  svc->start();                              // a service that isn't started is left out of the GATT table
  ble_refresh_calib();
  ble_send_config();
  ble_send_status();

  // The team client finds the sleeve by name, so the name goes in the advertising
  // packet; the 128-bit service UUID goes in the scan response.
  NimBLEAdvertising *adv = NimBLEDevice::getAdvertising();
  NimBLEAdvertisementData ad, sr;
  ad.setFlags(0x06);
  ad.setName("RehabSense");
  sr.addServiceUUID(TEAM_UUID("0001"));
  adv->setAdvertisementData(ad);
  adv->setScanResponseData(sr);
  adv->enableScanResponse(true);
  adv->start();
  Log.println("# Bluetooth advertising as \"RehabSense\"");
}

bool ble_connected() { return connected; }

// ---- periodic output ----

static void sendFeatures() {
  wire::Features f;
  f.t_us          = nowUs();
  f.envelope      = emgPct / 100.0f;
  f.mdf           = 0;
  f.elbow_deg     = angleDeg;
  f.upper_dev_deg = upperTiltDeg;
  f.rep_state     = teamRepState();
  f.rep_count     = (uint16_t)repsInSet;
  f.comp_flags    = (upperTiltDeg > P.shoulder_deg ? wire::COMP_SHOULDER : 0)
                  | (upperGyroDeg > P.swing_dps ? wire::COMP_SWING : 0);
  f.sig_flags     = 0;
  f.activation_on = emgOn ? 1 : 0;
  uint8_t b[wire::FEATURES_BYTES];
  size_t n = wire::features(b, featSeq++, f);
  notifyChr(chEvents, b, n);
}

static void pushImuSample() {
  if (imuN == 0) imuT0 = nowUs();
  memcpy(imuUp[imuN], imuRawU, sizeof(imuRawU));
  memcpy(imuFo[imuN], imuRawF, sizeof(imuRawF));
  if (++imuN < wire::IMU_BATCH) return;
  uint8_t b[wire::FRAME_MAX];
  size_t n = wire::imu(b, imuSeq, imuT0, imuUp, imuFo, imuN);
  imuSeq += imuN;
  imuN = 0;
  if (rawStream) notifyChr(chRaw, b, n);
}

void ble_evt(uint8_t id, const uint8_t *payload, uint8_t len) {
  if (!connected || !subEvents) return;
  uint8_t nx = (evHead + 1) % (sizeof(evQ) / sizeof(evQ[0]));
  if (nx == evTail) evTail = (evTail + 1) % (sizeof(evQ) / sizeof(evQ[0]));   // full: drop the oldest
  evQ[evHead].n = (uint8_t)wire::event(evQ[evHead].b, nowUs(), id, payload, len);
  evHead = nx;
}

static void drainEvents() {
  for (int k = 0; k < 4 && evTail != evHead; k++) {
    if (!chEvents->notify(evQ[evTail].b, evQ[evTail].n)) return;   // no buffer free: try next tick
    evTail = (evTail + 1) % (sizeof(evQ) / sizeof(evQ[0]));
  }
}

static void drainText() {
  const uint16_t N = sizeof(txQ);
  for (int k = 0; k < 2 && txTail != txHead; k++) {
    uint8_t chunk[wire::FRAME_MAX];
    uint16_t n = 0, lastNl = 0, i = txTail;
    while (i != txHead && n < sizeof(chunk)) {
      chunk[n++] = (uint8_t)txQ[i];
      if (txQ[i] == '\n') lastNl = n;
      i = (i + 1) % N;
    }
    if (n == sizeof(chunk) && lastNl) n = lastNl;     // whole lines per notification when they fit
    if (!chText->notify(chunk, n)) return;
    txTail = (txTail + n) % N;
  }
}

void ble_send_status() {
  if (!chStatus) return;
  wire::Status s;
  s.fw_state       = fwState();
  s.fault          = imuOk ? wire::F_NONE : wire::F_IMU_UNRESPONSIVE;
  s.battery_pct    = 100;                  // USB / power-bank powered: no battery to measure
  s.battery_mv     = 5000;
  s.signal_quality = 100;
  s.seq_oldest     = 0;
  s.seq_newest     = 0;
  s.clip_count     = 0;
  s.flags          = 0;
  s.rep_count      = (uint16_t)reps;
  s.host_offset_us = hostOffsetUs;
  uint8_t b[wire::STATUS_BYTES];
  size_t n = wire::status(b, s);
  chStatus->setValue(b, n);
  if (connected) chStatus->notify();
}

void ble_tick() {
  if (!chEvents) return;                   // not started yet
  uint32_t now = millis();
  uint8_t st = fwState();
  if (st != lastFwState) {                 // EVT_STATE_CHANGE on every transition
    lastFwState = st;
    ble_evt(wire::E_STATE_CHANGE, &st, 1);
    ble_send_status();
  }
  if (now - lastStatusMs >= 1000) { lastStatusMs = now; ble_send_status(); }
  if (!connected) { imuN = 0; evHead = evTail = 0; txHead = txTail = 0; return; }
  drainEvents();                           // events first: reps, sets and state changes matter most
  drainText();
  if (subEvents && now - lastFeatMs >= 20) { lastFeatMs = now; sendFeatures(); }   // 50 Hz
  if (subRaw && imuOk) pushImuSample(); else imuN = 0;
}

// ---- events ----

void ble_rep(uint16_t idx, uint8_t score, uint8_t rom, float peakDeg, uint16_t comp, uint32_t durMs) {
  wire::RepComplete r = {idx, score, rom, 0, 0, 0, (int16_t)(peakDeg * 10), comp, durMs};
  uint8_t p[16];
  wire::rep_complete(p, r);
  ble_evt(wire::E_REP_COMPLETE, p, 16);
  if (comp & wire::COMP_SHOULDER) ble_evt(wire::E_COMP_SHOULDER);
  if (comp & wire::COMP_SWING)    ble_evt(wire::E_COMP_SWING);
  ble_send_status();
}

void ble_partial(uint16_t nextIndex, float peakDeg) {       // "<Hh": index, peak x10 (as rehab_sim.py)
  int16_t pk = (int16_t)(peakDeg * 10);
  uint8_t p[4] = {(uint8_t)nextIndex, (uint8_t)(nextIndex >> 8), (uint8_t)pk, (uint8_t)((uint16_t)pk >> 8)};
  ble_evt(wire::E_REP_ABANDONED, p, 4);
}

void ble_fatigue(int16_t signs, uint16_t reps) {             // "<hH": signs (1-3, 9 = partial streak), reps
  uint8_t p[4] = {(uint8_t)signs, (uint8_t)((uint16_t)signs >> 8), (uint8_t)reps, (uint8_t)(reps >> 8)};
  ble_evt(wire::E_FATIGUE_WARN, p, 4);
}

void ble_set_complete(uint16_t n) {
  if (n == 0xFFFF) { ble_evt(wire::E_SET_COMPLETE); return; }
  uint8_t p[2] = {(uint8_t)n, (uint8_t)(n >> 8)};
  ble_evt(wire::E_SET_COMPLETE, p, 2);
}

void ble_calib_phase(uint8_t phase, uint8_t pct) {
  uint8_t p[2] = {phase, pct};
  ble_evt(wire::E_CALIB_PHASE_DONE, p, 2);
}

void ble_fault(bool raised) {
  if (raised) { uint8_t f = wire::F_IMU_UNRESPONSIVE; ble_evt(wire::E_FAULT, &f, 1); }
  ble_send_status();                       // cleared: the STATE_CHANGE back says so
}

void ble_text_line(const char *s, size_t n) {
  if (!chText || !connected || !subText) return;
  const uint16_t N = sizeof(txQ);
  uint16_t used = (txHead + N - txTail) % N;
  if (n > (size_t)(N - 1 - used)) return;  // queue full: drop this line rather than half of it
  for (size_t i = 0; i < n; i++) { txQ[txHead] = s[i]; txHead = (txHead + 1) % N; }
}

// ---- settings, calibration record ----

void ble_send_config() {
  if (!chConfig) return;
  uint8_t b[128];
  size_t n = wire::config_tlv(b, sizeof(b), currentConfig());
  chConfig->setValue(b, n);
  notifyChr(chConfig, b, n);
}

static int applyConfig(const uint8_t *tlv, size_t len) {
  wire::Config c = currentConfig();
  int n = wire::config_parse(tlv, len, c);
  if (n < 0) return -1;
  P.reps_per_set  = constrain(c.rep_target, 1, 50);
  P.sets          = constrain(c.set_count, 1, 10);
  P.rest_s        = constrain(c.rest_seconds, 5, 600);
  P.target_deg    = constrain(c.target_deg, 40.0f, 140.0f);
  P.start_deg     = constrain(c.start_deg, 5.0f, 40.0f);
  P.hyst_deg      = constrain(c.start_deg - c.finish_deg, 1.0f, 20.0f);
  P.tempo_min_s   = c.tempo_min;
  P.tempo_max_s   = c.tempo_max;
  P.shoulder_deg  = c.shoulder_deg;
  P.swing_dps     = c.swing_dps;
  P.ded_shoulder  = (int)c.ded_shoulder;
  P.ded_swing     = (int)c.ded_swing;
  rawStream       = c.raw_stream != 0;
  ble_send_config();
  Log.printf("# App: settings updated (%d) reps=%d sets=%d rest=%d target=%.0f\n",
             n, P.reps_per_set, P.sets, P.rest_s, P.target_deg);
  return n;
}

void ble_refresh_calib() {
  if (!chCalib) return;
  wire::Calib c = {};
  c.version   = 2;
  c.timestamp = hostEpochS;
  c.rest_rms  = emgRestMv;
  c.rest_sd   = emgRestSd;
  c.mvc       = emgMaxMv;
  for (int k = 0; k < 3; k++) { c.gyro_bias[k] = biasU[k]; c.gyro_bias[3 + k] = biasF[k]; }
  c.q_upper0[0] = 1;                                   // the sleeve stores only the relative pose
  c.q_fore0[0] = qCal.w; c.q_fore0[1] = qCal.x; c.q_fore0[2] = qCal.y; c.q_fore0[3] = qCal.z;
  c.flexion_axis[2] = 1;
  c.angle_min = 0;
  c.angle_max = P.target_deg;
  uint8_t b[wire::CALIB_BYTES];
  size_t n = wire::calib(b, c);
  chCalib->setValue(b, n);
}

static void hapticTest(uint8_t p) {
  switch (p) {
    case wire::TP_TICK:                 haptic_play(HP_TICK); break;
    case wire::TP_REP_CLEAN:            haptic_play(HP_REP_OK); break;
    case wire::TP_REP_FLAGGED:          haptic_play(HP_REP_FLAGGED); break;
    case wire::TP_SET_COMPLETE:         haptic_play(HP_SET_COMPLETE); break;
    case wire::TP_REST:                 haptic_play(HP_REST); break;
    case wire::TP_FAULT:                haptic_play(HP_FAULT); break;
    case wire::TP_SOFT_CLICK:           haptic_play(HP_TICK); break;
    case wire::TP_REP_CLEAN_THEN_SET:   haptic_play_then(HP_REP_OK, HP_SET_COMPLETE, 300); break;
    case wire::TP_REP_FLAGGED_THEN_SET: haptic_play_then(HP_REP_FLAGGED, HP_SET_COMPLETE, 300); break;
    default: break;
  }
}

// ---- commands ----

void ble_poll(bool inCal) {
  if (!cmdQ) return;
  Cmd c;
  // During calibration, leave anything that would start or stop a session in the queue
  while (xQueuePeek(cmdQ, &c, 0) == pdTRUE) {
    uint8_t op = c.d[0];
    const uint8_t *pl = c.d + 1;
    size_t pn = c.len ? c.len - 1 : 0;
    bool safeDuringCal = op == wire::C_TEXT || op == wire::C_ABORT_CALIBRATION || op == wire::C_HAPTIC_TEST ||
                         op == wire::C_GET_CONFIG || op == wire::C_SET_TIME || op == wire::C_ACK_SEQ ||
                         op == wire::C_INTERNAL_CALIB_WRITE;
    if (inCal && !safeDuringCal) return;           // handled after calibration
    xQueueReceive(cmdQ, &c, 0);

    switch (op) {
      case wire::C_TEXT: {                         // RehabSense extension: a typed command
        char t[64];
        size_t k = pn < sizeof(t) - 1 ? pn : sizeof(t) - 1;
        memcpy(t, pl, k); t[k] = 0;
        comms_inject(t);
        break;
      }
      case wire::C_START_SESSION:
        Log.println("# App: start");
        if (!calibrated)       calibrate(true);    // runs the 3 steps by itself, then starts
        else if (resting)      rep_skip_rest();
        else if (sessionDone)  comms_inject("r");
        break;
      case wire::C_STOP_SESSION:
      case wire::C_POWER_OFF:
        Log.println("# App: stop");
        rep_stop();
        ble_set_complete(0xFFFF);
        break;
      case wire::C_START_CALIBRATION:
        if (pn && pl[0] == wire::CP_STRAIGHT) { Log.println("# App: re-zero"); comms_inject("z"); }
        else                                  { Log.println("# App: calibrate"); calibrate(true); }
        break;
      case wire::C_REQUEST_RECALIBRATION:
        Log.println("# App: calibrate"); calibrate(true);
        break;
      case wire::C_ABORT_CALIBRATION:
        calibAbort = !inCal ? false : true;        // only meaningful mid-calibration
        break;
      case wire::C_SET_CONFIG:
        if (applyConfig(pl, pn) < 0) Log.println("# App: settings rejected (bad length)");
        break;
      case wire::C_GET_CONFIG: ble_send_config(); break;
      case wire::C_HAPTIC_TEST: if (pn) hapticTest(pl[0]); break;
      case wire::C_SET_TIME:
        if (pn >= 8) {
          uint64_t e = 0;
          for (int i = 7; i >= 0; i--) e = (e << 8) | pl[i];
          hostOffsetUs = (int64_t)e - (int64_t)nowUs();
          hostEpochS   = (uint32_t)(e / 1000000ULL);
          ble_send_status();
        }
        break;
      case wire::C_START_TRANSFER: {
        uint8_t x[63] = {0};
        x[0] = 4;                                  // XferState.FAILED: no Wi-Fi transfer on this board
        chXfer->setValue(x, sizeof(x));
        notifyChr(chXfer, x, sizeof(x));
        break;
      }
      default: break;                              // ACK_SEQ, BACKFILL, STOP_TRANSFER, calib writes: nothing to do
    }
  }
}
