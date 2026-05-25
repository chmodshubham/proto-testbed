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

# ---------------------------------------------------------------------------
# Env validation
# ---------------------------------------------------------------------------

[[ "$VM2_REPO" == "~"* ]] && { log ERROR "VM2_REPO must be an absolute path (no tilde). Edit env.sh."; exit 1; }

# ---------------------------------------------------------------------------
# Binary checks — only for the protocols being run
# ---------------------------------------------------------------------------

needs_openssl=0
needs_strongswan=0
needs_openssh=0

case "$PROTO" in
    tls|mtls|dtls|quic) needs_openssl=1 ;;
    ipsec)               needs_strongswan=1 ;;
    ssh)                 needs_openssh=1 ;;
    all)                 needs_openssl=1; needs_strongswan=1; needs_openssh=1 ;;
esac

if [[ $needs_openssl -eq 1 ]]; then
    OSSL="${REPO_ROOT}/os-lib/install/openssl-4.0/bin/openssl"
    if [[ ! -x "$OSSL" ]]; then
        log ERROR "OpenSSL 4.0 not found at: ${OSSL}"
        log ERROR "Build it first. See protocols/tls/README.md Steps 1-4."
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
    SSH_KEYS_MISSING=0
    [[ ! -f "${REPO_ROOT}/pki/out/ssh/classical/client-key" ]] && SSH_KEYS_MISSING=1
    [[ ! -f "${REPO_ROOT}/pki/out/ssh/pqc/client-key"       ]] && SSH_KEYS_MISSING=1
    if [[ $SSH_KEYS_MISSING -eq 1 ]]; then
        log ERROR "SSH keys not found under pki/out/ssh/."
        log ERROR "Generate them first: ./pki/gen.sh --proto ssh"
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
    PKI="${REPO_ROOT}/os-lib/install/strongswan/bin/pki"
    IPSEC_CERTS_MISSING=0
    [[ ! -f "${REPO_ROOT}/pki/out/ipsec/classical/server-cert.pem" ]] && IPSEC_CERTS_MISSING=1
    [[ ! -f "${REPO_ROOT}/pki/out/ipsec/pqc/server-cert.pem"       ]] && IPSEC_CERTS_MISSING=1
    if [[ $IPSEC_CERTS_MISSING -eq 1 ]]; then
        log ERROR "IPsec certificates not found under pki/out/ipsec/."
        log ERROR "Generate them first: ./pki/gen.sh --proto ipsec"
        log ERROR "Then sync to vm2:"
        log ERROR "  rsync -a --mkpath pki/out/ca/ipsec/ \$VM2_USER@\$VM2_HOST:\$VM2_REPO/pki/out/ca/ipsec/"
        log ERROR "  rsync -a --mkpath pki/out/ipsec/   \$VM2_USER@\$VM2_HOST:\$VM2_REPO/pki/out/ipsec/"
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
        ensure_apt_deps build-essential cmake pkg-config perl
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
        [[ -n "${VM2_PASSWORD:-}" ]] && ensure_apt_deps sshpass
        ;;
esac
# sshpass needed for all protocols when VM2_PASSWORD is set (management SSH)
if [[ -n "${VM2_PASSWORD:-}" ]]; then
    ensure_apt_deps sshpass
fi

# ---------------------------------------------------------------------------
# Sync repo to vm2 (excludes os-lib — binaries are built independently on each VM)
# ---------------------------------------------------------------------------

log INFO "Syncing repo to ${VM2_USER}@${VM2_HOST}:${VM2_REPO} ..."
rsync_vm2 -a --delete \
    --exclude='os-lib/' \
    --exclude='.git/' \
    "${REPO_ROOT}/" "${VM2_USER}@${VM2_HOST}:${VM2_REPO}/"
log INFO "Sync complete."
echo ""

# ---------------------------------------------------------------------------
# Pre-flight: kill stale servers on vm2 holding protocol ports
# ---------------------------------------------------------------------------

log INFO "Clearing stale servers on ${VM2_HOST} ..."
kill_vm2_ports "${PROTO}"
log INFO "Ports clear."
echo ""

# ---------------------------------------------------------------------------
# Cleanup: stop all servers on vm2 and client processes on vm1 on exit
# ---------------------------------------------------------------------------

BGPIDS=()
_CLEANED=0

# Suppress terminal echo so keystrokes don't appear in output during traffic loops.
# Restored in cleanup. Fails silently if not on a tty (e.g. piped output).
stty -echo 2>/dev/null || true

