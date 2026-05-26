#!/usr/bin/env bash
# protocols/quic/client.sh — QUIC client on vm1
#
# Usage: bash protocols/quic/client.sh [classical|pqc]
# Run from repo root after sourcing env.sh.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
QUIC_DIR="${REPO_ROOT}/protocols/quic"
source "${REPO_ROOT}/orchestrator/common.sh"

MODE="${1:-classical}"

check_ossl "protocols/quic/README.md"

if [[ ! -x "${QUIC_DIR}/client" ]]; then
    log ERROR "QUIC client binary not found: ${QUIC_DIR}/client"
    log ERROR "Build it first: make -C protocols/quic"
    exit 1
fi

resolve_vm_config quic
SERVER_IP="${VM2_IP:?VM2_IP not set. Source env.sh from repo root.}"
source "${REPO_ROOT}/protocols/quic/config.sh"

log INFO "Mode:               $MODE"
log INFO "Server address:     ${SERVER_IP}:${QUIC_PORT} (UDP)"
log INFO "Protocol:           QUIC / TLS 1.3"
log INFO "CA certificate:     $CAFILE"
log INFO "KEX groups:         $QUIC_GROUPS"
log INFO "Cipher suites:      $CIPHERS"
log INFO "Signature algs:     $SIGALGS"
echo ""

cd "${REPO_ROOT}"
exec "${QUIC_DIR}/client" "$MODE"
