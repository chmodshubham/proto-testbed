#!/usr/bin/env bash
# run.sh — testbed runner
#
# Syncs repo to vm2, starts the server, runs traffic. Press Ctrl-C to stop.
#
# Usage:
#   ./run.sh [--proto PROTO] [--mode MODE] [--help]
#
#   PROTO  tls | mtls | dtls | quic | ipsec | ssh | all   (default: all)
#   MODE   classical | pqc | all                          (default: all)
#
# Examples:
#   ./run.sh                               # all protocols; IPsec runs pqc only
#   ./run.sh --proto tls                   # TLS only, both modes
#   ./run.sh --proto tls --mode classical  # TLS classical only
#   ./run.sh --proto ipsec --mode pqc      # IPsec PQC only
#   ./run.sh --proto ipsec --mode classical
#   ./run.sh --proto ssh --mode pqc        # SSH PQC only
#
# Note: --proto ipsec --mode all is not supported. Two charon instances cannot
#       share kernel XFRM on the same host. Specify classical or pqc explicitly.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

if [[ ! -f "${REPO_ROOT}/env.sh" ]]; then
    printf 'ERROR: env.sh not found in repo root: %s\n' "${REPO_ROOT}" >&2
    exit 1
fi
source "${REPO_ROOT}/env.sh"
source "${REPO_ROOT}/orchestrator/common.sh"

# ---------------------------------------------------------------------------
# Argument parsing (must precede binary checks so --proto drives what to check)
# ---------------------------------------------------------------------------

usage() {
    printf 'Usage: %s [--proto PROTO] [--mode MODE] [--help]\n\n' "$0"
    printf '  --proto  tls | mtls | dtls | quic | ipsec | ssh | all   (default: all)\n'
    printf '  --mode   classical | pqc | all                    (default: all)\n'
    printf '\n'
    printf '  Set VM2_PASSWORD in env.sh if vm2 system SSH requires password auth.\n'
    printf '  Requires sshpass: sudo apt-get install -y sshpass\n'
}

PROTO=""
MODE=""
POSITIONAL=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            usage; exit 0 ;;
        --proto=*)
            PROTO="${1#--proto=}"; shift ;;
        --proto)
            [[ $# -lt 2 ]] && { log ERROR "--proto requires a value."; usage >&2; exit 1; }
            PROTO="$2"; shift 2 ;;
        --mode=*)
            MODE="${1#--mode=}"; shift ;;
        --mode)
            [[ $# -lt 2 ]] && { log ERROR "--mode requires a value."; usage >&2; exit 1; }
            MODE="$2"; shift 2 ;;
        -*)
            log ERROR "Unknown flag: '$1'."; usage >&2; exit 1 ;;
        *)
            POSITIONAL+=("$1"); shift ;;
    esac
done

[[ ${#POSITIONAL[@]} -gt 0 ]] && { log ERROR "Unexpected argument(s): ${POSITIONAL[*]}."; usage >&2; exit 1; }

PROTO="${PROTO:-all}"
MODE="${MODE:-all}"

case "$PROTO" in tls|mtls|dtls|quic|ipsec|ssh|all) ;;
    *) log ERROR "Invalid protocol '$PROTO'. Valid values: tls, mtls, dtls, quic, ipsec, ssh, all."; usage >&2; exit 1 ;;
esac
case "$MODE" in classical|pqc|all) ;;
    *) log ERROR "Invalid mode '$MODE'. Valid values: classical, pqc, all."; usage >&2; exit 1 ;;
esac
[[ "$PROTO" == "dtls" && "$MODE" == "pqc" ]] && {
    log ERROR "DTLS does not support PQC (DTLS 1.2 only; ML-KEM requires TLS 1.3)."; exit 1
}
[[ "$PROTO" == "ipsec" && "$MODE" == "all" ]] && {
    log INFO "IPsec cannot run two modes in parallel (charon holds kernel XFRM). Defaulting to pqc."
    MODE="pqc"
}

# Per-protocol VM config is resolved later (prepare_proto), once per protocol.
# Each protocol syncs and runs against its own vm2; there is no single shared vm2.

# ---------------------------------------------------------------------------
# Binary checks — only for the protocols being run
# ---------------------------------------------------------------------------

needs_openssl=0
needs_strongswan=0
needs_openssh=0

