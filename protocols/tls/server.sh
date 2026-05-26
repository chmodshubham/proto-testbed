#!/usr/bin/env bash
# protocols/tls/server.sh — TLS server on vm2 (TLS 1.2 for classical, TLS 1.3 for pqc)
#
# Usage: ./protocols/tls/server.sh [classical|pqc]
# Run from repo root.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "${REPO_ROOT}/orchestrator/common.sh"

check_ossl "protocols/tls/README.md"
resolve_vm_config tls

MODE="${1:-classical}"
BIND_IP="${VM2_IP:?VM2_IP not set. Source env.sh from repo root.}"

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
log INFO "Listening on:       ${BIND_IP}:${TLS_PORT}"
log INFO "Protocol:           $TLS_VER_LABEL"
log INFO "Certificate:        ${PKI}/tls/${MODE}/server-cert.pem"
log INFO "KEX groups:         $TLS_GROUPS"
log INFO "Cipher suites:      $CIPHERS"
log INFO "Signature algs:     $SIGALGS"
echo ""

exec "$OSSL" s_server \
    -accept "${BIND_IP}:${TLS_PORT}" \
    -cert   "${PKI}/tls/${MODE}/server-cert.pem" \
    -key    "${PKI}/tls/${MODE}/server-key.pem" \
    "$TLS_VER_FLAG" \
    -groups "$TLS_GROUPS" \
    "$CIPHER_FLAG" "$CIPHERS" \
    -sigalgs "$SIGALGS" \
    -WWW
