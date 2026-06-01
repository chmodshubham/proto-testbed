#!/usr/bin/env bash
# protocols/dtls/server.sh — DTLS 1.2 server on vm2
#
# Usage: ./protocols/dtls/server.sh classical
# Run from repo root. Builds the server binary if not present.

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
resolve_vm_config dtls

BIND_IP="${VM2_IP:?VM2_IP not set. Source env.sh from repo root.}"
source "${REPO_ROOT}/protocols/dtls/config.sh"

log INFO "Mode:               $MODE"
log INFO "Listening on:       ${BIND_IP}:${PORT_DTLS} (UDP)"
log INFO "Protocol:           DTLS 1.2"
log INFO "Certificate:        ${SERVER_CERT}"
log INFO "KEX groups:         $DTLS_GROUPS"
log INFO "Cipher suites:      $CIPHERS"
log INFO "Signature algs:     $SIGALGS"
log INFO "Library:            $("$OSSL" version | head -1 || true)"
echo ""

if [[ ! -x "${DTLS_DIR}/server" ]]; then
    make -C "${DTLS_DIR}" server
fi

cd "${REPO_ROOT}"
exec "${DTLS_DIR}/server" classical
