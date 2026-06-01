#!/usr/bin/env bash
# protocols/quic/server.sh — QUIC server on vm2
#
# Usage: bash protocols/quic/server.sh [classical|pqc]
# Run from repo root after sourcing env.sh.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
QUIC_DIR="${REPO_ROOT}/protocols/quic"
source "${REPO_ROOT}/orchestrator/common.sh"

MODE="${1:-classical}"

check_ossl "protocols/quic/README.md"

if [[ ! -x "${QUIC_DIR}/server" ]]; then
    log ERROR "QUIC server binary not found: ${QUIC_DIR}/server"
    log ERROR "Build it first: make -C protocols/quic"
    exit 1
fi

resolve_vm_config quic
BIND_IP="${VM2_IP:?VM2_IP not set. Source env.sh from repo root.}"
source "${REPO_ROOT}/protocols/quic/config.sh"

log INFO "Mode:               $MODE"
log INFO "Listening on:       ${BIND_IP}:${QUIC_PORT} (UDP)"
log INFO "Protocol:           QUIC / TLS 1.3"
log INFO "Certificate:        ${SERVER_CERT}"
log INFO "KEX groups:         $QUIC_GROUPS"
log INFO "Cipher suites:      $CIPHERS"
log INFO "Signature algs:     $SIGALGS"
log INFO "Library (server):   $("$NGINX" -V 2>&1 | grep -oE 'nginx/[0-9.]+' || true) + BoringSSL $("$NGINX" -V 2>&1 | grep -oE 'boringssl-[0-9.]+' | grep -oE '[0-9.]+' || true)"
printf '\n'

cd "${REPO_ROOT}"
exec "${QUIC_DIR}/server" "$MODE"
