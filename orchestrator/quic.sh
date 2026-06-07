#!/usr/bin/env bash
# orchestrator/quic.sh — start QUIC server on vm2, loop traffic from vm1 until killed
#
# Usage: ./orchestrator/quic.sh [classical|pqc]
# Set VM2_USER, VM2_HOST, VM2_REPO in env.sh and source it before running.
# Run from repo root on vm1.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${REPO_ROOT}/orchestrator/common.sh"

check_ossl "protocols/quic/README.md"

if [[ ! -x "${REPO_ROOT}/protocols/quic/client" ]]; then
    log ERROR "QUIC client binary not found. Run: make -C protocols/quic client"
    exit 1
fi

resolve_vm_config quic

MODE="${1:-classical}"
SERVER_IP="${NLB_HOST:-${VM2_IP:?VM2_IP not set. Source env.sh from repo root.}}"
# The C client uses inet_addr() and cannot resolve DNS names. Resolve here.
if [[ "$SERVER_IP" =~ [a-zA-Z] ]]; then
    SERVER_IP="$(getent hosts "$SERVER_IP" | awk '{print $1; exit}')"
    [[ -z "$SERVER_IP" ]] && { log ERROR "Failed to resolve NLB_HOST to an IP."; exit 1; }
fi
export VM2_IP="$SERVER_IP"

# Stopping traffic must NOT stop the server: the trap only breaks the traffic
# loop. nginx stays up on vm2 until explicitly stopped (./nginx-server.sh stop).
_STOP=0
cleanup() { _STOP=1; }
trap cleanup EXIT INT TERM

source "${REPO_ROOT}/protocols/quic/config.sh"
PROTO_TAG="quic/${MODE}"

if [[ "${TESTBED_NO_HEADER:-0}" != "1" ]]; then
    log INFO "Mode:               $MODE"
    log INFO "Server address:     ${SERVER_IP}:${QUIC_PORT} (UDP)"
    log INFO "KEX groups:         $QUIC_GROUPS"
    log INFO "Cipher suites:      $CIPHERS"
    log INFO "Signature algs:     $SIGALGS"
    log INFO "CA certificate:     $CAFILE"
    printf '\r\n'
    log INFO "Starting QUIC server (${MODE}) on ${VM2_HOST} ..."
fi
if nginx_alive_vm2 quic "${MODE}"; then
    if [[ "${TESTBED_NO_HEADER:-0}" != "1" ]]; then
        log INFO "Reusing running QUIC server (${MODE}) on ${VM2_HOST}."
    fi
else
    ssh_vm2 "${VM2_USER}@${VM2_HOST}" bash <<EOF > /dev/null 2>&1
        pidfile=/tmp/quic-nginx-${MODE}.pid
        if [[ -f "\$pidfile" ]]; then
            kill "\$(cat "\$pidfile")" 2>/dev/null || true
            sleep 0.2
        fi
        pkill -f 'nginx.*quic-nginx-${MODE}' 2>/dev/null || true
        cd ${VM2_REPO}
        source env.sh
        nohup bash protocols/quic/server.sh ${MODE} > /tmp/quic-server-${MODE}.log 2>&1 &
EOF
fi

wait_proc "quic-nginx-${MODE}" "/tmp/quic-server-${MODE}.log"
check_backend quic
log_tty_state "before traffic_header"
traffic_header

set +m
COUNT=0
while [[ $_STOP -eq 0 ]]; do
    log_tty_state "loop top (#$((COUNT + 1)))"
    RESULT=$(timeout 10 "${REPO_ROOT}/protocols/quic/client" "$MODE" 2>&1 || true) 2>/dev/null
    log_tty_state "after quic client"
    [[ $_STOP -eq 0 ]] || break
    COUNT=$((COUNT + 1))
    print_row "$RESULT" "$COUNT"
    sleep 1
done
