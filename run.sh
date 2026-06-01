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
needs_nginx=0
needs_strongswan=0
needs_openssh=0

case "$PROTO" in
    tls)           needs_openssl=1; needs_nginx=1 ;;
    mtls|dtls)     needs_openssl=1 ;;
    quic)          needs_openssl=1; needs_nginx=1 ;;
    ipsec)         needs_strongswan=1 ;;
    ssh)           needs_openssh=1 ;;
    all)           needs_openssl=1; needs_nginx=1; needs_strongswan=1; needs_openssh=1 ;;
esac

if [[ $needs_openssl -eq 1 ]]; then
    OSSL="${REPO_ROOT}/os-lib/install/openssl-4.0/bin/openssl"
    if [[ ! -x "$OSSL" ]]; then
        log ERROR "OpenSSL 4.0 not found at: ${OSSL}"
        log ERROR "Build it first: bash lib-setup.sh"
        exit 1
    fi
fi

if [[ $needs_nginx -eq 1 ]]; then
    NGINX_CHK="${REPO_ROOT}/os-lib/install/nginx/sbin/nginx"
    if [[ ! -x "$NGINX_CHK" ]]; then
        log ERROR "nginx not found at: ${NGINX_CHK}"
        log ERROR "Build it first: bash lib-setup.sh"
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

    log INFO "Clearing stale servers on ${VM2_HOST} (${proto}) ..."
    kill_vm2_ports "${proto}"
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
    # Belt-and-suspenders: for each prepared protocol, resolve its vm2 and kill any
    # servers the orchestrator traps may have missed on that protocol's ports.
    local cp
    for cp in "${PREPARED_PROTOS[@]}"; do
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

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

# print_shared_header — print the single traffic table header used in parallel mode
print_shared_header() {
    printf '\r\n'
    log INFO "Traffic loop running. Press Ctrl-C to stop."
    printf '\r\n'
    printf "%-21s %-16s %-7s %-28s %-36s %s\r\n" "Timestamp" "Protocol" "Conn" "Key Exchange" "Cipher Suite" "Verify"
    printf "%-21s %-16s %-7s %-28s %-36s %s\r\n" "---------------------" "----------------" "-------" "----------------------------" "------------------------------------" "------"
}

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

run_sequential() {
    local proto="$1" mode="$2"
    log INFO "================================================================"
    log INFO "Protocol: ${proto}  |  Mode: ${mode}"
    log INFO "================================================================"
    printf '\r\n'
    bash "${REPO_ROOT}/orchestrator/${proto}.sh" "$mode"
}


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

set +m
if [[ "$PROTO" == "all" && "$MODE" == "all" ]]; then
    log INFO "IPsec: pqc mode only. Parallel classical+pqc unsupported: charon holds the kernel XFRM socket and policy, blocking a second instance."
    print_shared_header
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
    print_shared_header
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
    print_shared_header
    prefix_run "${PROTO}/classical" "$PROTO" classical & BGPIDS+=($!)
    prefix_run "${PROTO}/pqc"       "$PROTO" pqc       & BGPIDS+=($!)
    wait "${BGPIDS[@]}" 2>/dev/null || true
else
    run_sequential "$PROTO" "$MODE"
fi
