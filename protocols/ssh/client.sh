#!/usr/bin/env bash
# protocols/ssh/client.sh — SSH client on vm1
#
# Usage: ./protocols/ssh/client.sh [classical|pqc]
# Run from repo root on vm1.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "${REPO_ROOT}/orchestrator/common.sh"

MODE="${1:-classical}"
SERVER_IP="${VM2_IP:?VM2_IP not set. Source env.sh from repo root.}"

source "${REPO_ROOT}/protocols/ssh/config.sh"

log INFO "Mode:               $MODE"
log INFO "Server address:     ${SERVER_IP}:${SSH_PORT}"
log INFO "Client key:         ${SSH_CLIENT_KEY}"
log INFO "KEX algorithms:     ${SSH_KEX}"
echo ""

exec "$SSH_BIN" \
    -p "${SSH_PORT}" \
    -i "${SSH_CLIENT_KEY}" \
    -o KexAlgorithms="${SSH_KEX}" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes \
    -v \
    "${VM2_USER}@${SERVER_IP}" \
    exit
