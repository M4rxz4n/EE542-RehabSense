/*
 * config.h — runtime configuration over BLE [PRD §5.9.1]
 *
 * "All parameters below are runtime-configurable over BLE, may be changed
 * during a session, take effect from the next repetition, and are stored in
 * NVS and read back for confirmation."
 *
 * The wire form is TLV — tag, length, value — rather than a packed struct, so
 * a newer host can talk to older firmware without the two having to agree on a
 * layout. An unrecognised tag is SKIPPED rather than rejecting the whole
 * block; a tag with the wrong length is rejected, because a length mismatch
 * means the two sides disagree about what the tag means.
 *
 * Tags are shared with the host client; keep in step with the table in
 * host/rehab_protocol.py.
 */

#ifndef REHAB_CONFIG_TLV_H
#define REHAB_CONFIG_TLV_H

#include "esp_err.h"
#include "rehab_types.h"

/* ── TLV tags ────────────────────────────────────────────────────────── */

#define CFG_TAG_HOLD_MS          0x01   /* uint16                        */
#define CFG_TAG_HOLD_VEL         0x02   /* float                         */
#define CFG_TAG_REP_TARGET       0x03   /* uint8                         */
#define CFG_TAG_SET_COUNT        0x04   /* uint8                         */
#define CFG_TAG_REST_SECONDS     0x05   /* uint16                        */
#define CFG_TAG_TARGET_ANGLE     0x06   /* float                         */
#define CFG_TAG_START_ANGLE      0x07   /* float                         */
#define CFG_TAG_FINISH_ANGLE     0x08   /* float                         */
#define CFG_TAG_TEMPO            0x09   /* float x2: min, max            */
#define CFG_TAG_COMP_THRESH      0x0A   /* float x3: shoulder,trunk,swing*/
#define CFG_TAG_WEIGHTS          0x0B   /* float x5: range,tempo,smooth, */
                                        /*           cocon, hold_steady  */
#define CFG_TAG_DEDUCTIONS       0x0C   /* float x3: shoulder,trunk,swing*/
#define CFG_TAG_RAW_STREAM       0x0D   /* uint8                         */
#define CFG_TAG_CHANNEL_ROLES    0x0E   /* uint8 x2: exercise, agonist   */

/* Largest serialised block: every tag present. */
#define CFG_TLV_MAX_BYTES        128

/* ── API ─────────────────────────────────────────────────────────────── */

/* Load from NVS, falling back to compile-time defaults. */
void config_init(void);

const rehab_runtime_cfg_t *config_get(void);

/* Apply a TLV block from the host. Values are validated and clamped to the
 * ranges in PRD §5.9.1 before being stored — a host that asks for a 10 ms hold
 * gets 300, not a device that cannot complete a repetition.
 *
 * Returns ESP_ERR_INVALID_SIZE if a recognised tag carried the wrong length.
 * Unrecognised tags are skipped and do not fail the block. On success the
 * result is persisted to NVS and pushed to every consumer. */
esp_err_t config_apply_tlv(const uint8_t *tlv, size_t len);

/* Serialise the configuration in force, for GET_CONFIG. This is how the host
 * confirms a write took effect. */
size_t config_serialise(uint8_t *out, size_t max);

/* Restore compile-time defaults and persist. */
void config_reset_defaults(void);

/* Push the current configuration into grading and the repetition cycle.
 * Called automatically by config_init and config_apply_tlv; exposed for the
 * state machine to call after a calibration change. */
void config_publish(void);

#endif /* REHAB_CONFIG_TLV_H */
