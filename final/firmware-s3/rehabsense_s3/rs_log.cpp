#include "rs_log.h"
#include "ble.h"

TeeLog Log;

size_t TeeLog::write(uint8_t c) {
  Serial.write(c);
  if (c == '\r') return 1;
  if (c == '\n' || len >= sizeof(line) - 2) {     // a whole line (or a very long one): send it
    if (len) { line[len++] = '\n'; ble_text_line(line, len); }
    len = 0;
    return 1;
  }
  line[len++] = (char)c;
  return 1;
}

size_t TeeLog::write(const uint8_t *buf, size_t n) {
  for (size_t i = 0; i < n; i++) write(buf[i]);
  return n;
}
