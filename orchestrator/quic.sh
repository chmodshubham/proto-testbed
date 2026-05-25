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
check_env

if [[ ! -x "${REPO_ROOT}/protocols/quic/client" ]]; then
    log ERROR "QUIC client binary not found. Run: make -C protocols/quic"
    exit 1
fi

MODE="${1:-classical}"
SERVER_IP="${VM2_IP:?VM2_IP not set. Source env.sh from repo root.}"

_STOP=0
cleanup() {
    _STOP=1
    stty echo 2>/dev/null || true
    ssh_vm2 "${VM2_USER}@${VM2_HOST}" \
        "pkill -f 'protocols/quic/server' 2>/dev/null || true" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

source "${REPO_ROOT}/protocols/quic/config.sh"
PROTO_TAG="quic/${MODE}"

log INFO "Mode:               $MODE"
log INFO "Server address:     ${SERVER_IP}:${QUIC_PORT} (UDP)"
log INFO "KEX groups:         $QUIC_GROUPS"
log INFO "Cipher suites:      $CIPHERS"
log INFO "Signature algs:     $SIGALGS"
log INFO "CA certificate:     $CAFILE"
echo ""
log INFO "Starting QUIC server (${MODE}) on ${VM2_HOST} ..."

ssh_vm2 "${VM2_USER}@${VM2_HOST}" bash <<EOF
    pkill -f "protocols/quic/server" > /dev/null 2>&1 && sleep 0.2 || true
    cd ${VM2_REPO}
    source env.sh
    nohup bash protocols/quic/server.sh ${MODE} > /tmp/quic-server-${MODE}.log 2>&1 &
EOF

for i in $(seq 1 20); do
    if ssh_vm2 "${VM2_USER}@${VM2_HOST}" \
        "grep -q 'Server is ready' /tmp/quic-server-${MODE}.log 2>/dev/null" 2>/dev/null; then
        log INFO "Server is ready and accepting connections."
        break
    fi
    [[ $i -eq 20 ]] && { log ERROR "Server failed to start within 10s. Check /tmp/quic-server-${MODE}.log on ${VM2_HOST}."; exit 1; }
    sleep 0.5
done
traffic_header

COUNT=0
while [[ $_STOP -eq 0 ]]; do
    RESULT=$(timeout 10 "${REPO_ROOT}/protocols/quic/client" "$MODE" 2>&1 || true)
    [[ $_STOP -eq 0 ]] || break
    COUNT=$((COUNT + 1))
    print_row "$RESULT" "$COUNT"
done
