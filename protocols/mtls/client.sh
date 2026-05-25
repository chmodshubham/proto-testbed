#!/usr/bin/env bash
# protocols/mtls/client.sh — mTLS 1.3 client on vm1
#
# Usage: ./protocols/mtls/client.sh [classical|pqc]
# Run from repo root.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "${REPO_ROOT}/orchestrator/common.sh"

MODE="${1:-classical}"
SERVER_IP="${VM2_IP:?VM2_IP not set. Source env.sh from repo root.}"

source "${REPO_ROOT}/protocols/mtls/config.sh"

log INFO "Mode:               $MODE"
log INFO "Server address:     ${SERVER_IP}:${MTLS_PORT}"
log INFO "Protocol:           TLS 1.3 (mutual)"
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
    -tls1_3 \
    -groups  "${MTLS_GROUPS}" \
    -ciphersuites "${CIPHERS}" \
    -sigalgs "${SIGALGS}" \
    -verify 2 \
    -keylogfile "/tmp/mtls-${MODE}.keys"
