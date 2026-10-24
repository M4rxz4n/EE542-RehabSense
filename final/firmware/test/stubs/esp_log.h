#ifndef ESP_LOG_H_STUB
#define ESP_LOG_H_STUB
#include <stdio.h>
#ifdef TEST_QUIET
#define ESP_LOGI(tag, fmt, ...) do {} while (0)
#define ESP_LOGW(tag, fmt, ...) do {} while (0)
#define ESP_LOGE(tag, fmt, ...) do {} while (0)
#else
#define ESP_LOGI(tag, fmt, ...) printf("I %s: " fmt "\n", tag, ##__VA_ARGS__)
#define ESP_LOGW(tag, fmt, ...) printf("W %s: " fmt "\n", tag, ##__VA_ARGS__)
#define ESP_LOGE(tag, fmt, ...) printf("E %s: " fmt "\n", tag, ##__VA_ARGS__)
#endif
#endif
