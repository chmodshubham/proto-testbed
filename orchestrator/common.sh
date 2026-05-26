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
    local ts
    printf -v ts '%(%Y-%m-%d %H:%M:%S)T' -1
    if [[ -n "${PROTO_TAG:-}" ]]; then
        printf '%-21s %-18s [%s] %s\n' "$ts" "[${PROTO_TAG}]" "$1" "$2"
    else
        printf '%-21s [%s] %s\n' "$ts" "$1" "$2"
    fi
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

# ssh_vm2 [ssh-args...] — ssh to vm2; uses sshpass when VM2_PASSWORD is set
ssh_vm2() {
    if [[ -n "${VM2_PASSWORD:-}" ]]; then
        sshpass -p "$VM2_PASSWORD" ssh "$@"
    else
        ssh "$@"
    fi
}

# rsync_vm2 [rsync-args...] — rsync to/from vm2; uses sshpass when VM2_PASSWORD is set
rsync_vm2() {
    if [[ -n "${VM2_PASSWORD:-}" ]]; then
        RSYNC_RSH="sshpass -p '$VM2_PASSWORD' ssh" rsync "$@"
    else
        rsync "$@"
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

# check_env — validate required VM2_* vars are set and VM2_REPO is absolute
check_env() {
    VM2_USER="${VM2_USER:?VM2_USER not set. Source env.sh from repo root.}"
    VM2_HOST="${VM2_HOST:?VM2_HOST not set. Source env.sh from repo root.}"
    VM2_REPO="${VM2_REPO:?VM2_REPO not set. Source env.sh from repo root.}"
    if [[ "$VM2_REPO" == "~"* ]]; then
        log ERROR "VM2_REPO must be an absolute path (no tilde). Edit env.sh."
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

# check_vm1_reach <port> — verify vm1 can open a TCP connection to VM2_IP:port.
# TCP only; UDP reachability cannot be confirmed without an app-level reply.
# Honors TESTBED_SKIP_REACH=1 to skip entirely.
check_vm1_reach() {
    local port="$1"
    [[ "${TESTBED_SKIP_REACH:-0}" == "1" ]] && return 0
    if ! timeout 3 bash -c "</dev/tcp/${VM2_IP}/${port}" 2>/dev/null; then
        log ERROR "Cannot reach ${VM2_IP}:${port}/tcp from vm1 within 3s."
        log ERROR "Check firewall rules on vm2 for port ${port}/tcp."
        exit 1
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
                sudo fuser -k \${PORT_TLS}/tcp     > /dev/null 2>&1 || true
                sudo fuser -k \${PORT_TLS_PQC}/tcp > /dev/null 2>&1 || true
                pkill -f "s_server.*\${PORT_TLS}"     > /dev/null 2>&1 || true
                pkill -f "s_server.*\${PORT_TLS_PQC}" > /dev/null 2>&1 || true
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
                sudo fuser -k \${PORT_QUIC}/udp     > /dev/null 2>&1 || true
                sudo fuser -k \${PORT_QUIC_PQC}/udp > /dev/null 2>&1 || true
                pkill -f "protocols/quic/server" > /dev/null 2>&1 || true
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
                pkill -f "s_server"              > /dev/null 2>&1 || true
                pkill -f "protocols/dtls/server" > /dev/null 2>&1 || true
                pkill -f "protocols/quic/server" > /dev/null 2>&1 || true
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

# traffic_header — print column headers for the traffic table; suppressed when TESTBED_NO_HEADER=1
traffic_header() {
    stty -echo 2>/dev/null || true
    if [[ "${TESTBED_NO_HEADER:-0}" == "1" ]]; then
        return
    fi
    echo ""
    log INFO "Traffic loop running. Press Ctrl-C to stop."
    echo ""
    printf "%-21s %-16s %-7s %-28s %-36s %s\n" "Timestamp" "Protocol" "Conn" "Key Exchange" "Cipher Suite" "Verify"
    printf "%-21s %-16s %-7s %-28s %-36s %s\n" "---------------------" "----------------" "-------" "----------------------------" "------------------------------------" "------"
}

# print_row <result_string> <count> — parse s_client/dtls-client output and print one table row
print_row() {
    local result="$1" count="$2"
    local ts kex ciph verify
    printf -v ts '%(%Y-%m-%d %H:%M:%S)T' -1
    kex=$(    printf '%s' "$result" | grep -oE 'Temp Key: [^,]+|group: \S+' | sed 's/^Temp Key: //;s/^group: //' | head -1 || true)
    ciph=$(   printf '%s' "$result" | grep -oE 'Cipher is \S+'               | sed 's/^Cipher is //'             | head -1 || true)
    verify=$( printf '%s' "$result" | grep -oE 'Verify return code: [0-9]+'  | sed 's/^Verify return code: //'   | head -1 || true)
    printf "%-21s %-16s %-7s %-28s %-36s %s\n" "$ts" "${PROTO_TAG:-unknown}" "#${count}" "${kex:-unknown}" "${ciph:-unknown}" "${verify:-FAILED}"
}
