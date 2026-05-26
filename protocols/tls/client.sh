#!/usr/bin/env bash
# protocols/tls/client.sh — TLS client on vm1 (TLS 1.2 for classical, TLS 1.3 for pqc)
#
# Usage: ./protocols/tls/client.sh [classical|pqc]
# Run from repo root.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "${REPO_ROOT}/orchestrator/common.sh"
resolve_vm_config tls

MODE="${1:-classical}"
SERVER_IP="${VM2_IP:?VM2_IP not set. Source env.sh from repo root.}"

source "${REPO_ROOT}/protocols/tls/config.sh"

if [[ "$MODE" == "classical" ]]; then
    TLS_VER_FLAG="-tls1_2"
    CIPHER_FLAG="-cipher"
    TLS_VER_LABEL="TLS 1.2"
else
    TLS_VER_FLAG="-tls1_3"
    CIPHER_FLAG="-ciphersuites"
    TLS_VER_LABEL="TLS 1.3"
fi

log INFO "Mode:               $MODE"
log INFO "Server address:     ${SERVER_IP}:${TLS_PORT}"
log INFO "Protocol:           $TLS_VER_LABEL"
log INFO "CA certificate:     $CAFILE"
log INFO "KEX groups:         $TLS_GROUPS"
log INFO "Cipher suites:      $CIPHERS"
log INFO "Signature algs:     $SIGALGS"
log INFO "Key log:            /tmp/tls-${MODE}.keys"
echo ""

exec "$OSSL" s_client \
    -connect "${SERVER_IP}:${TLS_PORT}" \
    -CAfile  "$CAFILE" \
    -partial_chain \
    "$TLS_VER_FLAG" \
    -groups "$TLS_GROUPS" \
    "$CIPHER_FLAG" "$CIPHERS" \
    -sigalgs "$SIGALGS" \
    -verify 2 \
    -keylogfile "/tmp/tls-${MODE}.keys"
