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
#include "session_format.h"

typedef struct {
    uint32_t seq_oldest;      /* oldest sequence still retained */
    uint32_t seq_newest;      /* most recent written            */
    uint32_t seq_acked;       /* highest contiguous the host has */
    bool     psram_backed;    /* false means the degraded path is in use */
    bool     gap_occurred;    /* tier 2 wrapped and data was genuinely lost */
    size_t   capacity_samples;
} session_stats_t;

/* ── The complete session record ─────────────────────────────────────────
 *
 * Tier 2 holds five streams, not two. Raw EMG and raw IMU are the measurement;
 * features, events and repetition results are the device's own calculations,
 * and the physician view wants both — recomputing the derived values on the
 * host would produce a second opinion that disagrees with what the patient
 * actually felt through the haptics.
 *
 * Every stream is a ring. If a session outruns its capacity the oldest records
 * are overwritten and the gap flag is raised, so a short file is never served
 * as though it were complete.
 * ──────────────────────────────────────────────────────────────────────── */

typedef enum {
    SESSION_STREAM_EMG = 0,
    SESSION_STREAM_IMU,
    SESSION_STREAM_FEATURES,
    SESSION_STREAM_EVENTS,
    SESSION_STREAM_REPS,
    SESSION_STREAM_COUNT
} session_stream_t;

/* What the bulk transfer serves. Counts are records, not bytes; the caller
 * multiplies by session_stream_record_size(). `first` is the index of the
 * oldest record still retained, which is non-zero only after a wrap. */
typedef struct {
    uint64_t start_us;              /* device monotonic at session start   */
    uint64_t end_us;                /* 0 while the session is still open   */
    uint32_t count[SESSION_STREAM_COUNT];
    uint32_t first[SESSION_STREAM_COUNT];
    bool     sealed;                /* session ended; safe to download     */
    bool     gap_occurred;
    bool     psram_backed;
} session_manifest_t;

/* Allocates tier 2 in PSRAM. Returns ESP_ERR_NO_MEM if PSRAM is absent or
 * CONFIG_SPIRAM_MODE_OCT was left unset, which is the usual cause. */
esp_err_t session_buffer_init(void);

/* Reset for a new set. Sequence numbers restart at zero. */
void session_buffer_begin(void);
void session_buffer_end(void);

/* Append. Returns the sequence number assigned.
 *
 * push_emg returns the index of the FIRST sample written, not the next free
 * one. The BLE transmit path labels its frames with this, so the sequence a
 * host acknowledges means the same thing to the ring as it does to the
 * stream — they used to be two independent counters that agreed only while
 * nothing dropped. */
uint32_t session_buffer_push_emg(const emg_frame_t *frames, size_t n);
uint32_t session_buffer_push_imu(const imu_sample_t *upper,
                                 const imu_sample_t *fore);

/* The device's own calculations, recorded alongside the raw measurement. */
void session_buffer_push_features(const features_t *f);
void session_buffer_push_event(const rehab_event_t *evt);
void session_buffer_push_rep(const rep_result_t *rep);

/* Host acknowledges the highest contiguous sequence it has. Storage below
 * this may be released. */
void session_buffer_ack(uint32_t seq);

/* Read back a range for backfill. Returns the number of frames copied, which
 * may be fewer than requested if the range has partly aged out. */
size_t session_buffer_read_emg(uint32_t from_seq, emg_frame_t *out, size_t max);

void session_buffer_stats(session_stats_t *out);

/* ── Bulk read, for the Wi-Fi transfer ───────────────────────────────────
 *
 * Generic over the five streams so the HTTP layer is one handler rather than
 * five near-identical ones. Copies `max_records` starting at `from_record`
 * into `out`, in the packed session_format.h layout, and returns how many it
 * actually copied — fewer at the end of a stream, or when the start has aged
 * out of the ring.
 *
 * Safe to call while a session is running, but the manifest reports
 * sealed=false and the host should wait: counts move under it otherwise.
 * ──────────────────────────────────────────────────────────────────────── */

size_t session_stream_record_size(session_stream_t stream);

size_t session_buffer_read_stream(session_stream_t stream,
                                  uint32_t from_record,
                                  void *out, size_t max_records);

void session_buffer_manifest(session_manifest_t *out);

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
