#!/usr/bin/env bash
# Host-side tests. No ESP-IDF needed — these compile the real firmware
# sources against small stubs for esp_err.h and esp_log.h.
#
#   ./run_tests.sh          everything
#   ./run_tests.sh rep      just the repetition state machine
#   ./run_tests.sh dsp      just the filter / median-frequency checks
#
# On Windows run this from Git Bash, or paste the gcc line below into cmd.

set -e
cd "$(dirname "$0")"

FW=../main
CFLAGS="-std=c11 -Wall -Wextra -Wno-unused-parameter -Wno-unused-variable
        -DTEST_QUIET -I stubs -I $FW -I $FW/rep -I $FW/imu -I $FW/emg"

run_rep() {
    echo "=== repetition state machine ==="
    gcc $CFLAGS test_rep.c "$FW/rep/rep_cycle.c" "$FW/rep/grading.c" -lm -o test_rep
    ./test_rep
}

run_dsp() {
    echo
    echo "=== filter chain and median frequency ==="
    python3 verify_dsp.py
}

case "${1:-all}" in
    rep) run_rep ;;
    dsp) run_dsp ;;
    *)   run_rep; run_dsp ;;
esac
