#!/usr/bin/env bash
# protocols/dtls/client.sh — DTLS 1.2 client on vm1
#
# Usage: ./protocols/dtls/client.sh classical
# Run from repo root. Builds the client binary if not present.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DTLS_DIR="${REPO_ROOT}/protocols/dtls"
source "${REPO_ROOT}/orchestrator/common.sh"

MODE="${1:-classical}"

if [[ "$MODE" != "classical" ]]; then
    log ERROR "DTLS 1.2 supports classical mode only. No PQC KEX available."
    exit 1
fi

check_ossl "protocols/dtls/README.md"

SERVER_IP="${VM2_IP:?VM2_IP not set. Source env.sh from repo root.}"
source "${REPO_ROOT}/protocols/dtls/config.sh"

log INFO "Mode:               $MODE"
log INFO "Server address:     ${SERVER_IP}:${PORT_DTLS} (UDP)"
log INFO "Protocol:           DTLS 1.2"
log INFO "CA certificate:     $CAFILE"
log INFO "KEX groups:         $DTLS_GROUPS"
log INFO "Cipher suites:      $CIPHERS"
log INFO "Signature algs:     $SIGALGS"
echo ""

if [[ ! -x "${DTLS_DIR}/client" ]]; then
    make -C "${DTLS_DIR}" client
fi

cd "${REPO_ROOT}"
exec "${DTLS_DIR}/client" classical
