#!/usr/bin/env bash
# orchestrator/common.sh — shared helpers (sourced, not executed)
#
# Callers must set REPO_ROOT before sourcing this file.
# This file sets OSSL, PKI, and LD_LIBRARY_PATH derived from REPO_ROOT.

OSSL="${REPO_ROOT}/os-lib/install/openssl-4.0/bin/openssl"
PKI="${REPO_ROOT}/pki/out"
export LD_LIBRARY_PATH="${REPO_ROOT}/os-lib/install/openssl-4.0/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# Source env.sh if not already loaded (idempotent via guard variable)
if [[ -z "${_PROTO_ENV_LOADED:-}" && -f "${REPO_ROOT}/env.sh" ]]; then
    source "${REPO_ROOT}/env.sh"
    _PROTO_ENV_LOADED=1
fi

log() {
    # DEBUG lines are silent unless TESTBED_DEBUG=1 is set.
    [[ "$1" == "DEBUG" && "${TESTBED_DEBUG:-0}" != "1" ]] && return 0
    local ts
    printf -v ts '%(%Y-%m-%d %H:%M:%S)T' -1
    if [[ -n "${PROTO_TAG:-}" ]]; then
        printf '%-21s %-18s [%s] %s\r\n' "$ts" "[${PROTO_TAG}]" "$1" "$2"
    else
        printf '%-21s [%s] %s\r\n' "$ts" "$1" "$2"
    fi
}

# log_tty_state <stage> — DEBUG log of the live tty line-discipline flags at a
# stage boundary. Used to locate where output corruption (onlcr/opost cleared)
# begins. Silent unless TESTBED_DEBUG=1.
log_tty_state() {
    [[ "${TESTBED_DEBUG:-0}" != "1" ]] && return 0
    local flags
    flags="$(stty -a 2>/dev/null | grep -oE -- '-?onlcr|-?opost|-?icrnl' | tr '\n' ' ' || true)"
    log DEBUG "tty @ $1: ${flags:-no-tty}"
}

# check_openssh <readme_path>
check_openssh() {
    local openssh="${REPO_ROOT}/os-lib/install/openssh/bin/ssh"
    if [[ ! -x "$openssh" ]]; then
        log ERROR "OpenSSH binary not found: $openssh"
        log ERROR "Build OpenSSH first (see $1 Step 4)."
        exit 1
    fi
}

# ssh_vm2 [ssh-args...] — ssh to vm2; uses sshpass when VM2_PASSWORD is set.
# ConnectTimeout bounds the TCP connect; ServerAliveInterval/CountMax abort a
# session that stalls mid-command (e.g. an ipsec tunnel black-holing the route),
# so cleanup paths can never hang. Caller -o flags come after and override these.
SSH_TIMEOUT_OPTS=(-o ConnectTimeout=5 -o ServerAliveInterval=3 -o ServerAliveCountMax=2)
ssh_vm2() {
    if [[ -n "${VM2_PASSWORD:-}" ]]; then
        sshpass -p "$VM2_PASSWORD" ssh "${SSH_TIMEOUT_OPTS[@]}" "$@"
    else
        ssh "${SSH_TIMEOUT_OPTS[@]}" "$@"
    fi
}

# rsync_vm2 [rsync-args...] — rsync to/from vm2; uses sshpass when VM2_PASSWORD is set
rsync_vm2() {
    local rsh_opts="-o ConnectTimeout=5 -o ServerAliveInterval=3 -o ServerAliveCountMax=2"
    if [[ -n "${VM2_PASSWORD:-}" ]]; then
        RSYNC_RSH="sshpass -p '$VM2_PASSWORD' ssh $rsh_opts" rsync "$@"
    else
        RSYNC_RSH="ssh $rsh_opts" rsync "$@"
    fi
}

# ensure_apt_deps <pkg>... — install any missing apt packages; all output goes to stderr
ensure_apt_deps() {
    local missing=()
    for pkg in "$@"; do
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' || missing+=("$pkg")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log INFO "Installing missing packages: ${missing[*]} ..." >&2
        sudo apt-get install -y "${missing[@]}" >&2
    fi
}

