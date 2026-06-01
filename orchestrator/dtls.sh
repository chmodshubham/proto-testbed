#!/usr/bin/env bash
# orchestrator/dtls.sh — start DTLS server on vm2, loop traffic from vm1 until killed
#
# Usage: ./orchestrator/dtls.sh classical
# Set VM2_USER, VM2_HOST, VM2_REPO in env.sh and source it before running.
# Run from repo root on vm1.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${REPO_ROOT}/orchestrator/common.sh"

if [[ ! -x "${REPO_ROOT}/protocols/dtls/client" ]]; then
    log ERROR "DTLS client binary not found. Run: make -C protocols/dtls"
    exit 1
fi

resolve_vm_config dtls

MODE="${1:-classical}"

_STOP=0
cleanup() {
    _STOP=1
    ssh_vm2 "${VM2_USER}@${VM2_HOST}" \
        "pkill -f 'protocols/dtls/server ${MODE}' 2>/dev/null || true" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
SERVER_IP="${VM2_IP:?VM2_IP not set. Source env.sh from repo root.}"
SERVER_PORT="${PORT_DTLS:?PORT_DTLS not set. Source env.sh from repo root.}"

source "${REPO_ROOT}/protocols/dtls/config.sh"
PROTO_TAG="dtls/${MODE}"

if [[ "${TESTBED_NO_HEADER:-0}" != "1" ]]; then
    log INFO  "Mode:               $MODE"
    log INFO  "Server address:     ${SERVER_IP}:${SERVER_PORT} (UDP)"
    log INFO  "KEX groups:         $DTLS_GROUPS"
    log INFO  "Cipher suites:      $CIPHERS"
    log INFO  "Signature algs:     $SIGALGS"
    log INFO  "CA certificate:     $CAFILE"
    printf '\r\n'
    log INFO  "Starting DTLS server (${MODE}) on ${VM2_HOST} ..."
fi

ssh_vm2 "${VM2_USER}@${VM2_HOST}" bash <<EOF > /dev/null 2>&1
    pkill -f "protocols/dtls/server ${MODE}" > /dev/null 2>&1 && sleep 0.2 || true
    cd ${VM2_REPO}
    source env.sh
    nohup bash protocols/dtls/server.sh ${MODE} > /tmp/dtls-server.log 2>&1 &
EOF

wait_proc "protocols/dtls/server" "/tmp/dtls-server.log"
log_tty_state "before traffic_header"
traffic_header

set +m
COUNT=0
while [[ $_STOP -eq 0 ]]; do
    log_tty_state "loop top (#$((COUNT + 1)))"
    RESULT=$(timeout 10 "${REPO_ROOT}/protocols/dtls/client" "$MODE" 2>&1 || true) 2>/dev/null
    log_tty_state "after dtls client"
    [[ $_STOP -eq 0 ]] || break
    COUNT=$((COUNT + 1))
    print_row "$RESULT" "$COUNT"
    sleep 1
done
