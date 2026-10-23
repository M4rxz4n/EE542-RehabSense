/*
 * session_buffer.h — tiered acquisition buffer with backfill
 *
 *   Tier 0  DMA landing buffers            (inside the ADC driver)
 *   Tier 1  live ring, internal SRAM, 8 s  — DSP windows and the BLE queue
 *   Tier 2  session store, PSRAM, 10 min   — survives a dropout
 *
 * The N8R8 module carries 8 MB of octal PSRAM, so tier 2 holds a full set with
 * room to spare and no realistic dropout loses anything.
 *
 * Losing the BLE link does not change the firmware state. Acquisition,
 * repetition detection and haptics all keep running; only transmission idles.
 */

#ifndef SESSION_BUFFER_H
#define SESSION_BUFFER_H

#include "esp_err.h"
#include "rehab_types.h"

typedef struct {
    uint32_t seq_oldest;      /* oldest sequence still retained */
    uint32_t seq_newest;      /* most recent written            */
    uint32_t seq_acked;       /* highest contiguous the host has */
    bool     psram_backed;    /* false means the degraded path is in use */
    bool     gap_occurred;    /* tier 2 wrapped and data was genuinely lost */
    size_t   capacity_samples;
} session_stats_t;

/* Allocates tier 2 in PSRAM. Returns ESP_ERR_NO_MEM if PSRAM is absent or
 * CONFIG_SPIRAM_MODE_OCT was left unset, which is the usual cause. */
esp_err_t session_buffer_init(void);

/* Reset for a new set. Sequence numbers restart at zero. */
void session_buffer_begin(void);
void session_buffer_end(void);

/* Append. Returns the sequence number assigned. */
uint32_t session_buffer_push_emg(const emg_frame_t *frames, size_t n);
uint32_t session_buffer_push_imu(const imu_sample_t *upper,
                                 const imu_sample_t *fore);

/* Host acknowledges the highest contiguous sequence it has. Storage below
 * this may be released. */
void session_buffer_ack(uint32_t seq);

/* Read back a range for backfill. Returns the number of frames copied, which
 * may be fewer than requested if the range has partly aged out. */
size_t session_buffer_read_emg(uint32_t from_seq, emg_frame_t *out, size_t max);

void session_buffer_stats(session_stats_t *out);

/* ── Backfill after a dropout [PRD §5.9] ─────────────────────────────────
 *
 * The host reads the retained range from the status characteristic, then asks
 * for what it missed. Requests are served BELOW the live stream in priority,
 * so catching up never stalls real-time data — the storage task does the work
 * one chunk at a time rather than blocking on the whole range.
 *
 * If part of the range has aged out, the device says so through the gap flag
 * rather than silently serving a short range as though it were complete.
 * ──────────────────────────────────────────────────────────────────────── */

/* Queue a replay. ESP_ERR_INVALID_ARG for a reversed range,
 * ESP_ERR_NOT_FOUND if none of it is still retained. */
esp_err_t session_buffer_request_backfill(uint32_t from_seq, uint32_t to_seq);

/* True while a request is outstanding. */
bool session_buffer_backfill_pending(void);

/* Send the next chunk. Returns true while more remain. Called from the
 * storage task, which runs below the transmit task. */
bool session_buffer_service_backfill(void);

#endif /* SESSION_BUFFER_H */
