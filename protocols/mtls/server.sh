#!/usr/bin/env bash
# protocols/mtls/server.sh — mTLS 1.3 server on vm2
#
# Usage: ./protocols/mtls/server.sh [classical|pqc]
# Run from repo root.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "${REPO_ROOT}/orchestrator/common.sh"

check_ossl "protocols/mtls/README.md"

MODE="${1:-classical}"
BIND_IP="${VM2_IP:?VM2_IP not set. Source env.sh from repo root.}"

source "${REPO_ROOT}/protocols/mtls/config.sh"

log INFO "Mode:               $MODE"
log INFO "Listening on:       ${BIND_IP}:${MTLS_PORT}"
log INFO "Protocol:           TLS 1.3 (mutual)"
log INFO "Server certificate: ${SERVER_CERT}"
log INFO "Client CA:          ${CAFILE}"
log INFO "KEX groups:         $MTLS_GROUPS"
log INFO "Cipher suites:      $CIPHERS"
log INFO "Signature algs:     $SIGALGS"
echo ""

exec "$OSSL" s_server \
    -accept "${BIND_IP}:${MTLS_PORT}" \
    -cert   "${SERVER_CERT}" \
    -key    "${SERVER_KEY}" \
    -CAfile "${CAFILE}" \
    -tls1_3 \
    -Verify 1 \
    -groups "${MTLS_GROUPS}" \
    -ciphersuites "${CIPHERS}" \
    -sigalgs "${SIGALGS}" \
    -WWW
