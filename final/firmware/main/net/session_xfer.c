/*
 * session_xfer.c — SoftAP + HTTP server for the bulk session download
 *
 * Endpoints, all under the AP's gateway address:
 *
 *   GET /manifest.json     counts, sizes, scale factors, format version
 *   GET /emg.bin           rec_emg_t     × count
 *   GET /imu.bin           rec_imu_t     × count
 *   GET /features.bin      rec_feature_t × count
 *   GET /events.bin        rec_event_t   × count
 *   GET /reps.bin          rec_rep_t     × count
 *   GET /calib.bin         calib_record_t, the profile this session was scored against
 *   POST /complete         host confirms it has everything; the AP goes down
 *
 * The .bin endpoints honour Range, so a transfer that drops partway resumes
 * instead of restarting 4.5 MB of EMG. curl -C - works, which also means the
 * whole path can be exercised before any Python exists.
 *
 * Everything is served straight out of PSRAM in chunks. Nothing is copied to
 * flash and nothing is compressed: the session is already sitting in memory in
 * the exact layout the host wants, and an S3 doing gzip would be slower than
 * the radio it was trying to spare.
 */

#include <string.h>
#include <stdio.h>
#include <inttypes.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "esp_check.h"
#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_mac.h"
#include "esp_random.h"
#include "esp_http_server.h"
#include "nvs_flash.h"

#include "session_xfer.h"
#include "session_buffer.h"
#include "session_format.h"
#include "calibration.h"
#include "rehab_config.h"
#include "state_machine.h"

static const char *TAG = "xfer";

static httpd_handle_t  s_httpd;
static esp_netif_t    *s_netif;
static xfer_status_t   s_st;
static bool            s_wifi_inited;
static uint32_t        s_idle_ticks;

/* Chunk size for streaming out of PSRAM. 8 kB is large enough that the
 * per-chunk overhead disappears and small enough to sit in internal SRAM
 * without competing with the session itself. */
#define XFER_CHUNK_BYTES   8192
static uint8_t *s_chunk;

/* ── Identity ────────────────────────────────────────────────────────────
 *
 * SSID carries the last three bytes of the MAC so two sleeves in the same room
 * are distinguishable. The password is derived once per boot rather than
 * hard-coded: a fixed password printed in a repository is not a password, and
 * the host learns this one over the already-connected BLE link, which is the
 * one channel that is known to be in the right pair of hands.
 * ──────────────────────────────────────────────────────────────────────── */

static void derive_identity(void)
{
    uint8_t mac[6] = { 0 };
    esp_read_mac(mac, ESP_MAC_WIFI_SOFTAP);
    snprintf(s_st.ssid, sizeof(s_st.ssid), "%s-%02X%02X%02X",
             XFER_SSID_PREFIX, mac[3], mac[4], mac[5]);

    static const char alphabet[] = "abcdefghijkmnpqrstuvwxyz23456789";
    for (int i = 0; i < XFER_PASSWORD_LEN; i++) {
        s_st.password[i] = alphabet[esp_random() % (sizeof(alphabet) - 1)];
    }
    s_st.password[XFER_PASSWORD_LEN] = '\0';
}

/* ── Wi-Fi events ────────────────────────────────────────────────────── */

static void on_wifi_event(void *arg, esp_event_base_t base,
                          int32_t id, void *data)
{
    if (base != WIFI_EVENT) {
        return;
    }
    if (id == WIFI_EVENT_AP_STACONNECTED) {
        s_st.clients++;
        s_idle_ticks = 0;
        ESP_LOGI(TAG, "station joined (%u connected)", s_st.clients);
    } else if (id == WIFI_EVENT_AP_STADISCONNECTED) {
        if (s_st.clients) s_st.clients--;
        ESP_LOGI(TAG, "station left (%u connected)", s_st.clients);
    }
}

/* ── Stream serving ──────────────────────────────────────────────────── */

/* Parse a single "bytes=A-" or "bytes=A-B" range. Returns false when there is
 * no usable Range header, which the caller treats as "send the whole thing"
 * rather than as an error. Multi-range requests are not supported and are
 * answered in full; no client that matters issues them for a flat binary. */
