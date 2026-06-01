#!/usr/bin/env bash
# protocols/mtls/server.sh — mTLS server on vm2 (TLS 1.2 for classical, TLS 1.3 for pqc)
#
# Usage: ./protocols/mtls/server.sh [classical|pqc]
# Run from repo root.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "${REPO_ROOT}/orchestrator/common.sh"

check_ossl "protocols/mtls/README.md"
resolve_vm_config mtls

MODE="${1:-classical}"
BIND_IP="${VM2_IP:?VM2_IP not set. Source env.sh from repo root.}"

source "${REPO_ROOT}/protocols/mtls/config.sh"

tls_flags "$MODE"
TLS_VER_LABEL="$( [[ "$MODE" == "classical" ]] && printf 'TLS 1.2 (mutual)' || printf 'TLS 1.3 (mutual)' )"

log INFO "Mode:               $MODE"
log INFO "Listening on:       ${BIND_IP}:${MTLS_PORT}"
log INFO "Protocol:           $TLS_VER_LABEL"
log INFO "Server certificate: ${SERVER_CERT}"
log INFO "Client CA:          ${CAFILE}"
log INFO "KEX groups:         $MTLS_GROUPS"
log INFO "Cipher suites:      $CIPHERS"
log INFO "Signature algs:     $SIGALGS"
printf '\n'

exec "$OSSL" s_server \
    -accept "${BIND_IP}:${MTLS_PORT}" \
    -cert   "${SERVER_CERT}" \
    -key    "${SERVER_KEY}" \
    -CAfile "${CAFILE}" \
    "$TLS_VER_FLAG" \
    -Verify 1 \
    -groups "${MTLS_GROUPS}" \
    "$CIPHER_FLAG" "${CIPHERS}" \
    -sigalgs "${SIGALGS}" \
    -WWW
