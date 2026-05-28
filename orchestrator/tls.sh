#!/usr/bin/env bash
# orchestrator/tls.sh — start TLS server on vm2, loop traffic from vm1 until killed
#
# Usage: ./orchestrator/tls.sh [classical|pqc]
# Set VM2_USER, VM2_HOST, VM2_REPO in env.sh and source it before running.
# Run from repo root on vm1.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${REPO_ROOT}/orchestrator/common.sh"

check_ossl "protocols/tls/README.md"
resolve_vm_config tls

MODE="${1:-classical}"

_STOP=0
cleanup() {
    _STOP=1
    ssh_vm2 "${VM2_USER}@${VM2_HOST}" \
        "pkill -f 's_server.*${TLS_PORT}' 2>/dev/null || true" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
SERVER_IP="${NLB_HOST:-${VM2_IP:?VM2_IP not set. Source env.sh from repo root.}}"

source "${REPO_ROOT}/protocols/tls/config.sh"
PROTO_TAG="tls/${MODE}"

if [[ "${TESTBED_NO_HEADER:-0}" != "1" ]]; then
    log INFO  "Mode:               $MODE"
    log INFO  "Server address:     ${SERVER_IP}:${TLS_PORT}"
    log INFO  "KEX groups:         $TLS_GROUPS"
    log INFO  "Cipher suites:      $CIPHERS"
    log INFO  "Signature algs:     $SIGALGS"
    log INFO  "CA certificate:     $CAFILE"
    printf '\r\n'
    log INFO  "Starting TLS server (${MODE}) on ${VM2_HOST} ..."
fi

ssh_vm2 "${VM2_USER}@${VM2_HOST}" bash <<EOF > /dev/null 2>&1
    pkill -f "s_server.*${TLS_PORT}" > /dev/null 2>&1 && sleep 0.2 || true
    cd ${VM2_REPO}
    source env.sh
    nohup bash protocols/tls/server.sh ${MODE} > /tmp/tls-server.log 2>&1 &
EOF

log_tty_state "after server start"
wait_tcp "${TLS_PORT}" "/tmp/tls-server.log"
check_vm1_reach "${TLS_PORT}" tls
log_tty_state "before traffic_header"
traffic_header

if [[ "$MODE" == "classical" ]]; then
    TLS_VER_FLAG="-tls1_2"
    CIPHER_FLAG="-cipher"
else
    TLS_VER_FLAG="-tls1_3"
    CIPHER_FLAG="-ciphersuites"
fi

set +m
COUNT=0
while [[ $_STOP -eq 0 ]]; do
    log_tty_state "loop top (#$((COUNT + 1)))"
    RESULT=$({ printf 'GET / HTTP/1.0\r\n\r\n'; sleep 2; } 2>/dev/null | \
        timeout 10 "$OSSL" s_client \
            -connect "${SERVER_IP}:${TLS_PORT}" \
            -CAfile  "$CAFILE" \
            -partial_chain \
            "$TLS_VER_FLAG" \
            -groups  "$TLS_GROUPS" \
            "$CIPHER_FLAG" "$CIPHERS" \
            -sigalgs "$SIGALGS" \
            -verify 2 \
            2>&1 || true)
    log_tty_state "after s_client"
    [[ $_STOP -eq 0 ]] || break
    COUNT=$((COUNT + 1))
    print_row "$RESULT" "$COUNT"
done