static bool parse_range(httpd_req_t *req, size_t total,
                        size_t *out_start, size_t *out_len)
{
    char hdr[64];
    if (httpd_req_get_hdr_value_str(req, "Range", hdr, sizeof(hdr)) != ESP_OK) {
        return false;
    }

    size_t start = 0, end = 0;
    if (sscanf(hdr, "bytes=%zu-%zu", &start, &end) == 2) {
        if (end >= total) end = total ? total - 1 : 0;
    } else if (sscanf(hdr, "bytes=%zu-", &start) == 1) {
        end = total ? total - 1 : 0;
    } else {
        return false;
    }

    if (start >= total || end < start) {
        return false;
    }
    *out_start = start;
    *out_len   = end - start + 1;
    return true;
}

static esp_err_t serve_stream(httpd_req_t *req, session_stream_t stream)
{
    session_manifest_t man;
    session_buffer_manifest(&man);

    if (!man.sealed) {
        /* Refusing rather than serving a moving target. A file whose counts
         * changed while it was being read is internally inconsistent in ways
         * that surface much later, during analysis, as unexplained misalignment
         * between streams. */
        httpd_resp_set_status(req, "409 Conflict");
        httpd_resp_sendstr(req, "session still running");
        return ESP_OK;
    }

    const size_t rec   = session_stream_record_size(stream);
    const size_t first = man.first[stream];
    const size_t count = man.count[stream] - first;
    const size_t total = count * rec;

    size_t start = 0, len = total;
    const bool ranged = parse_range(req, total, &start, &len);

    httpd_resp_set_type(req, "application/octet-stream");
    httpd_resp_set_hdr(req, "Accept-Ranges", "bytes");

    char cr[96];
    if (ranged) {
        httpd_resp_set_status(req, "206 Partial Content");
        snprintf(cr, sizeof(cr), "bytes %zu-%zu/%zu",
                 start, start + len - 1, total);
        httpd_resp_set_hdr(req, "Content-Range", cr);
    }

    /* Range is a byte offset; the ring is addressed in records. Serving from a
     * record boundary and discarding the leading bytes keeps the reader simple
     * and costs at most one record per resumed transfer. */
    size_t sent = 0;
    while (sent < len) {
        const size_t byte_off   = start + sent;
        const size_t rec_index  = first + byte_off / rec;
        const size_t rec_skip   = byte_off % rec;

        size_t want_recs = (len - sent + rec_skip + rec - 1) / rec;
        if (want_recs > XFER_CHUNK_BYTES / rec) {
            want_recs = XFER_CHUNK_BYTES / rec;
        }
        if (want_recs == 0) {
            break;
        }

        const size_t got = session_buffer_read_stream(stream, rec_index,
                                                      s_chunk, want_recs);
        if (got == 0) {
            break;
        }

        size_t avail = got * rec - rec_skip;
        if (avail > len - sent) {
            avail = len - sent;
        }

        if (httpd_resp_send_chunk(req, (const char *)(s_chunk + rec_skip),
                                  avail) != ESP_OK) {
            ESP_LOGW(TAG, "client dropped %zu bytes in", sent);
            return ESP_FAIL;       /* connection closed; no terminating chunk */
        }

        sent += avail;
        s_st.bytes_served += (uint32_t)avail;
        s_idle_ticks = 0;
    }

    httpd_resp_send_chunk(req, NULL, 0);
    return ESP_OK;
}

static esp_err_t h_emg(httpd_req_t *r)      { return serve_stream(r, SESSION_STREAM_EMG); }
static esp_err_t h_imu(httpd_req_t *r)      { return serve_stream(r, SESSION_STREAM_IMU); }
static esp_err_t h_features(httpd_req_t *r) { return serve_stream(r, SESSION_STREAM_FEATURES); }
static esp_err_t h_events(httpd_req_t *r)   { return serve_stream(r, SESSION_STREAM_EVENTS); }
static esp_err_t h_reps(httpd_req_t *r)     { return serve_stream(r, SESSION_STREAM_REPS); }

