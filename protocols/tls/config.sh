#!/usr/bin/env bash
# protocols/tls/config.sh — TLS mode parameter sets (sourced, not executed)

case "$MODE" in
    classical)
        TLS_PORT="${PORT_TLS:?PORT_TLS not set. Source env.sh from repo root.}"
        CAFILE="${PKI}/ca/tls/classical/ca-cert.pem"
        TLS_PROTOCOLS="TLSv1.2 TLSv1.3"
        TLS_GROUPS="X25519:P-256:P-384"
        SIGALGS="ecdsa_secp256r1_sha256:ecdsa_secp384r1_sha384:rsa_pss_rsae_sha256"
        CIPHERS="ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256"
        ;;
    pqc)
        TLS_PORT="${PORT_TLS_PQC:?PORT_TLS_PQC not set. Source env.sh from repo root.}"
        CAFILE="${PKI}/ca/tls/pqc/ca-cert.pem"
        TLS_PROTOCOLS="TLSv1.3"
        TLS_GROUPS="X25519MLKEM768:X25519:P-256"
        SIGALGS="mldsa65:mldsa87:mldsa44:ecdsa_secp256r1_sha256:ecdsa_secp384r1_sha384"
        CIPHERS="TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256"
        ;;
    *)
        printf 'Usage: %s [classical|pqc]\n' "$0" >&2
        exit 1
        ;;
esac
