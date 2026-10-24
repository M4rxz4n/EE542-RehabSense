/*
 * session_xfer.h — bulk session download over Wi-Fi SoftAP
 *
 * Why this exists
 * ---------------
 * BLE carries the live stream: feature frames at 50 Hz, events, status and
 * control. That is a few kB/s and it is what the patient-facing app renders
 * during a set.
 *
 * The physician's record is a different problem. A ten-minute session is about
 * 6.6 MB of raw EMG, raw IMU and derived records. Paced over BLE that is
 * roughly wall-clock realtime — ten minutes of exercise, ten minutes of
 * transfer — because the link tops out near 10 kB/s against a phone. Over
 * SoftAP the same payload moves in seconds.
 *
 * Sequential, never concurrent
 * ----------------------------
 * The S3 has one 2.4 GHz radio. Running Wi-Fi and a saturated BLE link at once
 * means software coexistence arbitrating between them, which costs throughput
 * on both and makes BLE miss connection events — the live stream is exactly
 * what must not degrade. So the AP comes up only once a session is sealed, and
 * goes down when the transfer finishes or times out. BLE stays connected
 * throughout, but by then it is carrying control traffic only, which is small
 * enough to coexist with.
 *
 * The device refuses to start a transfer while OPERATIONAL. That is not a
 * policy the host can override.
 *
 * No internet path
 * ----------------
 * SoftAP makes the sleeve its own network with no route anywhere. Whatever
 * joins it downloads the session and is responsible for onward delivery to a
 * clinic system. Station mode, where the sleeve joins an existing network and
 * uploads directly, needs credential provisioning and is deliberately not in
 * this revision.
 */

#ifndef SESSION_XFER_H
#define SESSION_XFER_H

#include "esp_err.h"
#include <stdbool.h>
#include <stdint.h>

typedef enum {
    XFER_IDLE = 0,        /* radio down, nothing offered            */
    XFER_STARTING,        /* bringing the AP and server up          */
    XFER_READY,           /* AP up, waiting for or serving a client */
    XFER_COMPLETE,        /* host confirmed it has the whole record */
    XFER_FAILED,
} xfer_state_t;

typedef struct {
    xfer_state_t state;
    char         ssid[33];
    char         password[65];
    uint32_t     ipv4;            /* AP address, network byte order */
    uint8_t      clients;         /* stations currently associated  */
    uint32_t     bytes_served;
    uint16_t     seconds_remaining; /* until the idle timeout fires */
} xfer_status_t;

/* Called once at boot. Does NOT bring the radio up: Wi-Fi stays initialised
 * but stopped until a transfer is asked for, so it costs nothing during a
 * session beyond its static allocations. */
esp_err_t session_xfer_init(void);

/* Bring up the AP and the HTTP server.
 *
 * ESP_ERR_INVALID_STATE if a session is still running or none has been
 * recorded — downloading a buffer whose counts are moving under the reader
 * produces a file that is internally inconsistent in ways that are very hard
 * to spot later. */
esp_err_t session_xfer_start(void);

/* Tear the AP down. Safe to call when already idle. */
void session_xfer_stop(void);

void session_xfer_status(xfer_status_t *out);

/* Driven by the housekeeping task once a second: enforces the idle timeout so
 * a forgotten transfer does not leave the radio up until the battery dies. */
void session_xfer_tick(void);

#endif /* SESSION_XFER_H */
