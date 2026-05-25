#!/usr/bin/env bash
# protocols/ssh/server.sh — testbed sshd on vm2
#
# Usage: ./protocols/ssh/server.sh [classical|pqc]
# Run from repo root on vm2.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "${REPO_ROOT}/orchestrator/common.sh"

MODE="${1:-classical}"

source "${REPO_ROOT}/protocols/ssh/config.sh"

SSHD_CONFIG="/tmp/sshd-${MODE}.conf"

cat > "$SSHD_CONFIG" <<CONF
Port ${SSH_PORT}
ListenAddress 0.0.0.0
HostKey ${SSH_HOST_KEY}
AuthorizedKeysFile ${SSH_AUTHORIZED_KEYS}
KexAlgorithms ${SSH_KEX}
StrictModes no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
PerSourcePenalties no
PrintMotd no
LogLevel VERBOSE
PidFile /tmp/sshd-${MODE}.pid
CONF

log INFO "Mode:               $MODE"
log INFO "Listening on:       0.0.0.0:${SSH_PORT}"
log INFO "Host key:           ${SSH_HOST_KEY}"
log INFO "KEX algorithms:     ${SSH_KEX}"
echo ""

exec "$SSHD_BIN" -D -f "$SSHD_CONFIG" -e