# check_ossl <readme_path>
check_ossl() {
    if [[ ! -x "$OSSL" ]]; then
        log ERROR "OpenSSL binary not found: $OSSL"
        log ERROR "Build OpenSSL first (see $1 Step 4)."
        exit 1
    fi
}

# has_vm_config <proto> — return 0 if the minimum per-protocol VM vars are set, 1 otherwise.
# Use before resolve_vm_config when iterating all protocols so unconfigured ones are skipped.
has_vm_config() {
    local proto="$1"
    local p
    p="$(printf '%s' "$proto" | tr '[:lower:]' '[:upper:]')"
    local v1="${p}_VM1_IP" v2ip="${p}_VM2_IP" v2user="${p}_VM2_USER" v2host="${p}_VM2_HOST" v2repo="${p}_VM2_REPO"
    [[ -n "${!v1:-}" && -n "${!v2ip:-}" && -n "${!v2user:-}" && -n "${!v2host:-}" && -n "${!v2repo:-}" ]]
}

# resolve_vm_config <proto> — load the per-protocol VM variables for <proto> into
# the plain VM1_IP / VM2_IP / VM2_USER / VM2_HOST / VM2_REPO / VM2_PASSWORD names
# the rest of the testbed reads. <proto> is one of: tls mtls dtls quic ipsec ssh.
# There is no shared default; every <PROTO>_* variable must be set in env.sh.
resolve_vm_config() {
    local proto="$1"
    local p
    p="$(printf '%s' "$proto" | tr '[:lower:]' '[:upper:]')"
    local v1 v2ip v2user v2host v2repo
    v1="${p}_VM1_IP"
    v2ip="${p}_VM2_IP"
    v2user="${p}_VM2_USER"
    v2host="${p}_VM2_HOST"
    v2repo="${p}_VM2_REPO"
    VM1_IP="${!v1:?${v1} not set. Set per-protocol VM vars in env.sh.}"
    VM2_IP="${!v2ip:?${v2ip} not set. Set per-protocol VM vars in env.sh.}"
    VM2_USER="${!v2user:?${v2user} not set. Set per-protocol VM vars in env.sh.}"
    VM2_HOST="${!v2host:?${v2host} not set. Set per-protocol VM vars in env.sh.}"
    VM2_REPO="${!v2repo:?${v2repo} not set. Set per-protocol VM vars in env.sh.}"
    local v2pass="${p}_VM2_PASSWORD"
    VM2_PASSWORD="${!v2pass:-}"
    # Optional reverse-proxy backend URL, per protocol.
    # Set TLS_BACKEND_URL or QUIC_BACKEND_URL in env.sh; empty disables proxy mode.
    local v_burl="${p}_BACKEND_URL"
    PROXY_URL="${!v_burl:-}"
    export VM1_IP VM2_IP VM2_USER VM2_HOST VM2_REPO VM2_PASSWORD PROXY_URL
    if [[ "$VM2_REPO" == "~"* ]]; then
        log ERROR "${v2repo} must be an absolute path (no tilde). Edit env.sh."
        exit 1
    fi
}

# wait_tcp <port> <logfile> — poll until TCP port is open on vm2, or exit 1
wait_tcp() {
    local port="$1" logfile="$2"
    for i in {1..20}; do
        if ssh_vm2 "${VM2_USER}@${VM2_HOST}" "ss -tlnp | grep -q ${port}" 2>/dev/null; then
            if [[ "${TESTBED_NO_HEADER:-0}" != "1" ]]; then
                log INFO "Server is ready and accepting connections."
            fi
            return
        fi
        [[ $i -eq 20 ]] && { log ERROR "Server failed to start within 10s. Check ${logfile} on ${VM2_HOST}."; exit 1; }
        sleep 0.5
    done
}

