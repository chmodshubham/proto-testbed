#!/usr/bin/env bash
# protocols/mtls/config.sh — mTLS mode parameter sets (sourced, not executed)
#
# Classical: server=ECDSA P-384, client=Ed448, KEX=x448, cipher=ChaCha20-Poly1305
# PQC:       server=ML-DSA-87,   client=ML-DSA-44, KEX=SecP384r1MLKEM1024, cipher=AES-256-GCM

case "$MODE" in
    classical)
        MTLS_PORT="${PORT_MTLS:?PORT_MTLS not set. Source env.sh from repo root.}"
        CAFILE="${PKI}/ca/mtls/classical/ca-cert.pem"
        SERVER_CERT="${PKI}/mtls/classical/server-cert.pem"
        SERVER_KEY="${PKI}/mtls/classical/server-key.pem"
        CLIENT_CERT="${PKI}/mtls/classical/client-cert.pem"
        CLIENT_KEY="${PKI}/mtls/classical/client-key.pem"
        MTLS_GROUPS="x448:secp384r1:X25519"
        SIGALGS="ecdsa_secp384r1_sha384:ed448"
        CIPHERS="TLS_CHACHA20_POLY1305_SHA256"
        ;;
    pqc)
        MTLS_PORT="${PORT_MTLS_PQC:?PORT_MTLS_PQC not set. Source env.sh from repo root.}"
        CAFILE="${PKI}/ca/mtls/pqc/ca-cert.pem"
        SERVER_CERT="${PKI}/mtls/pqc/server-cert.pem"
        SERVER_KEY="${PKI}/mtls/pqc/server-key.pem"
        CLIENT_CERT="${PKI}/mtls/pqc/client-cert.pem"
        CLIENT_KEY="${PKI}/mtls/pqc/client-key.pem"
        MTLS_GROUPS="SecP384r1MLKEM1024:X25519MLKEM768:secp384r1"
        SIGALGS="mldsa87:mldsa44:mldsa65"
        CIPHERS="TLS_AES_256_GCM_SHA384"
        ;;
    *)
        printf 'Usage: %s [classical|pqc]\n' "$0" >&2
        exit 1
        ;;
esac
