// comms.h - Serial Monitor commands and Serial Plotter output.
// BLE joins this module on Sat 25 Oct, using the same commands.
#pragma once

void comms_begin();
void comms_poll();          // read and run any typed command
void comms_print_live();    // 20 Hz plotter line (if enabled)
void comms_help();

// Bluetooth: queue a command (e.g. "n", "t110") to run as if typed in the Serial Monitor
void comms_inject(const char *text);
int  comms_read_injected();   // next queued character, or -1 (used while calibration waits)