# Note: nginx is NOT checked here. It runs only on vm2 (server side), never on
# this host (vm1/client). Its presence is verified remotely in prepare_proto.
case "$PROTO" in
    tls)           needs_openssl=1 ;;
    mtls|dtls)     needs_openssl=1 ;;
    quic)          needs_openssl=1 ;;
    ipsec)         needs_strongswan=1 ;;
    ssh)           needs_openssh=1 ;;
    all)           needs_openssl=1; needs_strongswan=1; needs_openssh=1 ;;
esac

if [[ $needs_openssl -eq 1 ]]; then
    OSSL="${REPO_ROOT}/os-lib/install/openssl-4.0/bin/openssl"
    if [[ ! -x "$OSSL" ]]; then
        log ERROR "OpenSSL 4.0 not found at: ${OSSL}"
        log ERROR "Build it first: bash env-setup.sh"
        exit 1
    fi
fi

if [[ $needs_openssh -eq 1 ]]; then
    SSH_BIN_CHK="${REPO_ROOT}/os-lib/install/openssh/bin/ssh"
    if [[ ! -x "$SSH_BIN_CHK" ]]; then
        log ERROR "OpenSSH not found at: ${SSH_BIN_CHK}"
        log ERROR "Build it first. See protocols/ssh/README.md."
        exit 1
    fi
fi

if [[ $needs_strongswan -eq 1 ]]; then
    SWAN="${REPO_ROOT}/os-lib/install/strongswan/sbin/swanctl"
    if [[ ! -x "$SWAN" ]]; then
        log ERROR "strongSwan not found at: ${SWAN}"
        log ERROR "Build it first. See protocols/ipsec/README.md Steps 1-4."
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Dependency checks — install missing apt packages before any work starts
# ---------------------------------------------------------------------------

# rsync always needed for repo sync
ensure_apt_deps rsync

# protocol-specific build/runtime deps
case "$PROTO" in
    tls|mtls|dtls|quic|all)
        ensure_apt_deps build-essential cmake pkg-config perl python3
        ;;
esac
case "$PROTO" in
    quic|all)
        ensure_apt_deps libnghttp3-dev
        ;;
esac
case "$PROTO" in
    ipsec|all)
        ensure_apt_deps build-essential pkg-config flex bison libssl-dev
        ;;
esac
case "$PROTO" in
    ssh|all)
        ensure_apt_deps build-essential libpam0g-dev libssl-dev zlib1g-dev
        ;;
esac
# sshpass needed when any per-protocol VM2 password is set (management SSH)
for _p in TLS MTLS DTLS QUIC IPSEC SSH; do
    _pw="${_p}_VM2_PASSWORD"
    if [[ -n "${!_pw:-}" ]]; then ensure_apt_deps sshpass; break; fi
done

# ---------------------------------------------------------------------------
# Build C client binaries on vm1 (dtls, quic)
# ---------------------------------------------------------------------------

build_local() {
    local proto="$1"
    local dir="${REPO_ROOT}/protocols/${proto}"
    if [[ ! -x "${dir}/client" ]]; then
        log INFO "Building ${proto} client on vm1 ..."
        make -s -C "$dir" client || {
            log ERROR "Failed to build ${proto} client."
            exit 1
        }
        log INFO "Build complete."
    fi
}

case "$PROTO" in
    dtls|all) build_local dtls ;;
esac
case "$PROTO" in
    quic|all) build_local quic ;;
esac

# ---------------------------------------------------------------------------
# Per-protocol vm2 preparation: resolve that protocol's VM, sync the repo to it,
# build its C server binary if needed, and clear stale servers on its ports.
# Each protocol may target a different vm2, so this runs once per protocol.
# ---------------------------------------------------------------------------

PREPARED_PROTOS=()

# pki_marker <proto> <mode> — print the path that proves PKI is generated for proto/mode.
pki_marker() {
    case "$1" in
        ssh) printf '%s/pki/out/ssh/%s/client-key' "$REPO_ROOT" "$2" ;;
        *)   printf '%s/pki/out/%s/%s/server-cert.pem' "$REPO_ROOT" "$1" "$2" ;;
    esac
}

