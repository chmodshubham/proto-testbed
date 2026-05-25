#!/usr/bin/env bash
# protocols/tls/server.sh — TLS 1.3 server on vm2
#
# Usage: ./protocols/tls/server.sh [classical|pqc]
# Run from repo root.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "${REPO_ROOT}/orchestrator/common.sh"

check_ossl "protocols/tls/README.md"

MODE="${1:-classical}"
BIND_IP="${VM2_IP:?VM2_IP not set. Source env.sh from repo root.}"

source "${REPO_ROOT}/protocols/tls/config.sh"

log INFO "Mode:               $MODE"
log INFO "Listening on:       ${BIND_IP}:${TLS_PORT}"
log INFO "Protocol:           TLS 1.3"
log INFO "Certificate:        ${PKI}/tls/${MODE}/server-cert.pem"
log INFO "KEX groups:         $TLS_GROUPS"
log INFO "Cipher suites:      $CIPHERS"
log INFO "Signature algs:     $SIGALGS"
echo ""

exec "$OSSL" s_server \
    -accept "${BIND_IP}:${TLS_PORT}" \
    -cert   "${PKI}/tls/${MODE}/server-cert.pem" \
    -key    "${PKI}/tls/${MODE}/server-key.pem" \
    -tls1_3 \
    -groups "$TLS_GROUPS" \
    -ciphersuites "$CIPHERS" \
    -sigalgs "$SIGALGS" \
    -WWW
