#!/usr/bin/env bash
# protocols/ssh/config.sh — SSH mode parameter sets (sourced, not executed)

OPENSSH="${REPO_ROOT}/os-lib/install/openssh"
SSH_BIN="${OPENSSH}/bin/ssh"
SSHD_BIN="${OPENSSH}/sbin/sshd"

case "$MODE" in
    classical)
        SSH_PORT="${PORT_SSH:?PORT_SSH not set. Source env.sh from repo root.}"
        SSH_HOST_KEY="${PKI}/ssh/classical/host-key"
        SSH_CLIENT_KEY="${PKI}/ssh/classical/client-key"
        SSH_AUTHORIZED_KEYS="${PKI}/ssh/classical/authorized_keys"
        SSH_KEX="curve25519-sha256,ecdh-sha2-nistp256,diffie-hellman-group14-sha256"
        ;;
    pqc)
        SSH_PORT="${PORT_SSH_PQC:?PORT_SSH_PQC not set. Source env.sh from repo root.}"
        SSH_HOST_KEY="${PKI}/ssh/pqc/host-key"
        SSH_CLIENT_KEY="${PKI}/ssh/pqc/client-key"
        SSH_AUTHORIZED_KEYS="${PKI}/ssh/pqc/authorized_keys"
        SSH_KEX="mlkem768x25519-sha256,curve25519-sha256"
        ;;
    *)
        printf 'Usage: %s [classical|pqc]\n' "$0" >&2
        exit 1
        ;;
esac
