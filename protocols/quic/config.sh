#!/usr/bin/env bash
# protocols/quic/config.sh — QUIC mode parameter sets (sourced, not executed)
#
# Classical: CA=Ed25519, server=Ed25519, KEX=X25519, cipher=TLS_AES_128_GCM_SHA256
# PQC:       CA=ML-DSA-44, server=ML-DSA-65, KEX=X25519MLKEM768, cipher=TLS_AES_128_GCM_SHA256

case "$MODE" in
    classical)
        QUIC_PORT="${PORT_QUIC:?PORT_QUIC not set. Source env.sh from repo root.}"
        CAFILE="${PKI}/ca/quic/classical/ca-cert.pem"
        SERVER_CERT="${PKI}/quic/classical/server-cert.pem"
        SERVER_KEY="${PKI}/quic/classical/server-key.pem"
        QUIC_GROUPS="X25519:P-256"
        SIGALGS="ed25519:ecdsa_secp256r1_sha256"
        CIPHERS="TLS_AES_128_GCM_SHA256"
        ;;
    pqc)
        QUIC_PORT="${PORT_QUIC_PQC:?PORT_QUIC_PQC not set. Source env.sh from repo root.}"
        CAFILE="${PKI}/ca/quic/pqc/ca-cert.pem"
        SERVER_CERT="${PKI}/quic/pqc/server-cert.pem"
        SERVER_KEY="${PKI}/quic/pqc/server-key.pem"
        QUIC_GROUPS="X25519MLKEM768:X25519:P-256"
        SIGALGS="mldsa65:mldsa44:ed25519"
        CIPHERS="TLS_AES_128_GCM_SHA256"
        ;;
    *)
        printf 'Usage: %s [classical|pqc]\n' "$0" >&2
        exit 1
        ;;
esac
