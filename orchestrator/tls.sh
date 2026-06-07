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

# Stopping traffic must NOT stop the server: the trap only breaks the traffic
# loop. nginx stays up on vm2 until explicitly stopped (./nginx-server.sh stop).
_STOP=0
cleanup() { _STOP=1; }
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
if nginx_alive_vm2 tls "${MODE}"; then
    if [[ "${TESTBED_NO_HEADER:-0}" != "1" ]]; then
        log INFO "Reusing running TLS server (${MODE}) on ${VM2_HOST}."
    fi
else
    ssh_vm2 "${VM2_USER}@${VM2_HOST}" bash <<EOF > /dev/null 2>&1
        pidfile=/tmp/tls-nginx-${MODE}.pid
        if [[ -f "\$pidfile" ]]; then
            kill "\$(cat "\$pidfile")" 2>/dev/null || true
            sleep 0.2
        fi
        cd ${VM2_REPO}
        source env.sh
        nohup bash protocols/tls/server.sh ${MODE} > /tmp/tls-server-${MODE}.log 2>&1 &
EOF
fi

log_tty_state "after server start"
wait_tcp "${TLS_PORT}" "/tmp/tls-server-${MODE}.log"
check_vm1_reach "${TLS_PORT}" tls
check_backend tls
log_tty_state "before traffic_header"
traffic_header

tls_flags "$MODE"

set +m
COUNT=0
while [[ $_STOP -eq 0 ]]; do
    log_tty_state "loop top (#$((COUNT + 1)))"
    RESULT=$({ printf 'GET / HTTP/1.0\r\nHost: %s\r\n\r\n' "${SERVER_IP}"; sleep 2; } 2>/dev/null | \
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
