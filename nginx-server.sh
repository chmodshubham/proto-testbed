#!/usr/bin/env bash
# nginx-server.sh — manage the persistent nginx server on vm2 (TLS / QUIC).
#
# nginx persists on vm2 across traffic runs; this script is the
# explicit lifecycle manager (start / stop / status).
#
# Usage:
#   ./nginx-server.sh start  --proto tls|quic --mode classical|pqc
#   ./nginx-server.sh stop   --proto tls|quic [--mode classical|pqc]   # default: both modes
#   ./nginx-server.sh status --proto tls|quic [--mode classical|pqc]   # default: both modes
#
# Set the per-protocol VM2_* variables in env.sh first.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

if [[ ! -f "${REPO_ROOT}/env.sh" ]]; then
    printf 'ERROR: env.sh not found in repo root: %s\n' "${REPO_ROOT}" >&2
    exit 1
fi
source "${REPO_ROOT}/env.sh"
source "${REPO_ROOT}/orchestrator/common.sh"

usage() {
    printf 'Usage: %s <start|stop|status> --proto tls|quic [--mode classical|pqc]\n\n' "$0"
    printf '  start   start the server for one --proto/--mode (reuses if already running)\n'
    printf '  stop    stop the server for --proto (both modes unless --mode given)\n'
    printf '  status  print UP/DOWN per mode for --proto\n'
}

# ---------------------------------------------------------------------------
# Argument parsing — mirrors run.sh style
# ---------------------------------------------------------------------------

ACTION=""
PROTO=""
MODE=""
POSITIONAL=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)   usage; exit 0 ;;
        start|stop|status)
            [[ -n "$ACTION" ]] && { log ERROR "Multiple actions given: '$ACTION' and '$1'."; usage >&2; exit 1; }
            ACTION="$1"; shift ;;
        --proto=*)   PROTO="${1#--proto=}"; shift ;;
        --proto)
            [[ $# -lt 2 ]] && { log ERROR "--proto requires a value."; usage >&2; exit 1; }
            PROTO="$2"; shift 2 ;;
        --mode=*)    MODE="${1#--mode=}"; shift ;;
        --mode)
            [[ $# -lt 2 ]] && { log ERROR "--mode requires a value."; usage >&2; exit 1; }
            MODE="$2"; shift 2 ;;
        -*)          log ERROR "Unknown flag: '$1'."; usage >&2; exit 1 ;;
        *)           POSITIONAL+=("$1"); shift ;;
    esac
done

[[ ${#POSITIONAL[@]} -gt 0 ]] && { log ERROR "Unexpected argument(s): ${POSITIONAL[*]}."; usage >&2; exit 1; }
[[ -z "$ACTION" ]] && { log ERROR "No action given (start|stop|status)."; usage >&2; exit 1; }

case "$PROTO" in
    tls|quic) ;;
    "")  log ERROR "--proto is required (tls|quic)."; usage >&2; exit 1 ;;
    *)   log ERROR "Invalid --proto '$PROTO'. nginx serves tls and quic only."; usage >&2; exit 1 ;;
esac

if [[ -n "$MODE" ]]; then
    case "$MODE" in classical|pqc) ;;
        *) log ERROR "Invalid --mode '$MODE'. Valid: classical, pqc."; usage >&2; exit 1 ;;
    esac
fi

resolve_vm_config "$PROTO"

