/* Minimal NVS surface for the host test build. Not a functional store: the
 * handle-based calls are stubbed so calibration.c and config.c compile and
 * their logic can be exercised without ESP-IDF. */
#ifndef NVS_H_STUB
#define NVS_H_STUB
#include <stddef.h>
#include "esp_err.h"
typedef int nvs_handle_t;
#define NVS_READONLY  0
#define NVS_READWRITE 1
static inline esp_err_t nvs_open(const char *ns, int mode, nvs_handle_t *h)
    { (void)ns; (void)mode; if (h) *h = 0; return ESP_FAIL; }
static inline esp_err_t nvs_get_blob(nvs_handle_t h, const char *k, void *v, size_t *l)
    { (void)h; (void)k; (void)v; (void)l; return ESP_FAIL; }
static inline esp_err_t nvs_set_blob(nvs_handle_t h, const char *k, const void *v, size_t l)
    { (void)h; (void)k; (void)v; (void)l; return ESP_OK; }
static inline esp_err_t nvs_commit(nvs_handle_t h) { (void)h; return ESP_OK; }
static inline void nvs_close(nvs_handle_t h) { (void)h; }
#endif
