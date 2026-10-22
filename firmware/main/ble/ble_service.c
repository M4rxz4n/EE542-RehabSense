/*
 * ble_service.c — NimBLE GATT server
 *
 * The device is authoritative for repetition counts, scores, compensation
 * flags and fatigue. The host displays them; it does not re-derive them from
 * the raw stream. If the two ever disagree that is a firmware bug to fix, not
 * a discrepancy to paper over in the UI.
 */

#include <string.h>
#include <inttypes.h>
#include "esp_log.h"
#include "esp_check.h"
#include "nvs_flash.h"

#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/ble_uuid.h"
#include "host/util/util.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

#include "ble_service.h"
#include "rehab_config.h"

static const char *TAG = "ble";

/* Base: A5B1xxxx-7C4E-4D9A-9E3F-1D2C3B4A5968 (little-endian byte order). */
#define REHAB_UUID(x16)                                                   \
    BLE_UUID128_INIT(0x68, 0x59, 0x4a, 0x5b, 0x3b, 0x2c, 0x1d, 0x9e,      \
                     0x9a, 0x4d, 0x4e, 0x7c,                              \
                     (uint8_t)((x16) & 0xff), (uint8_t)((x16) >> 8),      \
                     0xb1, 0xa5)

static const ble_uuid128_t UUID_SVC      = REHAB_UUID(0x0001);
static const ble_uuid128_t UUID_CONTROL  = REHAB_UUID(0x0002);
static const ble_uuid128_t UUID_RAW      = REHAB_UUID(0x0003);
static const ble_uuid128_t UUID_EVENTS   = REHAB_UUID(0x0004);
static const ble_uuid128_t UUID_STATUS   = REHAB_UUID(0x0005);
static const ble_uuid128_t UUID_BACKFILL = REHAB_UUID(0x0006);
static const ble_uuid128_t UUID_CALIB    = REHAB_UUID(0x0007);

static uint16_t s_conn   = BLE_HS_CONN_HANDLE_NONE;
static uint16_t s_h_raw, s_h_events, s_h_status, s_h_backfill;
static ble_command_cb_t s_on_command;
static device_status_t  s_status;
static calib_record_t   s_calib_mirror;
static uint8_t          s_own_addr_type;
static uint8_t          s_txbuf[BLE_FRAME_MAX_BYTES];

/* ── Characteristic access ───────────────────────────────────────────── */

static int gatt_access(uint16_t conn, uint16_t attr,
                       struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    const ble_uuid_t *uuid = ctxt->chr->uuid;

    if (ble_uuid_cmp(uuid, &UUID_CONTROL.u) == 0) {
        if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        uint8_t buf[64];
        uint16_t len = 0;
        if (ble_hs_mbuf_to_flat(ctxt->om, buf, sizeof(buf), &len) != 0 || len < 1) {
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }
        if (s_on_command) {
            s_on_command(buf[0], &buf[1], len - 1);
        }
        return 0;
    }

    if (ble_uuid_cmp(uuid, &UUID_STATUS.u) == 0) {
        if (ctxt->op != BLE_GATT_ACCESS_OP_READ_CHR) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        return os_mbuf_append(ctxt->om, &s_status, sizeof(s_status)) == 0
             ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
    }

    if (ble_uuid_cmp(uuid, &UUID_CALIB.u) == 0) {
        if (ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR) {
            return os_mbuf_append(ctxt->om, &s_calib_mirror,
                                  sizeof(s_calib_mirror)) == 0
                 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
        }
        if (ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR) {
            uint16_t len = 0;
            if (ble_hs_mbuf_to_flat(ctxt->om, &s_calib_mirror,
                                    sizeof(s_calib_mirror), &len) != 0 ||
                len != sizeof(s_calib_mirror)) {
                return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
            }
            if (s_on_command) {
                s_on_command(CMD_SET_CONFIG, (uint8_t *)&s_calib_mirror, len);
            }
            return 0;
        }
    }

    return BLE_ATT_ERR_UNLIKELY;
}

