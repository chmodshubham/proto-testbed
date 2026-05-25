#!/usr/bin/env bash
# protocols/tls/client.sh — TLS 1.3 client on vm1
#
# Usage: ./protocols/tls/client.sh [classical|pqc]
# Run from repo root.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "${REPO_ROOT}/orchestrator/common.sh"

MODE="${1:-classical}"
SERVER_IP="${VM2_IP:?VM2_IP not set. Source env.sh from repo root.}"

source "${REPO_ROOT}/protocols/tls/config.sh"

log INFO "Mode:               $MODE"
log INFO "Server address:     ${SERVER_IP}:${TLS_PORT}"
log INFO "Protocol:           TLS 1.3"
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
    -tls1_3 \
    -groups "$TLS_GROUPS" \
    -ciphersuites "$CIPHERS" \
    -sigalgs "$SIGALGS" \
    -verify 2 \
    -keylogfile "/tmp/tls-${MODE}.keys"