# ensure_pki <proto> — for each mode this run needs, check the marker file and
# generate that single (proto, mode) pair if missing. Skips silently when a
# marker is already present, so partial state (e.g. classical present, pqc
# missing under --mode all) regenerates only the missing pair. Fails fast on
# invalid args or gen.sh errors.
#
# Modes considered come from the global $MODE flag. DTLS has no pqc mode, so
# it always resolves to classical here.
ensure_pki() {
    local proto="$1"
    local m marker modes=()
    case "$MODE" in
        classical) modes=(classical) ;;
        pqc)       modes=(pqc) ;;
        all)       modes=(classical pqc) ;;
    esac
    if [[ "$proto" == "dtls" ]]; then
        modes=(classical)
    fi
    for m in "${modes[@]}"; do
        marker="$(pki_marker "$proto" "$m")"
        if [[ -f "$marker" ]]; then
            continue
        fi
        log INFO "Generating ${proto}/${m} PKI on vm1 ..."
        if ! "${REPO_ROOT}/pki/gen.sh" --proto "$proto" --mode "$m" >/dev/null; then
            log ERROR "Failed to generate ${proto}/${m} PKI. Check pki/gen.sh output."
            exit 1
        fi
        if [[ ! -f "$marker" ]]; then
            log ERROR "PKI marker still missing after generation: ${marker}"
            exit 1
        fi
    done
}

prepare_proto() {
    local proto="$1"
    resolve_vm_config "$proto"
    ensure_pki "$proto"

    # nginx (tls/quic) runs on vm2, not this host. Verify the binary exists there
    # before syncing/starting, so a missing server-side build fails with a clear
    # message instead of an opaque startup error later.
    if [[ "$proto" == "tls" || "$proto" == "quic" ]]; then
        if ! ssh_vm2 "${VM2_USER}@${VM2_HOST}" \
                "[[ -x '${VM2_REPO}/os-lib/install/nginx/sbin/nginx' ]]" 2>/dev/null; then
            log ERROR "nginx not found on ${VM2_HOST}: ${VM2_REPO}/os-lib/install/nginx/sbin/nginx"
            log ERROR "Build it on the server (vm2): bash env-setup.sh"
            exit 1
        fi
        check_backend "$proto"
    fi

    log INFO "Syncing repo to ${VM2_USER}@${VM2_HOST}:${VM2_REPO} (${proto}) ..."
    rsync_vm2 -a --delete \
        --exclude='os-lib/' \
        --exclude='.git/' \
        "${REPO_ROOT}/" "${VM2_USER}@${VM2_HOST}:${VM2_REPO}/"

    if [[ "$proto" == "dtls" ]]; then
        if ! ssh_vm2 "${VM2_USER}@${VM2_HOST}" \
                "[[ -x '${VM2_REPO}/protocols/dtls/server' ]]" 2>/dev/null; then
            log INFO "Building dtls server on ${VM2_HOST} ..."
            ssh_vm2 "${VM2_USER}@${VM2_HOST}" \
                "make -s -C '${VM2_REPO}/protocols/dtls' server" || {
                log ERROR "Failed to build dtls server on ${VM2_HOST}."
                exit 1
            }
        fi
    fi

    # nginx (tls/quic) is persistent across runs: reuse live servers instead of
    # killing them here. Resolve MODE=all to both modes, and only clear when no
    # server for any intended mode is alive (truly stale state).
    if [[ "$proto" == "tls" || "$proto" == "quic" ]]; then
        local _modes_to_check=()
        case "$MODE" in
            classical) _modes_to_check=(classical) ;;
            pqc)       _modes_to_check=(pqc) ;;
            all)       _modes_to_check=(classical pqc) ;;
        esac
        local _any_alive=0 _m
        for _m in "${_modes_to_check[@]}"; do
            if nginx_alive_vm2 "$proto" "$_m"; then
                if nginx_proxy_stale_vm2 "$proto" "$_m"; then
                    log INFO "Proxy config changed for ${proto}/${_m} — restarting nginx ..."
                    ssh_vm2 -n "${VM2_USER}@${VM2_HOST}" "
                        pf=${VM2_REPO}/os-lib/install/nginx/logs/${proto}-nginx-${_m}.pid
                        [[ -f \"\$pf\" ]] && kill \"\$(cat \"\$pf\")\" 2>/dev/null || true
                    " 2>/dev/null || true
                else
                    log INFO "Reusing persistent ${proto}/${_m} server on ${VM2_HOST}."
                    _any_alive=1
                fi
            fi
        done
        if [[ $_any_alive -eq 0 ]]; then
            log INFO "Clearing stale servers on ${VM2_HOST} (${proto}) ..."
            kill_vm2_ports "${proto}"
        fi
    else
        log INFO "Clearing stale servers on ${VM2_HOST} (${proto}) ..."
        kill_vm2_ports "${proto}"
    fi
    PREPARED_PROTOS+=("$proto")
}

# Flush any leftover XFRM state from a previous crashed ipsec run.
# The EXIT trap cannot fire on SIGKILL, so stale policies can block SSH to vm2.
case "$PROTO" in ipsec|all)
    sudo -n ip xfrm policy flush 2>/dev/null </dev/null || true
    sudo -n ip xfrm state flush  2>/dev/null </dev/null || true
    sudo -n pkill -f "libexec/ipsec/charon" 2>/dev/null </dev/null || true
    ;; esac

