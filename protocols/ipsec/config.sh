#!/usr/bin/env bash
# protocols/ipsec/config.sh — sourced by server.sh, client.sh, orchestrator/ipsec.sh

MODE="${1:-${MODE:-}}"
case "$MODE" in
    classical)
        IPSEC_PORT="${PORT_IPSEC:?PORT_IPSEC not set. Source env.sh from repo root.}"
        IPSEC_CA="${PKI}/ca/ipsec/classical/ca-cert.pem"
        IPSEC_SERVER_CERT="${PKI}/ipsec/classical/server-cert.pem"
        IPSEC_SERVER_KEY="${PKI}/ipsec/classical/server-key.pem"
        IPSEC_CLIENT_CERT="${PKI}/ipsec/classical/client-cert.pem"
        IPSEC_CLIENT_KEY="${PKI}/ipsec/classical/client-key.pem"
        IPSEC_IKE_PROPOSALS="aes256gcm16-prfsha384-ecp256"
        IPSEC_ESP_PROPOSALS="aes256gcm16-ecp256-noesn"
        ;;
    pqc)
        IPSEC_PORT="${PORT_IPSEC_PQC:?PORT_IPSEC_PQC not set. Source env.sh from repo root.}"
        IPSEC_CA="${PKI}/ca/ipsec/pqc/ca-cert.pem"
        IPSEC_SERVER_CERT="${PKI}/ipsec/pqc/server-cert.pem"
        IPSEC_SERVER_KEY="${PKI}/ipsec/pqc/server-key.pem"
        IPSEC_CLIENT_CERT="${PKI}/ipsec/pqc/client-cert.pem"
        IPSEC_CLIENT_KEY="${PKI}/ipsec/pqc/client-key.pem"
        IPSEC_IKE_PROPOSALS="aes256gcm16-prfsha384-mlkem768"
        IPSEC_ESP_PROPOSALS="aes256gcm16-mlkem768-noesn"
        ;;
    *)
        printf 'Usage: source %s [classical|pqc]\n' "$0" >&2
        exit 1
        ;;
esac

IPSEC_CONN="testbed-${MODE}"
STRONGSWAN="${REPO_ROOT}/os-lib/install/strongswan"
SWANCTL="${STRONGSWAN}/sbin/swanctl"
CHARON="${STRONGSWAN}/libexec/ipsec/charon"
