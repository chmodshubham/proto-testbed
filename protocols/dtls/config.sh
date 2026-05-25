#!/usr/bin/env bash
# protocols/dtls/config.sh — DTLS mode parameter sets (sourced, not executed)
#
# DTLS 1.2 only (no DTLS 1.3 exists). ML-KEM hybrid KEX requires TLS 1.3 and
# is therefore unavailable. Only classical mode is supported.

case "$MODE" in
    classical)
        CAFILE="${PKI}/ca/dtls/classical/ca-cert.pem"
        SERVER_CERT="${PKI}/dtls/classical/server-cert.pem"
        SERVER_KEY="${PKI}/dtls/classical/server-key.pem"
        DTLS_GROUPS="secp521r1:secp384r1"
        SIGALGS="ecdsa_secp521r1_sha512"
        CIPHERS="ECDHE-ECDSA-AES256-GCM-SHA384"
        ;;
    *)
        printf 'Usage: %s classical\nNote: DTLS 1.2 does not support ML-KEM hybrid KEX. No PQC mode.\n' "$0" >&2
        exit 1
        ;;
esac
