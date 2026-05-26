#!/usr/bin/env bash
# protocols/mtls/client.sh — mTLS client on vm1 (TLS 1.2 for classical, TLS 1.3 for pqc)
#
# Usage: ./protocols/mtls/client.sh [classical|pqc]
# Run from repo root.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "${REPO_ROOT}/orchestrator/common.sh"
resolve_vm_config mtls

MODE="${1:-classical}"
SERVER_IP="${VM2_IP:?VM2_IP not set. Source env.sh from repo root.}"

source "${REPO_ROOT}/protocols/mtls/config.sh"

if [[ "$MODE" == "classical" ]]; then
    TLS_VER_FLAG="-tls1_2"
    CIPHER_FLAG="-cipher"
    TLS_VER_LABEL="TLS 1.2 (mutual)"
else
    TLS_VER_FLAG="-tls1_3"
    CIPHER_FLAG="-ciphersuites"
    TLS_VER_LABEL="TLS 1.3 (mutual)"
fi

log INFO "Mode:               $MODE"
log INFO "Server address:     ${SERVER_IP}:${MTLS_PORT}"
log INFO "Protocol:           $TLS_VER_LABEL"
log INFO "CA certificate:     $CAFILE"
log INFO "Client certificate: $CLIENT_CERT"
log INFO "KEX groups:         $MTLS_GROUPS"
log INFO "Cipher suites:      $CIPHERS"
log INFO "Signature algs:     $SIGALGS"
log INFO "Key log:            /tmp/mtls-${MODE}.keys"
echo ""

exec "$OSSL" s_client \
    -connect "${SERVER_IP}:${MTLS_PORT}" \
    -CAfile  "${CAFILE}" \
    -partial_chain \
    -cert    "${CLIENT_CERT}" \
    -key     "${CLIENT_KEY}" \
    "$TLS_VER_FLAG" \
    -groups  "${MTLS_GROUPS}" \
    "$CIPHER_FLAG" "${CIPHERS}" \
    -sigalgs "${SIGALGS}" \
    -verify 2 \
    -keylogfile "/tmp/mtls-${MODE}.keys"