# prepare every protocol that will run, before launching traffic
if [[ "$PROTO" == "all" ]]; then
    for _proto in tls mtls dtls quic ipsec ssh; do
        [[ "$_proto" == "dtls" && "$MODE" == "pqc" ]] && continue
        if ! has_vm_config "$_proto"; then
            log INFO "Skipping ${_proto}: VM config not set in env.sh."
            continue
        fi
        prepare_proto "$_proto"
    done
else
    prepare_proto "$PROTO"
fi
log INFO "All targets prepared."
printf '\r\n'

# ---------------------------------------------------------------------------
# Cleanup: stop all servers on vm2 and client processes on vm1 on exit
# ---------------------------------------------------------------------------

BGPIDS=()
BACKEND_PIDS=()
_CLEANED=0

cleanup() {
    [[ $_CLEANED -eq 1 ]] && return
    _CLEANED=1
    printf '\r\n'
    log INFO "Stopping ..."
    # Forward SIGTERM to all prefix_run subshells; each forwards to its orchestrator,
    # whose trap kills the remote server on vm2.
    if [[ ${#BGPIDS[@]} -gt 0 ]]; then
        set +m
        kill -TERM "${BGPIDS[@]}" 2>/dev/null || true
        # Wait up to 3s for graceful exit
        local i
        for i in {1..10}; do
            local alive=0
            local p
            for p in "${BGPIDS[@]}"; do
                kill -0 "$p" 2>/dev/null && alive=1 && break
            done
            [[ $alive -eq 0 ]] && break
            sleep 0.3
        done
        kill -KILL "${BGPIDS[@]}" 2>/dev/null || true
        { wait "${BGPIDS[@]}"; } 2>/dev/null || true
    fi
    if [[ ${#BACKEND_PIDS[@]} -gt 0 ]]; then
        kill "${BACKEND_PIDS[@]}" 2>/dev/null || true
    fi
    # Belt-and-suspenders: for each prepared protocol, resolve its vm2 and kill any
    # servers the orchestrator traps may have missed on that protocol's ports.
    # nginx (tls/quic) is persistent: leave it running on vm2 after a run ends.
    # Stop it explicitly with ./nginx-server.sh stop --proto tls|quic.
    local cp
    for cp in "${PREPARED_PROTOS[@]}"; do
        [[ "$cp" == "tls" || "$cp" == "quic" ]] && continue
        resolve_vm_config "$cp"
        kill_vm2_ports "$cp"
    done
    # Local charon and XFRM state (ipsec client runs on vm1)
    sudo -n pkill -f "libexec/ipsec/charon" 2>/dev/null </dev/null || true
    sudo -n ip xfrm policy flush 2>/dev/null </dev/null || true
    sudo -n ip xfrm state flush  2>/dev/null </dev/null || true
    log INFO "Done."
}

trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup' EXIT

# start_backend_if_needed — when a TLS or QUIC proxy target equals the local
# VM1_IP, launch a Python HTTP backend so nginx can forward traffic to it.
# Deduplicates by port so --proto all only starts one instance per port.
start_backend_if_needed() {
    local started_ports=() proto_upper lower_p host_var port_var vm1_var h p v1 already sp
    for proto_upper in TLS QUIC; do
        lower_p="$(printf '%s' "$proto_upper" | tr '[:upper:]' '[:lower:]')"
        [[ "$PROTO" != "$lower_p" && "$PROTO" != "all" ]] && continue
        host_var="${proto_upper}_PROXY_HOST"
        port_var="${proto_upper}_PROXY_PORT"
        vm1_var="${proto_upper}_VM1_IP"
        h="${!host_var:-}"; p="${!port_var:-}"; v1="${!vm1_var:-}"
        [[ -z "$h" || -z "$p" || "$h" != "$v1" ]] && continue
        already=0
        if [[ ${#started_ports[@]} -gt 0 ]]; then
            for sp in "${started_ports[@]}"; do [[ "$sp" == "$p" ]] && already=1; done
        fi
        [[ $already -eq 1 ]] && continue
        log INFO "Starting HTTP backend on ${h}:${p} ..."
        python3 -m http.server "$p" --bind "$h" --directory /tmp \
            > "/tmp/backend-${p}.log" 2>&1 &
        local bpid=$!
        BACKEND_PIDS+=("$bpid")
        started_ports+=("$p")
        # Confirm the backend actually bound the port. http.server with `&` returns
        # a pid even when the bind fails (port busy, perm); poll so a dead backend
        # surfaces here instead of as opaque nginx 502s during the traffic loop.
        local up=0 i
        for i in {1..20}; do
            if ! kill -0 "$bpid" 2>/dev/null; then break; fi   # process already died
            if timeout 1 bash -c "</dev/tcp/${h}/${p}" 2>/dev/null; then up=1; break; fi
            sleep 0.25
        done
        if [[ $up -eq 1 ]]; then
            log INFO "HTTP backend up on ${h}:${p} (log: /tmp/backend-${p}.log)"
        else
            log ERROR "HTTP backend FAILED to start on ${h}:${p}. Last log lines:"
            tail -n 5 "/tmp/backend-${p}.log" 2>/dev/null | while IFS= read -r _ln; do log ERROR "  ${_ln}"; done
            log ERROR "nginx will return 502 for ${proto_upper} until the backend is up."
        fi
    done
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

# prefix_run <label> <proto> <mode> — run orchestrator with TESTBED_NO_HEADER=1 (header already printed)
# Runs orchestrator as a direct child (not inside a pipeline) so signals reach it.
prefix_run() {
    set +m
    local label="$1" proto="$2" mode="$3"
    local fifo orch_pid
    fifo="$(mktemp -u /tmp/run-fifo-XXXXXX)"
    mkfifo "$fifo"
    cat < "$fifo" 2>/dev/null &
    local cat_pid=$!
    disown "$cat_pid" 2>/dev/null || true
    TESTBED_NO_HEADER=1 bash "${REPO_ROOT}/orchestrator/${proto}.sh" "$mode" < /dev/null > "$fifo" 2>&1 &
    orch_pid=$!
    # Forward SIGTERM/SIGINT to orchestrator so its cleanup trap fires
    trap "kill -TERM $orch_pid 2>/dev/null || true; kill -TERM $cat_pid 2>/dev/null || true" TERM INT
    wait "$orch_pid" 2>/dev/null || true
    local rc=$?
    kill "$cat_pid" 2>/dev/null || true
    wait "$cat_pid" 2>/dev/null || true
    rm -f "$fifo"
    return $rc
} 2>/dev/null

# print_lib_info <proto> — print library versions used by proto before traffic starts.
# For nginx-based (tls, quic): fetch from vm2 via SSH; show server+client libs.
# For openssl-based (mtls, dtls): show openssl version (same lib for client and server).
# For ipsec: show strongSwan version. For ssh: show OpenSSH version.
print_lib_info() {
    local proto="$1"
    local ossl_ver nginx_ver bssl_ver swan_ver ssh_ver
    # Ensure VM2 vars are set for protocols that need SSH to fetch server lib version.
    case "$proto" in tls|quic)
        [[ -n "${VM2_USER:-}" && -n "${VM2_HOST:-}" && -n "${VM2_REPO:-}" ]] \
            || resolve_vm_config "$proto"
        ;; esac
    # Disable errexit/nounset inside this function so version queries never abort the run.
    set +eu
    case "$proto" in
        tls|quic)
            nginx_ver=$(ssh_vm2 "${VM2_USER}@${VM2_HOST}" \
                "${VM2_REPO}/os-lib/install/nginx/sbin/nginx -V 2>&1" \
                | grep -oE 'nginx/[0-9.]+' | head -1 || true)
            bssl_ver=$(ssh_vm2 "${VM2_USER}@${VM2_HOST}" \
                "${VM2_REPO}/os-lib/install/nginx/sbin/nginx -V 2>&1" \
                | grep -oE 'boringssl-[0-9.]+' | head -1 | grep -oE '[0-9.]+' || true)
            ossl_ver=$("$OSSL" version 2>/dev/null | grep -oE 'OpenSSL [0-9.]+' | head -1 || true)
            log INFO "Library (server):   ${nginx_ver} + BoringSSL ${bssl_ver}"
            log INFO "Library (client):   ${ossl_ver}"
            ;;
        mtls|dtls)
            ossl_ver=$("$OSSL" version 2>/dev/null | grep -oE 'OpenSSL [0-9.]+' | head -1 || true)
            log INFO "Library:            ${ossl_ver}"
            ;;
        ipsec)
            local _swan="${REPO_ROOT}/os-lib/install/strongswan"
            swan_ver=$(LD_LIBRARY_PATH="${_swan}/lib/ipsec" \
                "${_swan}/sbin/swanctl" --version 2>&1 \
                | grep -oE 'strongSwan [0-9.]+' | head -1 || true)
            log INFO "Library:            ${swan_ver}"
            ;;
        ssh)
            local _ssh="${REPO_ROOT}/os-lib/install/openssh/bin/ssh"
            ssh_ver=$("$_ssh" -V 2>&1 | grep -oE 'OpenSSH_[0-9a-zA-Z.]+' | head -1 || true)
            log INFO "Library:            ${ssh_ver}"
            ;;
    esac
    set -eu
}

run_sequential() {
    local proto="$1" mode="$2"
    log INFO "================================================================"
    log INFO "Protocol: ${proto}  |  Mode: ${mode}"
    log INFO "================================================================"
    printf '\r\n'
    print_lib_info "$proto"
    bash "${REPO_ROOT}/orchestrator/${proto}.sh" "$mode"
}


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

start_backend_if_needed
set +m
if [[ "$PROTO" == "all" && "$MODE" == "all" ]]; then
    log INFO "IPsec: pqc mode only. Parallel classical+pqc unsupported: charon holds the kernel XFRM socket and policy, blocking a second instance."
    for _lp in tls mtls dtls quic ipsec ssh; do
        has_vm_config "$_lp" && { resolve_vm_config "$_lp"; print_lib_info "$_lp"; } || true
    done
    traffic_header
    has_vm_config tls  && { prefix_run "tls/classical"  tls  classical & BGPIDS+=($!); }
    has_vm_config tls  && { prefix_run "tls/pqc"        tls  pqc       & BGPIDS+=($!); }
    has_vm_config mtls && { prefix_run "mtls/classical" mtls classical & BGPIDS+=($!); }
    has_vm_config mtls && { prefix_run "mtls/pqc"       mtls pqc       & BGPIDS+=($!); }
    has_vm_config quic && { prefix_run "quic/classical" quic classical & BGPIDS+=($!); }
    has_vm_config quic && { prefix_run "quic/pqc"       quic pqc       & BGPIDS+=($!); }
    has_vm_config dtls && { prefix_run "dtls/classical" dtls classical & BGPIDS+=($!); }
    has_vm_config ipsec && { prefix_run "ipsec/pqc"     ipsec pqc      & BGPIDS+=($!); }
    has_vm_config ssh  && { prefix_run "ssh/classical"  ssh  classical & BGPIDS+=($!); }
    has_vm_config ssh  && { prefix_run "ssh/pqc"        ssh  pqc       & BGPIDS+=($!); }
    [[ ${#BGPIDS[@]} -gt 0 ]] && wait "${BGPIDS[@]}" 2>/dev/null || true
elif [[ "$PROTO" == "all" ]]; then
    for _lp in tls mtls dtls quic ipsec ssh; do
        [[ "$_lp" == "dtls" && "$MODE" == "pqc" ]] && continue
        has_vm_config "$_lp" && { resolve_vm_config "$_lp"; print_lib_info "$_lp"; } || true
    done
    traffic_header
    for proto in tls mtls dtls quic ipsec ssh; do
        [[ "$proto" == "dtls" && "$MODE" == "pqc" ]] && continue
        if ! has_vm_config "$proto"; then continue; fi
        prefix_run "${proto}/${MODE}" "$proto" "$MODE" & BGPIDS+=($!)
    done
    [[ ${#BGPIDS[@]} -gt 0 ]] && wait "${BGPIDS[@]}" 2>/dev/null || true
elif [[ "$MODE" == "all" && "$PROTO" == "dtls" ]]; then
    # DTLS has no PQC mode; classical only
    log INFO "DTLS does not support PQC (DTLS 1.2 only). Running classical only."
    printf '\r\n'
    run_sequential dtls classical
elif [[ "$MODE" == "all" ]]; then
    print_lib_info "$PROTO"
    traffic_header
    prefix_run "${PROTO}/classical" "$PROTO" classical & BGPIDS+=($!)
    prefix_run "${PROTO}/pqc"       "$PROTO" pqc       & BGPIDS+=($!)
    wait "${BGPIDS[@]}" 2>/dev/null || true
else
    run_sequential "$PROTO" "$MODE"
fi