# check_vm1_reach <port> [proto] — verify vm1 can open a TCP connection to the connect target:port.
# Target is NLB_HOST when set and proto is tls|mtls; otherwise VM2_IP.
# TCP only; QUIC and DTLS are UDP — no reachability check possible without an app-level reply.
# For QUIC with an NLB, the NLB must be configured as UDP passthrough (not TCP passthrough).
# Honors TESTBED_SKIP_REACH=1 to skip entirely.
check_vm1_reach() {
    local port="$1" proto="${2:-}"
    local target="$VM2_IP"
    case "$proto" in
        tls|mtls) target="${NLB_HOST:-$VM2_IP}" ;;
    esac
    [[ "${TESTBED_SKIP_REACH:-0}" == "1" ]] && return 0
    if ! timeout 3 bash -c "</dev/tcp/${target}/${port}" 2>/dev/null; then
        log ERROR "Cannot reach ${target}:${port}/tcp from vm1 within 3s."
        log ERROR "Check firewall rules on vm2 for port ${port}/tcp."
        exit 1
    fi
}

# check_backend <proto> — when proxy mode is on (BACKEND_URL set), verify
# that nginx on vm2 can open a TCP connection to the proxy backend. nginx connects
# to the backend, not vm1, so the probe runs from vm2 via SSH. Non-fatal: logs a
# clear warning if the backend is down so 502s are diagnosable, but does not abort
# the run (the handshake/traffic loop is still worth observing). No-op when proxy
# mode is off. Honors TESTBED_SKIP_REACH=1 to skip.
check_backend() {
    local proto="$1"
    [[ "${TESTBED_SKIP_REACH:-0}" == "1" ]] && return 0
    [[ -z "${PROXY_URL:-}" ]] && return 0   # proxy mode off
    local _url="${PROXY_URL#*://}"          # strip scheme
    local _hostport="${_url%%/*}"           # host:port (before first /)
    local _bhost="${_hostport%:*}"
    local _bport="${_hostport##*:}"
    local guard=""
    [[ "${TESTBED_NO_HEADER:-0}" == "1" ]] && guard="[${proto}] "
    if ssh_vm2 "${VM2_USER}@${VM2_HOST}" \
            "timeout 3 bash -c '</dev/tcp/${_bhost}/${_bport}'" 2>/dev/null; then
        log INFO "${guard}Backend reachable from ${VM2_HOST}: ${_bhost}:${_bport}/tcp."
    else
        log ERROR "${guard}Backend UNREACHABLE from ${VM2_HOST}: ${_bhost}:${_bport}/tcp."
        log ERROR "${guard}nginx will return 502. Check the backend is running and vm2 firewall allows ${_bport}/tcp."
    fi
}

# wait_proc <pattern> <logfile> — poll until process matching pattern exists on vm2, or exit 1
wait_proc() {
    local pattern="$1" logfile="$2"
    for i in {1..20}; do
        if ssh_vm2 "${VM2_USER}@${VM2_HOST}" "pgrep -f '${pattern}' > /dev/null" 2>/dev/null; then
            if [[ "${TESTBED_NO_HEADER:-0}" != "1" ]]; then
                log INFO "Server is ready and accepting connections."
            fi
            return
        fi
        [[ $i -eq 20 ]] && { log ERROR "Server failed to start within 10s. Check ${logfile} on ${VM2_HOST}."; exit 1; }
        sleep 0.5
    done
}