static esp_err_t h_calib(httpd_req_t *req)
{
    calib_record_t rec;
    if (calibration_load_nvs(&rec) != ESP_OK) {
        httpd_resp_set_status(req, "404 Not Found");
        httpd_resp_sendstr(req, "no calibration profile stored");
        return ESP_OK;
    }
    httpd_resp_set_type(req, "application/octet-stream");
    httpd_resp_send(req, (const char *)&rec, sizeof(rec));
    s_idle_ticks = 0;
    return ESP_OK;
}

/* ── Manifest ────────────────────────────────────────────────────────────
 *
 * JSON rather than a packed struct, because this is the one thing a human
 * reads when something is wrong, and because it carries the scale factors —
 * a host one version behind can still parse the binaries correctly instead of
 * silently mis-scaling every value in them.
 * ──────────────────────────────────────────────────────────────────────── */

static esp_err_t h_manifest(httpd_req_t *req)
{
    session_manifest_t m;
    session_buffer_manifest(&m);

    char body[1280];
    const int n = snprintf(body, sizeof(body),
        "{\n"
        "  \"format_version\": %d,\n"
        "  \"sealed\": %s,\n"
        "  \"gap_occurred\": %s,\n"
        "  \"psram_backed\": %s,\n"
        "  \"start_us\": %" PRIu64 ",\n"
        "  \"end_us\": %" PRIu64 ",\n"
        "  \"emg_sample_rate_hz\": %d,\n"
        "  \"imu_sample_rate_hz\": %d,\n"
        "  \"feature_rate_hz\": %d,\n"
        "  \"emg_channels\": %d,\n"
        "  \"scales\": {\n"
        "    \"envelope\": %.1f, \"mdf\": %.1f, \"angle\": %.1f,\n"
        "    \"accel\": %.1f, \"gyro\": %.1f, \"fraction\": %.1f,\n"
        "    \"seconds\": %.1f\n"
        "  },\n"
        "  \"streams\": {\n"
        "    \"emg\":      { \"path\": \"/emg.bin\",      \"record_bytes\": %u, \"count\": %" PRIu32 ", \"first\": %" PRIu32 " },\n"
        "    \"imu\":      { \"path\": \"/imu.bin\",      \"record_bytes\": %u, \"count\": %" PRIu32 ", \"first\": %" PRIu32 " },\n"
        "    \"features\": { \"path\": \"/features.bin\", \"record_bytes\": %u, \"count\": %" PRIu32 ", \"first\": %" PRIu32 " },\n"
        "    \"events\":   { \"path\": \"/events.bin\",   \"record_bytes\": %u, \"count\": %" PRIu32 ", \"first\": %" PRIu32 " },\n"
        "    \"reps\":     { \"path\": \"/reps.bin\",     \"record_bytes\": %u, \"count\": %" PRIu32 ", \"first\": %" PRIu32 " }\n"
        "  }\n"
        "}\n",
        SESSION_FORMAT_VERSION,
        m.sealed ? "true" : "false",
        m.gap_occurred ? "true" : "false",
        m.psram_backed ? "true" : "false",
        m.start_us, m.end_us,
        EMG_SAMPLE_RATE_HZ, IMU_SAMPLE_RATE_HZ, FEATURE_RATE_HZ,
        EMG_N_CHANNELS,
        SCALE_ENVELOPE, SCALE_MDF, SCALE_ANGLE,
        SCALE_ACCEL, SCALE_GYRO, SCALE_FRACTION, SCALE_SECONDS,
        (unsigned)session_stream_record_size(SESSION_STREAM_EMG),
        m.count[SESSION_STREAM_EMG],      m.first[SESSION_STREAM_EMG],
        (unsigned)session_stream_record_size(SESSION_STREAM_IMU),
        m.count[SESSION_STREAM_IMU],      m.first[SESSION_STREAM_IMU],
        (unsigned)session_stream_record_size(SESSION_STREAM_FEATURES),
        m.count[SESSION_STREAM_FEATURES], m.first[SESSION_STREAM_FEATURES],
        (unsigned)session_stream_record_size(SESSION_STREAM_EVENTS),
        m.count[SESSION_STREAM_EVENTS],   m.first[SESSION_STREAM_EVENTS],
        (unsigned)session_stream_record_size(SESSION_STREAM_REPS),
        m.count[SESSION_STREAM_REPS],     m.first[SESSION_STREAM_REPS]);

    httpd_resp_set_type(req, "application/json");
    httpd_resp_send(req, body, n > 0 ? n : 0);
    s_idle_ticks = 0;
    return ESP_OK;
}

