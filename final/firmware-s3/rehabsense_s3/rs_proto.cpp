#include <string.h>
#include "rs_proto.h"

namespace wire {

// Explicit little-endian writers, so the layout never depends on struct padding.
static size_t u8(uint8_t *o, uint8_t v)   { o[0] = v; return 1; }
static size_t u16(uint8_t *o, uint16_t v) { o[0] = v; o[1] = v >> 8; return 2; }
static size_t u32(uint8_t *o, uint32_t v) { for (int i = 0; i < 4; i++) o[i] = v >> (8 * i); return 4; }
static size_t u64(uint8_t *o, uint64_t v) { for (int i = 0; i < 8; i++) o[i] = v >> (8 * i); return 8; }
static size_t f32(uint8_t *o, float v)    { uint32_t b; memcpy(&b, &v, 4); return u32(o, b); }
static size_t i16(uint8_t *o, int16_t v)  { return u16(o, (uint16_t)v); }

static uint16_t rd16(const uint8_t *p) { return p[0] | (p[1] << 8); }
static float    rdf(const uint8_t *p)  { uint32_t b = p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24);
                                         float v; memcpy(&v, &b, 4); return v; }

size_t header(uint8_t *o, uint8_t type, uint32_t seq, uint64_t t_us, uint8_t n) {
  size_t k = 0;
  k += u8(o + k, type);
  k += u32(o + k, seq);
  k += u64(o + k, t_us);
  k += u8(o + k, n);
  return k;   // 14
}

size_t features(uint8_t *o, uint32_t seq, const Features &f) {
  size_t k = header(o, FT_FEATURES, seq, f.t_us, 1);
  k += u64(o + k, f.t_us);
  k += f32(o + k, f.envelope);
  k += f32(o + k, f.mdf);
  k += f32(o + k, f.elbow_deg);
  k += f32(o + k, f.upper_dev_deg);
  k += u8(o + k, f.rep_state);
  k += u16(o + k, f.rep_count);
  k += u16(o + k, f.comp_flags);
  k += u16(o + k, f.sig_flags);
  k += u8(o + k, f.activation_on);
  return k;   // 14 + 32
}

size_t event(uint8_t *o, uint64_t t_us, uint8_t id, const uint8_t *payload, uint8_t len) {
  if (len > 16) len = 16;
  size_t k = header(o, FT_EVENT, 0, t_us, 1);
  k += u8(o + k, id);
  k += u8(o + k, len);
  if (len) { memcpy(o + k, payload, len); k += len; }
  return k;
}

size_t rep_complete(uint8_t *o, const RepComplete &r) {
  size_t k = 0;
  k += u16(o + k, r.index);
  k += u8(o + k, r.score);
  k += u8(o + k, r.rom_pct);
  k += u8(o + k, r.cocon_pct);
  k += u8(o + k, r.smooth_pct);
  k += u8(o + k, r.hold_pct);
  k += u8(o + k, 0);            // pad
  k += i16(o + k, r.peak_dd);
  k += u16(o + k, r.comp_flags);
  k += u32(o + k, r.duration_ms);
  return k;   // 16
}

static int16_t sat16(float v) { return v > 32767 ? 32767 : (v < -32768 ? -32768 : (int16_t)v); }

size_t imu(uint8_t *o, uint32_t seq, uint64_t t_us, const float up[][6], const float fo[][6], uint8_t n) {
  if (n > IMU_BATCH) n = IMU_BATCH;
  size_t k = header(o, FT_IMU, seq, t_us, n);
  for (uint8_t i = 0; i < n; i++) {
    const float *dev[2] = {up[i], fo[i]};
    for (int d = 0; d < 2; d++) {
      for (int a = 0; a < 3; a++) k += i16(o + k, sat16(dev[d][a] * 1000.0f));       // g -> mg
      for (int a = 3; a < 6; a++) k += i16(o + k, sat16(dev[d][a] * 10.0f));         // deg/s x10
    }
  }
  return k;
}

size_t status(uint8_t *o, const Status &s) {
  size_t k = 0;
  k += u8(o + k, s.fw_state);
  k += u8(o + k, s.fault);
  k += u8(o + k, s.battery_pct);
  k += u16(o + k, s.battery_mv);
  k += u8(o + k, s.signal_quality);
  k += u32(o + k, s.seq_oldest);
  k += u32(o + k, s.seq_newest);
  k += u32(o + k, s.clip_count);
  k += u8(o + k, s.flags);
  k += u16(o + k, s.rep_count);
  k += u64(o + k, (uint64_t)s.host_offset_us);
  return k;   // 29
}