cleanup() {
    [[ $_CLEANED -eq 1 ]] && return
    _CLEANED=1
    stty echo 2>/dev/null || true
    echo ""
    log INFO "Stopping ..."
    # Forward SIGTERM to all prefix_run subshells; each forwards to its orchestrator,
    # whose trap kills the remote server on vm2.
    if [[ ${#BGPIDS[@]} -gt 0 ]]; then
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
        wait "${BGPIDS[@]}" 2>/dev/null || true
    fi
    # Belt-and-suspenders: kill any vm2 servers that orchestrator traps may have missed
    ssh_vm2 "${VM2_USER}@${VM2_HOST}" bash 2>/dev/null <<REMOTE || true
        pkill -f "s_server.*${PORT_TLS}"       2>/dev/null || true
        pkill -f "s_server.*${PORT_TLS_PQC}"   2>/dev/null || true
        pkill -f "s_server.*${PORT_MTLS}"      2>/dev/null || true
        pkill -f "s_server.*${PORT_MTLS_PQC}"  2>/dev/null || true
        pkill -f "protocols/dtls/server"       2>/dev/null || true
        pkill -f "protocols/quic/server"       2>/dev/null || true
        sudo pkill -f "libexec/ipsec/charon"   2>/dev/null || true
        sudo pkill -f "sshd.*${PORT_SSH}"      2>/dev/null || true
        sudo pkill -f "sshd.*${PORT_SSH_PQC}"  2>/dev/null || true
REMOTE
    sudo pkill -f "libexec/ipsec/charon" 2>/dev/null || true
    sudo ip xfrm policy flush 2>/dev/null || true
    sudo ip xfrm state flush  2>/dev/null || true
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
    echo ""
    log INFO "Traffic loop running. Press Ctrl-C to stop."
    echo ""
    printf "%-21s %-16s %-7s %-28s %-36s %s\n" "Timestamp" "Protocol" "Conn" "Key Exchange" "Cipher Suite" "Verify"
    printf "%-21s %-16s %-7s %-28s %-36s %s\n" "---------------------" "----------------" "-------" "----------------------------" "------------------------------------" "------"
}

# prefix_run <label> <proto> <mode> — run orchestrator with TESTBED_NO_HEADER=1 (header already printed)
# Runs orchestrator as a direct child (not inside a pipeline) so signals reach it.
prefix_run() {
    local label="$1" proto="$2" mode="$3"
    local fifo orch_pid
    fifo="$(mktemp -u /tmp/run-fifo-XXXXXX)"
    mkfifo "$fifo"
    cat < "$fifo" &
    local cat_pid=$!
    disown "$cat_pid" 2>/dev/null || true
    TESTBED_NO_HEADER=1 bash "${REPO_ROOT}/orchestrator/${proto}.sh" "$mode" < /dev/null > "$fifo" 2>&1 &
    orch_pid=$!
    # Forward SIGTERM/SIGINT to orchestrator so its cleanup trap fires
    trap "kill -TERM $orch_pid 2>/dev/null || true" TERM INT
    wait "$orch_pid" 2>/dev/null || true
    local rc=$?
    wait "$cat_pid" 2>/dev/null || true
    rm -f "$fifo"
    return $rc
}

run_sequential() {
    local proto="$1" mode="$2"
    log INFO "================================================================"
    log INFO "Protocol: ${proto}  |  Mode: ${mode}"
    log INFO "================================================================"
    echo ""
    bash "${REPO_ROOT}/orchestrator/${proto}.sh" "$mode"
}


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [[ "$PROTO" == "all" && "$MODE" == "all" ]]; then
    log INFO "IPsec: pqc mode only. Parallel classical+pqc unsupported: charon holds the kernel XFRM socket and policy, blocking a second instance."
    print_shared_header
    prefix_run "tls/classical"  tls  classical & BGPIDS+=($!)
    prefix_run "tls/pqc"        tls  pqc       & BGPIDS+=($!)
    prefix_run "mtls/classical" mtls classical & BGPIDS+=($!)
    prefix_run "mtls/pqc"       mtls pqc       & BGPIDS+=($!)
    prefix_run "quic/classical" quic classical & BGPIDS+=($!)
    prefix_run "quic/pqc"       quic pqc       & BGPIDS+=($!)
    prefix_run "dtls/classical" dtls classical & BGPIDS+=($!)
    prefix_run "ipsec/pqc"      ipsec pqc      & BGPIDS+=($!)
    prefix_run "ssh/classical"  ssh  classical & BGPIDS+=($!)
    prefix_run "ssh/pqc"        ssh  pqc       & BGPIDS+=($!)
    wait "${BGPIDS[@]}" 2>/dev/null || true
elif [[ "$PROTO" == "all" ]]; then
    print_shared_header
    for proto in tls mtls dtls quic ipsec ssh; do
        [[ "$proto" == "dtls" && "$MODE" == "pqc" ]] && continue
        prefix_run "${proto}/${MODE}" "$proto" "$MODE" & BGPIDS+=($!)
    done
    wait "${BGPIDS[@]}" 2>/dev/null || true
elif [[ "$MODE" == "all" && "$PROTO" == "dtls" ]]; then
    # DTLS has no PQC mode; classical only
    log INFO "DTLS does not support PQC (DTLS 1.2 only). Running classical only."
    echo ""
    run_sequential dtls classical
elif [[ "$MODE" == "all" ]]; then
    print_shared_header
    prefix_run "${PROTO}/classical" "$PROTO" classical & BGPIDS+=($!)
    prefix_run "${PROTO}/pqc"       "$PROTO" pqc       & BGPIDS+=($!)
    wait "${BGPIDS[@]}" 2>/dev/null || true
else
    run_sequential "$PROTO" "$MODE"
fi
