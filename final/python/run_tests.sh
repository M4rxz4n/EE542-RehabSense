#!/usr/bin/env bash
# Host-side tests. No hardware, no radio, no broker — these run on a laptop
# with nothing plugged in, which is the point.
#
#   ./run_tests.sh              everything
#   ./run_tests.sh protocol     wire format only
#   ./run_tests.sh grading      the Python mirror of grading.c
#   ./run_tests.sh session      host against the simulated device
#
# On Windows run this from Git Bash, or run the python3 lines directly.
#
# bleak is not needed for any of this: rehab_client imports it lazily so the
# simulator path works without an adapter.

set -e
cd "$(dirname "$0")"

run_protocol() {
    echo "=== wire format ==="
    python3 test_protocol.py
}

run_grading() {
    echo
    echo "=== grading, against grading.c's behaviour ==="
    python3 test_grading.py
}

run_session() {
    echo
    echo "=== host against the simulated device ==="
    python3 test_sim_session.py
}

case "${1:-all}" in
    protocol) run_protocol ;;
    grading)  run_grading ;;
    session)  run_session ;;
    *)        run_protocol; run_grading; run_session ;;
esac
