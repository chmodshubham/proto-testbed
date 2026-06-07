#!/usr/bin/env bash
# protocols/tls/server.sh — nginx TLS server on vm2
#
# Usage: bash protocols/tls/server.sh [classical|pqc]
# Run from repo root after sourcing env.sh.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "${REPO_ROOT}/orchestrator/common.sh"

MODE="${1:-classical}"
resolve_vm_config tls
BIND_IP="${VM2_IP:?VM2_IP not set. Source env.sh from repo root.}"

NGINX="${REPO_ROOT}/os-lib/install/nginx/sbin/nginx"

[[ -x "$NGINX" ]] || {
    log ERROR "nginx not found: ${NGINX}"
    log ERROR "Run: bash lib-setup.sh  (or bash lib-setup.sh --skip-openssl --skip-strongswan --skip-openssh)"
    exit 1
}

source "${REPO_ROOT}/protocols/tls/config.sh"

[[ -f "${PKI}/tls/${MODE}/server-cert.pem" ]] || {
    log ERROR "Certificate not found: ${PKI}/tls/${MODE}/server-cert.pem"
    log ERROR "Run: bash pki/gen.sh tls ${MODE}"
    exit 1
}

NGINX_CONF="/tmp/tls-nginx-${MODE}.conf"
NGINX_PID="/tmp/tls-nginx-${MODE}.pid"
NGINX_ERROR_LOG="/tmp/tls-server-${MODE}.log"

log INFO "Mode:               $MODE"
log INFO "Listening on:       ${BIND_IP}:${TLS_PORT}"
log INFO "Certificate:        ${PKI}/tls/${MODE}/server-cert.pem"
log INFO "Protocols:          $TLS_PROTOCOLS"
log INFO "KEX groups:         $TLS_GROUPS"
log INFO "Cipher suites:      $CIPHERS"
log INFO "Signature algs:     $SIGALGS"
log INFO "Library (server):   $("$NGINX" -V 2>&1 | grep -oE 'nginx/[0-9.]+' || true) + BoringSSL $("$NGINX" -V 2>&1 | grep -oE 'boringssl-[0-9.]+' | grep -oE '[0-9.]+' || true)"
printf '\n'

# ssl_ciphers applies to TLS 1.2 only; omit for TLS 1.3 to use negotiated defaults.
if [[ "$MODE" == "classical" ]]; then
    SSL_CIPHERS_LINE="        ssl_ciphers         ${CIPHERS};"
else
    SSL_CIPHERS_LINE=""
fi

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

cat > "$NGINX_CONF" <<CONF
worker_processes 1;
pid              ${NGINX_PID};
error_log        ${NGINX_ERROR_LOG} warn;

events {
    worker_connections 256;
}

http {
    server {
        listen      ${BIND_IP}:${TLS_PORT} ssl;
        server_name _;

        ssl_certificate     ${PKI}/tls/${MODE}/server-cert.pem;
        ssl_certificate_key ${PKI}/tls/${MODE}/server-key.pem;
        ssl_protocols       ${TLS_PROTOCOLS};
${SSL_CIPHERS_LINE}
        ssl_ecdh_curve      ${TLS_GROUPS};

        ssl_session_cache   off;
        ssl_session_tickets off;

${LOCATION_BLOCK}
    }
}
CONF

"$NGINX" -t -c "$NGINX_CONF"
log INFO "Config test passed. Starting nginx ..."
printf '%s:%s' "${PROXY_HOST:-}" "${PROXY_PORT:-}" > "/tmp/tls-nginx-${MODE}.proxy"
exec "$NGINX" -c "$NGINX_CONF" -g "daemon off;"