# kill_vm2_ports <proto> <mode> — kill any process on vm2 holding ports for proto/mode,
# flush xfrm state for ipsec, and wait 0.5s for sockets to release.
kill_vm2_ports() {
    local proto="$1"
    ssh_vm2 "${VM2_USER}@${VM2_HOST}" bash <<EOF 2>/dev/null || true
        cd "${VM2_REPO}" || exit 0
        source env.sh || exit 0
        case "${proto}" in
            tls)
                for _pf in ${VM2_REPO}/os-lib/install/nginx/logs/tls-nginx-classical.pid ${VM2_REPO}/os-lib/install/nginx/logs/tls-nginx-pqc.pid; do
                    [[ -f "\$_pf" ]] && kill "\$(cat "\$_pf")" 2>/dev/null || true
                done
                sudo fuser -k \${PORT_TLS}/tcp     > /dev/null 2>&1 || true
                sudo fuser -k \${PORT_TLS_PQC}/tcp > /dev/null 2>&1 || true
                pkill -f "nginx.*tls-nginx" > /dev/null 2>&1 || true
                ;;
            mtls)
                sudo fuser -k \${PORT_MTLS}/tcp     > /dev/null 2>&1 || true
                sudo fuser -k \${PORT_MTLS_PQC}/tcp > /dev/null 2>&1 || true
                pkill -f "s_server.*\${PORT_MTLS}"     > /dev/null 2>&1 || true
                pkill -f "s_server.*\${PORT_MTLS_PQC}" > /dev/null 2>&1 || true
                ;;
            dtls)
                sudo fuser -k \${PORT_DTLS}/udp > /dev/null 2>&1 || true
                pkill -f "protocols/dtls/server" > /dev/null 2>&1 || true
                ;;
            quic)
                for _pf in ${VM2_REPO}/os-lib/install/nginx/logs/quic-nginx-classical.pid ${VM2_REPO}/os-lib/install/nginx/logs/quic-nginx-pqc.pid; do
                    [[ -f "\$_pf" ]] && kill "\$(cat "\$_pf")" 2>/dev/null || true
                done
                sudo fuser -k \${PORT_QUIC}/udp     > /dev/null 2>&1 || true
                sudo fuser -k \${PORT_QUIC_PQC}/udp > /dev/null 2>&1 || true
                pkill -f "nginx.*quic-nginx" > /dev/null 2>&1 || true
                ;;
            ipsec)
                sudo fuser -k \${PORT_IPSEC}/udp     > /dev/null 2>&1 || true
                sudo fuser -k \${PORT_IPSEC_PQC}/udp > /dev/null 2>&1 || true
                sudo pkill -f "libexec/ipsec/charon" > /dev/null 2>&1 || true
                sudo ip xfrm policy flush > /dev/null 2>&1 || true
                sudo ip xfrm state flush  > /dev/null 2>&1 || true
                ;;
            ssh)
                [[ -n "\${PORT_SSH}" ]]     || exit 0
                [[ -n "\${PORT_SSH_PQC}" ]] || exit 0
                sudo fuser -k \${PORT_SSH}/tcp     > /dev/null 2>&1 || true
                sudo fuser -k \${PORT_SSH_PQC}/tcp > /dev/null 2>&1 || true
                pkill -f "sshd.*\${PORT_SSH}"     > /dev/null 2>&1 || true
                pkill -f "sshd.*\${PORT_SSH_PQC}" > /dev/null 2>&1 || true
                ;;
            all)
                for _pf in ${VM2_REPO}/os-lib/install/nginx/logs/tls-nginx-classical.pid ${VM2_REPO}/os-lib/install/nginx/logs/tls-nginx-pqc.pid \
                           ${VM2_REPO}/os-lib/install/nginx/logs/quic-nginx-classical.pid ${VM2_REPO}/os-lib/install/nginx/logs/quic-nginx-pqc.pid; do
                    [[ -f "\$_pf" ]] && kill "\$(cat "\$_pf")" 2>/dev/null || true
                done
                pkill -f "nginx.*tls-nginx"      > /dev/null 2>&1 || true
                pkill -f "nginx.*quic-nginx"     > /dev/null 2>&1 || true
                pkill -f "protocols/dtls/server" > /dev/null 2>&1 || true
                sudo pkill -f "libexec/ipsec/charon" > /dev/null 2>&1 || true
                sudo ip xfrm policy flush > /dev/null 2>&1 || true
                sudo ip xfrm state flush  > /dev/null 2>&1 || true
                if [[ -n "\${PORT_SSH}" && -n "\${PORT_SSH_PQC}" ]]; then
                    sudo fuser -k \${PORT_SSH}/tcp     > /dev/null 2>&1 || true
                    sudo fuser -k \${PORT_SSH_PQC}/tcp > /dev/null 2>&1 || true
                    pkill -f "sshd.*\${PORT_SSH}"     > /dev/null 2>&1 || true
                    pkill -f "sshd.*\${PORT_SSH_PQC}" > /dev/null 2>&1 || true
                fi
                ;;
        esac
        sleep 0.5
