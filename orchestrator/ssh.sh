#!/usr/bin/env bash
# orchestrator/ssh.sh — start sshd on vm2, loop SSH connections from vm1 until killed
#
# Usage: ./orchestrator/ssh.sh [classical|pqc]
# Set VM2_USER, VM2_HOST, VM2_REPO in env.sh and source it before running.
# Run from repo root on vm1. sshd on vm2 must run as root (sudo).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${REPO_ROOT}/orchestrator/common.sh"

check_openssh "protocols/ssh/README.md"
resolve_vm_config ssh

MODE="${1:-classical}"

source "${REPO_ROOT}/protocols/ssh/config.sh"
PROTO_TAG="ssh/${MODE}"

_STOP=0
cleanup() {
    _STOP=1
    ssh_vm2 "${VM2_USER}@${VM2_HOST}" \
        "sudo pkill -f 'sshd.*${SSH_PORT}' 2>/dev/null || true" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

if [[ "${TESTBED_NO_HEADER:-0}" != "1" ]]; then
    log INFO "Mode:               $MODE"
    log INFO "Server address:     ${VM2_IP}:${SSH_PORT}"
    log INFO "KEX algorithms:     ${SSH_KEX}"
    log INFO "Client key:         ${SSH_CLIENT_KEY}"
    printf '\r\n'
    log INFO "Syncing PKI to ${VM2_HOST} ..."
fi
ssh_vm2 "${VM2_USER}@${VM2_HOST}" "mkdir -p ${VM2_REPO}/pki/out/ssh/${MODE}"
rsync_vm2 -q \
    "${SSH_HOST_KEY}" \
    "${SSH_HOST_KEY}.pub" \
    "${SSH_CLIENT_KEY}.pub" \
    "${VM2_USER}@${VM2_HOST}:${VM2_REPO}/pki/out/ssh/${MODE}/"
ssh_vm2 "${VM2_USER}@${VM2_HOST}" bash <<EOF > /dev/null 2>&1
    chmod 600 ${VM2_REPO}/pki/out/ssh/${MODE}/host-key
    cp ${VM2_REPO}/pki/out/ssh/${MODE}/client-key.pub ${VM2_REPO}/pki/out/ssh/${MODE}/authorized_keys
EOF

if [[ "${TESTBED_NO_HEADER:-0}" != "1" ]]; then log INFO "Starting SSH server (${MODE}) on ${VM2_HOST} ..."; fi

ssh_vm2 "${VM2_USER}@${VM2_HOST}" bash <<EOF > /dev/null 2>&1
    sudo pkill -f "sshd.*${SSH_PORT}" > /dev/null 2>&1 && sleep 0.2 || true
    # Unlock ubuntu account if locked (shadow entry '!') so pubkey auth succeeds with UsePAM no
    if sudo grep -q '^ubuntu:!' /etc/shadow 2>/dev/null; then
        sudo passwd -d ubuntu > /dev/null 2>&1 || true
    fi
    cd ${VM2_REPO}
    source env.sh
    sudo nohup bash protocols/ssh/server.sh ${MODE} > /tmp/ssh-server-${MODE}.log 2>&1 &
EOF

log_tty_state "after server start"
wait_tcp "${SSH_PORT}" "/tmp/ssh-server-${MODE}.log"
check_vm1_reach "${SSH_PORT}" ssh

log_tty_state "before traffic_header"
traffic_header

set +m
COUNT=0
while [[ $_STOP -eq 0 ]]; do
    log_tty_state "loop top (#$((COUNT + 1)))"
    RESULT=$(timeout 10 "$SSH_BIN" \
        -p "${SSH_PORT}" \
        -i "${SSH_CLIENT_KEY}" \
        -o KexAlgorithms="${SSH_KEX}" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o BatchMode=yes \
        -v \
        "${VM2_USER}@${VM2_IP}" \
        'sleep 2' 2>&1 || true) 2>/dev/null
    log_tty_state "after ssh client"

    [[ $_STOP -eq 0 ]] || break
    COUNT=$((COUNT + 1))

    ts=$(printf '%(%Y-%m-%d %H:%M:%S)T' -1)
    kex=$(  printf '%s' "$RESULT" | grep -oE 'kex: algorithm: \S+'              | sed 's/^kex: algorithm: //'              | head -1 || true)
    ciph=$( printf '%s' "$RESULT" | grep -oE 'server->client cipher: \S+'      | sed 's/^server->client cipher: //;s/@.*//'  | head -1 || true)
    if printf '%s' "$RESULT" | grep -q 'Authenticated to\|debug1: Exit status'; then
        res="0"
    else
        res="FAILED"
    fi

    printf "%-21s %-16s %-7s %-28s %-36s %s\r\n" \
        "$ts" "${PROTO_TAG}" "#${COUNT}" "${kex:-unknown}" "${ciph:-unknown}" "$res"
    sleep 1
done
