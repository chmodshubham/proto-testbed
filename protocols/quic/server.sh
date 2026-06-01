#!/usr/bin/env bash
# protocols/quic/server.sh — nginx HTTP/3 (QUIC) server on vm2
#
# Usage: bash protocols/quic/server.sh [classical|pqc]
# Run from repo root after sourcing env.sh.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "${REPO_ROOT}/orchestrator/common.sh"

MODE="${1:-classical}"
resolve_vm_config quic
BIND_IP="${VM2_IP:?VM2_IP not set. Source env.sh from repo root.}"

NGINX="${REPO_ROOT}/os-lib/install/nginx/sbin/nginx"

[[ -x "$NGINX" ]] || {
    log ERROR "nginx not found: ${NGINX}"
    log ERROR "Run: bash lib-setup.sh  (or bash lib-setup.sh --skip-openssl --skip-strongswan --skip-openssh)"
    exit 1
}

source "${REPO_ROOT}/protocols/quic/config.sh"

[[ -f "${SERVER_CERT}" ]] || {
    log ERROR "Certificate not found: ${SERVER_CERT}"
    log ERROR "Run: bash pki/gen.sh quic ${MODE}"
    exit 1
}

NGINX_CONF="/tmp/quic-nginx-${MODE}.conf"
NGINX_PID="/tmp/quic-nginx-${MODE}.pid"
NGINX_ERROR_LOG="/tmp/quic-server-${MODE}.log"

log INFO "Mode:               $MODE"
log INFO "Listening on:       ${BIND_IP}:${QUIC_PORT} (UDP)"
log INFO "Certificate:        ${SERVER_CERT}"
log INFO "KEX groups:         $QUIC_GROUPS"
log INFO "Cipher suites:      $CIPHERS"
log INFO "Signature algs:     $SIGALGS"
printf '\n'

cat > "$NGINX_CONF" <<CONF
worker_processes 1;
pid              ${NGINX_PID};
error_log        ${NGINX_ERROR_LOG} warn;

events {
    worker_connections 256;
}

http {
    server {
        listen      ${BIND_IP}:${QUIC_PORT} quic reuseport;
        server_name _;

        ssl_certificate     ${SERVER_CERT};
        ssl_certificate_key ${SERVER_KEY};
        ssl_protocols       TLSv1.3;
        ssl_ecdh_curve      ${QUIC_GROUPS};

        add_header Alt-Svc 'h3=":${QUIC_PORT}"; ma=86400';

        location / {
            return 200 "QUIC OK\n";
            add_header Content-Type text/plain;
        }
    }
}
CONF

"$NGINX" -t -c "$NGINX_CONF"
log INFO "Config test passed. Starting nginx ..."

exec "$NGINX" -c "$NGINX_CONF" -g "daemon off;"