/* The host says it has everything. Nothing is freed here — the session stays
 * in PSRAM until the next START overwrites it, so a host that finds a problem
 * with its copy can come back and fetch again. */
static esp_err_t h_complete(httpd_req_t *req)
{
    ESP_LOGI(TAG, "host reports transfer complete (%" PRIu32 " bytes served)",
             s_st.bytes_served);
    s_st.state = XFER_COMPLETE;
    httpd_resp_sendstr(req, "ok");
    return ESP_OK;
}

static const httpd_uri_t s_routes[] = {
    { .uri = "/manifest.json", .method = HTTP_GET,  .handler = h_manifest },
    { .uri = "/emg.bin",       .method = HTTP_GET,  .handler = h_emg      },
    { .uri = "/imu.bin",       .method = HTTP_GET,  .handler = h_imu      },
    { .uri = "/features.bin",  .method = HTTP_GET,  .handler = h_features },
    { .uri = "/events.bin",    .method = HTTP_GET,  .handler = h_events   },
    { .uri = "/reps.bin",      .method = HTTP_GET,  .handler = h_reps     },
    { .uri = "/calib.bin",     .method = HTTP_GET,  .handler = h_calib    },
    { .uri = "/complete",      .method = HTTP_POST, .handler = h_complete },
};

/* ── Lifecycle ───────────────────────────────────────────────────────── */

esp_err_t session_xfer_init(void)
{
    /* The netif and event loop are set up once; the radio itself stays down.
     * esp_wifi_init() allocates its static buffers here rather than at the
     * moment a transfer is wanted, so a start cannot fail for memory after a
     * session has already been recorded — which would be the worst possible
     * time to find out. */
    ESP_RETURN_ON_ERROR(esp_netif_init(), TAG, "netif init");

    const esp_err_t le = esp_event_loop_create_default();
    if (le != ESP_OK && le != ESP_ERR_INVALID_STATE) {
        ESP_RETURN_ON_ERROR(le, TAG, "event loop");
    }

    s_netif = esp_netif_create_default_wifi_ap();
    ESP_RETURN_ON_FALSE(s_netif, ESP_FAIL, TAG, "ap netif");

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_RETURN_ON_ERROR(esp_wifi_init(&cfg), TAG, "wifi init");

    ESP_RETURN_ON_ERROR(
        esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID,
                                            on_wifi_event, NULL, NULL),
        TAG, "event handler");

    /* Buffers in internal SRAM, not PSRAM: PSRAM holds the session being
     * transferred and the two must not compete. */
    ESP_RETURN_ON_ERROR(esp_wifi_set_storage(WIFI_STORAGE_RAM), TAG, "storage");

    s_chunk = malloc(XFER_CHUNK_BYTES);
    ESP_RETURN_ON_FALSE(s_chunk, ESP_ERR_NO_MEM, TAG, "chunk buffer");

    derive_identity();
    s_st.state = XFER_IDLE;

    ESP_LOGI(TAG, "ready; AP stays down until a transfer is requested");
    return ESP_OK;
}