size_t calib(uint8_t *o, const Calib &c) {
  size_t k = 0;
  k += u32(o + k, c.version);
  k += u32(o + k, c.timestamp);
  k += f32(o + k, c.rest_rms);
  k += f32(o + k, c.rest_sd);
  k += f32(o + k, c.mvc);
  k += f32(o + k, c.mdf_baseline);
  for (float v : c.gyro_bias)    k += f32(o + k, v);
  for (float v : c.q_upper0)     k += f32(o + k, v);
  for (float v : c.q_fore0)      k += f32(o + k, v);
  for (float v : c.flexion_axis) k += f32(o + k, v);
  k += f32(o + k, c.angle_min);
  k += f32(o + k, c.angle_max);
  k += u8(o + k, c.flags);
  o[k++] = 0; o[k++] = 0; o[k++] = 0;   // pad to 4
  return k;   // 104
}

static size_t tlvHead(uint8_t *o, uint8_t tag, uint8_t len) { o[0] = tag; o[1] = len; return 2; }

size_t config_tlv(uint8_t *o, size_t cap, const Config &c) {
  uint8_t b[128];
  size_t k = 0;
  k += tlvHead(b + k, T_REP_TARGET, 1);   k += u8(b + k, c.rep_target);
  k += tlvHead(b + k, T_SET_COUNT, 1);    k += u8(b + k, c.set_count);
  k += tlvHead(b + k, T_REST_SECONDS, 2); k += u16(b + k, c.rest_seconds);
  k += tlvHead(b + k, T_TARGET_ANGLE, 4); k += f32(b + k, c.target_deg);
  k += tlvHead(b + k, T_START_ANGLE, 4);  k += f32(b + k, c.start_deg);
  k += tlvHead(b + k, T_FINISH_ANGLE, 4); k += f32(b + k, c.finish_deg);
  k += tlvHead(b + k, T_TEMPO, 8);        k += f32(b + k, c.tempo_min); k += f32(b + k, c.tempo_max);
  k += tlvHead(b + k, T_COMP_THRESH, 12); k += f32(b + k, c.shoulder_deg); k += f32(b + k, c.trunk_deg);
                                          k += f32(b + k, c.swing_dps);
  k += tlvHead(b + k, T_DEDUCTIONS, 12);  k += f32(b + k, c.ded_shoulder); k += f32(b + k, c.ded_trunk);
                                          k += f32(b + k, c.ded_swing);
  k += tlvHead(b + k, T_RAW_STREAM, 1);   k += u8(b + k, c.raw_stream);
  if (k > cap) return 0;
  memcpy(o, b, k);
  return k;
}

int config_parse(const uint8_t *t, size_t len, Config &out) {
  Config c = out;
  int applied = 0;
  size_t i = 0;
  while (i + 2 <= len) {
    uint8_t tag = t[i], n = t[i + 1];
    if (i + 2 + n > len) return -1;                 // truncated
    const uint8_t *v = t + i + 2;
    auto need = [&](uint8_t want) { return n == want; };
    switch (tag) {
      case T_REP_TARGET:   if (!need(1)) return -1; c.rep_target = v[0]; applied++; break;
      case T_SET_COUNT:    if (!need(1)) return -1; c.set_count = v[0]; applied++; break;
      case T_REST_SECONDS: if (!need(2)) return -1; c.rest_seconds = rd16(v); applied++; break;
      case T_TARGET_ANGLE: if (!need(4)) return -1; c.target_deg = rdf(v); applied++; break;
      case T_START_ANGLE:  if (!need(4)) return -1; c.start_deg = rdf(v); applied++; break;
      case T_FINISH_ANGLE: if (!need(4)) return -1; c.finish_deg = rdf(v); applied++; break;
      case T_TEMPO:        if (!need(8)) return -1; c.tempo_min = rdf(v); c.tempo_max = rdf(v + 4); applied++; break;
      case T_COMP_THRESH:  if (!need(12)) return -1; c.shoulder_deg = rdf(v); c.trunk_deg = rdf(v + 4);
                           c.swing_dps = rdf(v + 8); applied++; break;
      case T_DEDUCTIONS:   if (!need(12)) return -1; c.ded_shoulder = rdf(v); c.ded_trunk = rdf(v + 4);
                           c.ded_swing = rdf(v + 8); applied++; break;
      case T_RAW_STREAM:   if (!need(1)) return -1; c.raw_stream = v[0]; applied++; break;
      case T_HOLD_MS:      if (!need(2)) return -1; break;   // known, no holds in this firmware: accepted, ignored
      case T_HOLD_VEL:     if (!need(4)) return -1; break;
      case T_WEIGHTS:      if (!need(20)) return -1; break;
      case T_CHANNEL_ROLES:if (!need(2)) return -1; break;
      default: break;                                  // unknown: skipped
    }
    i += 2 + n;
  }
  out = c;
  return applied;
}

}  // namespace wire