static const struct ble_gatt_svc_def s_svcs[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &UUID_SVC.u,
        .characteristics = (struct ble_gatt_chr_def[]) {
            { .uuid = &UUID_CONTROL.u,
              .access_cb = gatt_access,
              .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP },
            { .uuid = &UUID_RAW.u,
              .access_cb = gatt_access,
              .val_handle = &s_h_raw,
              .flags = BLE_GATT_CHR_F_NOTIFY },
            { .uuid = &UUID_EVENTS.u,
              .access_cb = gatt_access,
              .val_handle = &s_h_events,
              .flags = BLE_GATT_CHR_F_NOTIFY },
            { .uuid = &UUID_STATUS.u,
              .access_cb = gatt_access,
              .val_handle = &s_h_status,
              .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY },
            { .uuid = &UUID_BACKFILL.u,
              .access_cb = gatt_access,
              .val_handle = &s_h_backfill,
              .flags = BLE_GATT_CHR_F_NOTIFY },
            { .uuid = &UUID_CALIB.u,
              .access_cb = gatt_access,
              .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_WRITE },
            { 0 }
        },
    },
    { 0 }
};

/* ── GAP ─────────────────────────────────────────────────────────────── */

static int gap_event(struct ble_gap_event *event, void *arg)
{
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status == 0) {
            s_conn = event->connect.conn_handle;
            ESP_LOGI(TAG, "connected");

            /* Ask for the fast interval and the 2 Mbit PHY. A host that
             * grants only 30 ms is fine — tier 1 absorbs the difference. */
            struct ble_gap_upd_params p = {
                .itvl_min = BLE_CONN_ITVL_MIN_MS * 4 / 5,
                .itvl_max = BLE_CONN_ITVL_MAX_MS * 4 / 5,
                .latency  = 0,
                .supervision_timeout = BLE_CONN_TIMEOUT_MS / 10,
            };
            ble_gap_update_params(s_conn, &p);
            ble_gap_set_prefered_le_phy(s_conn, BLE_GAP_LE_PHY_2M_MASK,
                                        BLE_GAP_LE_PHY_2M_MASK, 0);
        } else {
            ble_service_start_advertising();
        }
        return 0;

    case BLE_GAP_EVENT_DISCONNECT:
        ESP_LOGW(TAG, "disconnected (reason %d) — acquisition continues",
                 event->disconnect.reason);
        s_conn = BLE_HS_CONN_HANDLE_NONE;
        ble_service_start_advertising();
        return 0;

    case BLE_GAP_EVENT_MTU:
        ESP_LOGI(TAG, "MTU %d", event->mtu.value);
        return 0;

    case BLE_GAP_EVENT_ADV_COMPLETE:
        ble_service_start_advertising();
        return 0;

    default:
        return 0;
    }
}

void ble_service_start_advertising(void)
{
    struct ble_hs_adv_fields fields = { 0 };
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.name = (uint8_t *)BLE_DEVICE_NAME;
    fields.name_len = strlen(BLE_DEVICE_NAME);
    fields.name_is_complete = 1;
    fields.tx_pwr_lvl_is_present = 1;
    fields.tx_pwr_lvl = BLE_HS_ADV_TX_PWR_LVL_AUTO;
    ble_gap_adv_set_fields(&fields);

    struct ble_gap_adv_params adv = {
        .conn_mode = BLE_GAP_CONN_MODE_UND,
        .disc_mode = BLE_GAP_DISC_MODE_GEN,
    };
    ble_gap_adv_start(s_own_addr_type, NULL, BLE_HS_FOREVER, &adv,
                      gap_event, NULL);
}

static void on_sync(void)
{
    ble_hs_util_ensure_addr(0);
    ble_hs_id_infer_auto(0, &s_own_addr_type);
    ble_service_start_advertising();
    ESP_LOGI(TAG, "advertising as \"%s\"", BLE_DEVICE_NAME);
}

static void host_task(void *arg)
{
    nimble_port_run();
    nimble_port_freertos_deinit();
}

esp_err_t ble_service_init(ble_command_cb_t on_command)
{
    s_on_command = on_command;

    ESP_RETURN_ON_ERROR(nimble_port_init(), TAG, "nimble init");

    ble_hs_cfg.sync_cb = on_sync;
    ble_hs_cfg.reset_cb = NULL;

    ble_svc_gap_init();
    ble_svc_gatt_init();

    ESP_RETURN_ON_ERROR(ble_gatts_count_cfg(s_svcs), TAG, "gatt count");
    ESP_RETURN_ON_ERROR(ble_gatts_add_svcs(s_svcs), TAG, "gatt add");
    ESP_RETURN_ON_ERROR(ble_svc_gap_device_name_set(BLE_DEVICE_NAME),
                        TAG, "device name");

    nimble_port_freertos_init(host_task);
    return ESP_OK;
}

bool ble_is_connected(void)
{
    return s_conn != BLE_HS_CONN_HANDLE_NONE;
}