# Modes to act on: the given one, or both when --mode omitted.
modes_to_use() {
    if [[ -n "$MODE" ]]; then printf '%s\n' "$MODE"; else printf 'classical\npqc\n'; fi
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

do_start() {
    [[ -n "$MODE" ]] || { log ERROR "start requires --mode classical|pqc."; exit 1; }
    if nginx_alive_vm2 "$PROTO" "$MODE"; then
        if nginx_proxy_stale_vm2 "$PROTO" "$MODE"; then
            log INFO "Proxy config changed — restarting ${PROTO} server (${MODE}) on ${VM2_HOST} ..."
            ssh_vm2 -n "${VM2_USER}@${VM2_HOST}" "
                pf=${VM2_REPO}/os-lib/install/nginx/logs/${PROTO}-nginx-${MODE}.pid
                [[ -f \"\$pf\" ]] && kill \"\$(cat \"\$pf\")\" 2>/dev/null || true
            " 2>/dev/null || true
            sleep 0.3
        else
            log INFO "Reusing running ${PROTO} server (${MODE}) on ${VM2_HOST}."
            return 0
        fi
    fi
    log INFO "Starting ${PROTO} server (${MODE}) on ${VM2_HOST} ..."
    ssh_vm2 "${VM2_USER}@${VM2_HOST}" bash <<EOF > /dev/null 2>&1
        cd ${VM2_REPO}
        source env.sh
        nohup bash protocols/${PROTO}/server.sh ${MODE} > ${VM2_REPO}/os-lib/install/nginx/logs/${PROTO}-server-${MODE}.log 2>&1 &
EOF
    if nginx_alive_vm2 "$PROTO" "$MODE"; then
        log INFO "${PROTO} server (${MODE}) started on ${VM2_HOST}."
    else
        log ERROR "${PROTO} server (${MODE}) did not start. Check ${VM2_REPO}/os-lib/install/nginx/logs/${PROTO}-server-${MODE}.log on ${VM2_HOST}."
        exit 1
    fi
}

do_stop() {
    if [[ -z "$MODE" ]]; then
        # Both modes: kill_vm2_ports clears all pidfiles/ports for the protocol.
        log INFO "Stopping ${PROTO} server on ${VM2_HOST} ..."
        kill_vm2_ports "$PROTO"
    else
        # Single mode: kill only that mode's pidfile + bound port.
        log INFO "Stopping ${PROTO}/${MODE} server on ${VM2_HOST} ..."
        # NOTE: no `-n` here — heredoc supplies bash via stdin; `-n` would block it.
        ssh_vm2 "${VM2_USER}@${VM2_HOST}" bash <<EOF 2>/dev/null || true
            cd "${VM2_REPO}" || exit 0
            source env.sh || exit 0
            pf=${VM2_REPO}/os-lib/install/nginx/logs/${PROTO}-nginx-${MODE}.pid
            [[ -f "\$pf" ]] && kill "\$(cat "\$pf")" 2>/dev/null || true
            case "${PROTO}/${MODE}" in
                tls/classical)  sudo fuser -k \${PORT_TLS}/tcp      > /dev/null 2>&1 || true ;;
                tls/pqc)        sudo fuser -k \${PORT_TLS_PQC}/tcp  > /dev/null 2>&1 || true ;;
                quic/classical) sudo fuser -k \${PORT_QUIC}/udp     > /dev/null 2>&1 || true ;;
                quic/pqc)       sudo fuser -k \${PORT_QUIC_PQC}/udp > /dev/null 2>&1 || true ;;
            esac
            pkill -f "nginx.*${PROTO}-nginx-${MODE}" > /dev/null 2>&1 || true
            sleep 0.3
EOF
    fi
    log INFO "Done."
}

do_status() {
    local m
    while read -r m; do
        if nginx_alive_vm2 "$PROTO" "$m"; then
            local pid
            pid="$(ssh_vm2 -n "${VM2_USER}@${VM2_HOST}" "cat ${VM2_REPO}/os-lib/install/nginx/logs/${PROTO}-nginx-${m}.pid 2>/dev/null" 2>/dev/null || true)"
            log INFO "${PROTO}/${m}: UP (pid ${pid})"
        else
            log INFO "${PROTO}/${m}: DOWN"
        fi
    done < <(modes_to_use)
}

case "$ACTION" in
    start)  do_start ;;
    stop)   do_stop ;;
    status) do_status ;;
esac