EOF
}

# nginx_alive_vm2 <proto> <mode> — exit 0 if the pidfile process is running on vm2.
# Used to reuse a persistent server instead of restarting it on every run.
# Note: passes -n so ssh does not read this caller's stdin (would EOF a while-read loop).
nginx_alive_vm2() {
    local proto="$1" mode="$2"
    ssh_vm2 -n "${VM2_USER}@${VM2_HOST}" "
        pf=${VM2_REPO}/os-lib/install/nginx/logs/${proto}-nginx-${mode}.pid
        [[ -f \"\$pf\" ]] && kill -0 \"\$(cat \"\$pf\")\" 2>/dev/null
    " 2>/dev/null
}

# nginx_proxy_stale_vm2 <proto> <mode> — exit 0 if the proxy config in env.sh
# differs from the stamp written when nginx last started. Callers that detect
# staleness should kill the running server so it restarts with the new config.
nginx_proxy_stale_vm2() {
    local proto="$1" mode="$2"
    local expected="${PROXY_URL:-}"
    local stamp
    stamp="$(ssh_vm2 -n "${VM2_USER}@${VM2_HOST}" \
        "cat ${VM2_REPO}/os-lib/install/nginx/conf/${proto}-nginx-${mode}.proxy 2>/dev/null || true" 2>/dev/null || true)"
    [[ "$stamp" != "$expected" ]]
}

# traffic_header — print column headers for the traffic table; suppressed when TESTBED_NO_HEADER=1
traffic_header() {
    if [[ "${TESTBED_NO_HEADER:-0}" == "1" ]]; then
        return
    fi
    printf '\r\n'
    log INFO "Traffic loop running. Press Ctrl-C to stop."
    printf '\r\n'
    printf "%-21s %-16s %-7s %-28s %-36s %s\r\n" "Timestamp" "Protocol" "Conn" "Key Exchange" "Cipher Suite" "Verify"
    printf "%-21s %-16s %-7s %-28s %-36s %s\r\n" "---------------------" "----------------" "-------" "----------------------------" "------------------------------------" "------"
}

# tls_flags <mode> — set TLS_VER_FLAG and CIPHER_FLAG for the given mode.
tls_flags() {
    if [[ "$1" == "classical" ]]; then
        TLS_VER_FLAG="-tls1_2"
        CIPHER_FLAG="-cipher"
    else
        TLS_VER_FLAG="-tls1_3"
        CIPHER_FLAG="-ciphersuites"
    fi
}

# print_row <result_string> <count> — parse s_client/dtls-client output and print one table row
print_row() {
    local result="$1" count="$2"
    local ts kex ciph verify
    printf -v ts '%(%Y-%m-%d %H:%M:%S)T' -1
    kex=$(    printf '%s' "$result" | grep -oE 'Temp Key: [^,]+|group: \S+' | sed 's/^Temp Key: //;s/^group: //' | head -1 || true)
    ciph=$(   printf '%s' "$result" | grep -oE 'Cipher is \S+'               | sed 's/^Cipher is //'             | head -1 || true)
    verify=$( printf '%s' "$result" | grep -oE 'Verify return code: [0-9]+'  | sed 's/^Verify return code: //'   | head -1 || true)
    printf "%-21s %-16s %-7s %-28s %-36s %s\r\n" "$ts" "${PROTO_TAG:-unknown}" "#${count}" "${kex:-unknown}" "${ciph:-unknown}" "${verify:-FAILED}"
}