/* ── Publishers ──────────────────────────────────────────────────────── */

static esp_err_t notify(uint16_t handle, const void *data, size_t len)
{
    if (s_conn == BLE_HS_CONN_HANDLE_NONE) {
        return ESP_ERR_INVALID_STATE;
    }
    struct os_mbuf *om = ble_hs_mbuf_from_flat(data, len);
    if (!om) {
        return ESP_ERR_NO_MEM;
    }
    return ble_gatts_notify_custom(s_conn, handle, om) == 0
         ? ESP_OK : ESP_FAIL;
}

static size_t put_header(uint8_t type, uint32_t seq, uint64_t t_us, uint8_t n)
{
    frame_header_t h = { .type = type, .seq = seq, .t_us = t_us, .n = n };
    memcpy(s_txbuf, &h, sizeof(h));
    return sizeof(h);
}

esp_err_t ble_notify_emg(const emg_frame_t *frames, size_t n, uint32_t seq)
{
    if (n > BLE_EMG_BATCH) n = BLE_EMG_BATCH;

    size_t off = put_header(FRAME_TYPE_EMG, seq,
                            n ? frames[0].t_us : 0, (uint8_t)n);

    for (size_t i = 0; i < n; i++) {
        for (int c = 0; c < EMG_N_CHANNELS; c++) {
            int32_t v = frames[i].ch[c];
            if (v >  32767) v =  32767;
            if (v < -32768) v = -32768;
            const int16_t s = (int16_t)v;
            memcpy(&s_txbuf[off], &s, sizeof(s));
            off += sizeof(s);
        }
    }
    return notify(s_h_raw, s_txbuf, off);
}

esp_err_t ble_notify_imu(const imu_sample_t *upper, const imu_sample_t *fore,
                         size_t n, uint32_t seq)
{
    if (n > BLE_IMU_BATCH) n = BLE_IMU_BATCH;

    size_t off = put_header(FRAME_TYPE_IMU, seq,
                            n ? upper[0].t_us : 0, (uint8_t)n);

    for (size_t i = 0; i < n; i++) {
        const imu_sample_t *src[2] = { &upper[i], &fore[i] };
        for (int d = 0; d < 2; d++) {
            for (int a = 0; a < 3; a++) {
                const int16_t acc = (int16_t)(src[d]->accel[a] * 1000.0f);
                memcpy(&s_txbuf[off], &acc, 2); off += 2;
            }
            for (int a = 0; a < 3; a++) {
                const int16_t gyr = (int16_t)(src[d]->gyro[a] * 10.0f);
                memcpy(&s_txbuf[off], &gyr, 2); off += 2;
            }
        }
    }
    return notify(s_h_raw, s_txbuf, off);
}

esp_err_t ble_notify_features(const features_t *f, uint32_t seq)
{
    size_t off = put_header(FRAME_TYPE_FEATURES, seq, f->t_us, 1);
    memcpy(&s_txbuf[off], f, sizeof(*f));
    off += sizeof(*f);
    return notify(s_h_events, s_txbuf, off);
}

esp_err_t ble_notify_event(const rehab_event_t *evt)
{
    size_t off = put_header(FRAME_TYPE_EVENT, 0, evt->t_us, 1);
    s_txbuf[off++] = evt->id;
    s_txbuf[off++] = evt->payload_len;
    if (evt->payload_len) {
        memcpy(&s_txbuf[off], evt->payload, evt->payload_len);
        off += evt->payload_len;
    }
    return notify(s_h_events, s_txbuf, off);
}

esp_err_t ble_notify_backfill(const emg_frame_t *frames, size_t n, uint32_t seq)
{
    if (n > BLE_EMG_BATCH) n = BLE_EMG_BATCH;

    size_t off = put_header(FRAME_TYPE_EMG, seq,
                            n ? frames[0].t_us : 0, (uint8_t)n);
    for (size_t i = 0; i < n; i++) {
        for (int c = 0; c < EMG_N_CHANNELS; c++) {
            const int16_t s = (int16_t)frames[i].ch[c];
            memcpy(&s_txbuf[off], &s, sizeof(s));
            off += sizeof(s);
        }
    }
    /* Served on its own characteristic at lower priority, so catching up
     * never stalls the live stream. */
    return notify(s_h_backfill, s_txbuf, off);
}

void ble_update_status(const device_status_t *status)
{
    s_status = *status;
    notify(s_h_status, &s_status, sizeof(s_status));
}
