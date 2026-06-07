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
    log ERROR "Run: bash env-setup.sh  (or bash env-setup.sh --skip-openssl --skip-strongswan --skip-openssh)"
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
log INFO "Library (server):   $("$NGINX" -V 2>&1 | grep -oE 'nginx/[0-9.]+' || true) + BoringSSL $("$NGINX" -V 2>&1 | grep -oE 'boringssl-[0-9.]+' | grep -oE '[0-9.]+' || true)"

# Reverse-proxy backend (Option A): both PROXY_HOST and PROXY_PORT must be set.
# Otherwise fall back to the built-in literal-200 response.
if [[ -n "${PROXY_HOST:-}" && -n "${PROXY_PORT:-}" ]]; then
    PROXY_TARGET="${PROXY_HOST}:${PROXY_PORT}"
    log INFO "Proxy target:       ${PROXY_TARGET}"
    LOCATION_BLOCK=$'        location / {\n            proxy_pass http://'"${PROXY_TARGET}"$';\n            proxy_set_header Host $host;\n            proxy_set_header X-Real-IP $remote_addr;\n            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n            proxy_set_header X-Forwarded-Proto $scheme;\n            proxy_http_version 1.1;\n        }'
else
    log INFO "Proxy target:       (none — fallback 200 response)"
    LOCATION_BLOCK=$'        location / {\n            return 200 "I am fine, client!\\n";\n            add_header Content-Type text/plain;\n        }'
fi
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

${LOCATION_BLOCK}
    }
}
CONF

"$NGINX" -t -c "$NGINX_CONF"
log INFO "Config test passed. Starting nginx ..."
printf '%s:%s' "${PROXY_HOST:-}" "${PROXY_PORT:-}" > "/tmp/quic-nginx-${MODE}.proxy"
exec "$NGINX" -c "$NGINX_CONF" -g "daemon off;"