esp_err_t session_xfer_start(void)
{
    if (s_st.state == XFER_READY || s_st.state == XFER_STARTING) {
        return ESP_OK;                      /* already up */
    }

    if (sm_state() == FW_STATE_OPERATIONAL) {
        ESP_LOGW(TAG, "refused: a set is still running");
        return ESP_ERR_INVALID_STATE;
    }

    session_manifest_t m;
    session_buffer_manifest(&m);
    if (!m.sealed || m.count[SESSION_STREAM_EMG] == 0) {
        ESP_LOGW(TAG, "refused: no sealed session to serve");
        return ESP_ERR_INVALID_STATE;
    }

    s_st.state        = XFER_STARTING;
    s_st.bytes_served = 0;
    s_st.clients      = 0;
    s_idle_ticks      = 0;

    /* A fresh password per transfer, not per boot: the credential is only
     * meaningful for the window it is live, and it reaches the host over the
     * BLE link that is already paired. */
    derive_identity();

    wifi_config_t wc = { 0 };
    strncpy((char *)wc.ap.ssid, s_st.ssid, sizeof(wc.ap.ssid) - 1);
    strncpy((char *)wc.ap.password, s_st.password, sizeof(wc.ap.password) - 1);
    wc.ap.ssid_len       = strlen(s_st.ssid);
    wc.ap.channel        = XFER_AP_CHANNEL;
    wc.ap.max_connection = 1;         /* one physician laptop, not a hotspot */
    wc.ap.authmode       = WIFI_AUTH_WPA2_PSK;
    wc.ap.pmf_cfg.required = false;

    ESP_RETURN_ON_ERROR(esp_wifi_set_mode(WIFI_MODE_AP), TAG, "ap mode");
    ESP_RETURN_ON_ERROR(esp_wifi_set_config(WIFI_IF_AP, &wc), TAG, "ap config");
    ESP_RETURN_ON_ERROR(esp_wifi_start(), TAG, "wifi start");

    esp_netif_ip_info_t ip;
    if (esp_netif_get_ip_info(s_netif, &ip) == ESP_OK) {
        s_st.ipv4 = ip.ip.addr;
    }

    httpd_config_t hc = HTTPD_DEFAULT_CONFIG();
    hc.server_port      = XFER_HTTP_PORT;
    hc.max_uri_handlers = sizeof(s_routes) / sizeof(s_routes[0]) + 2;
    hc.lru_purge_enable = true;
    /* Core 0, with the rest of the comms work. Acquisition owns core 1 and a
     * transfer must not be able to perturb it even though no session is
     * running during one. */
    hc.core_id          = CORE_COMMS;
    hc.stack_size       = 8192;

    ESP_RETURN_ON_ERROR(httpd_start(&s_httpd, &hc), TAG, "httpd");
    for (size_t i = 0; i < sizeof(s_routes) / sizeof(s_routes[0]); i++) {
        ESP_RETURN_ON_ERROR(httpd_register_uri_handler(s_httpd, &s_routes[i]),
                            TAG, "route %s", s_routes[i].uri);
    }

    s_st.state = XFER_READY;
    ESP_LOGI(TAG, "AP \"%s\" up on " IPSTR ":%d — %u kB to serve",
             s_st.ssid, IP2STR(&ip.ip), XFER_HTTP_PORT,
             (unsigned)((m.count[SESSION_STREAM_EMG] *
                         session_stream_record_size(SESSION_STREAM_EMG)) / 1024));
    return ESP_OK;
}

void session_xfer_stop(void)
{
    if (s_httpd) {
        httpd_stop(s_httpd);
        s_httpd = NULL;
    }
    if (s_st.state != XFER_IDLE) {
        esp_wifi_stop();
        /* Leave the password in place so the status characteristic can still
         * report what the last transfer used; clearing it would make a failed
         * transfer impossible to retry without a new session. */
        ESP_LOGI(TAG, "AP down after %" PRIu32 " bytes", s_st.bytes_served);
    }
    s_st.clients = 0;
    s_st.state   = XFER_IDLE;
}

void session_xfer_status(xfer_status_t *out)
{
    *out = s_st;
    out->seconds_remaining = (s_st.state == XFER_READY &&
                              XFER_IDLE_TIMEOUT_S > s_idle_ticks)
                           ? (uint16_t)(XFER_IDLE_TIMEOUT_S - s_idle_ticks) : 0;
}

void session_xfer_tick(void)
{
    if (s_st.state == XFER_COMPLETE) {
        /* The host has what it came for. Drop the radio rather than waiting
         * out the timeout — on battery, an idle AP is pure cost. */
        session_xfer_stop();
        return;
    }

    if (s_st.state != XFER_READY) {
        return;
    }

    /* Only count idle time when nobody is associated. A slow download over a
     * poor link is not idleness, and timing out mid-transfer would be the
     * worst moment to drop the radio. */
    if (s_st.clients == 0) {
        if (++s_idle_ticks >= XFER_IDLE_TIMEOUT_S) {
            ESP_LOGW(TAG, "no client joined within %d s — AP down",
                     XFER_IDLE_TIMEOUT_S);
            session_xfer_stop();
        }
    } else {
        s_idle_ticks = 0;
    }
}
