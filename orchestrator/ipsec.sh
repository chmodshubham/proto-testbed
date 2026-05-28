#!/usr/bin/env bash
# orchestrator/ipsec.sh — start IPsec server on vm2 and client charon on vm1, loop traffic
#
# Usage: bash orchestrator/ipsec.sh [classical|pqc]
# Run from repo root on vm1 after sourcing env.sh.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${REPO_ROOT}/orchestrator/common.sh"

resolve_vm_config ipsec

MODE="${1:-pqc}"

source "${REPO_ROOT}/protocols/ipsec/config.sh"
PROTO_TAG="ipsec/${MODE}"

STRONGSWAN_LOCAL="${REPO_ROOT}/os-lib/install/strongswan"
if [[ ! -x "${STRONGSWAN_LOCAL}/sbin/swanctl" ]]; then
    log ERROR "strongSwan not found at: ${STRONGSWAN_LOCAL}"
    log ERROR "Build strongSwan first. See protocols/ipsec/README.md."
    exit 1
fi

if [[ "${TESTBED_NO_HEADER:-0}" != "1" ]]; then
    log INFO "Mode:               $MODE"
    log INFO "Server address:     ${VM2_IP}:${IPSEC_PORT} (UDP)"
    log INFO "IKE proposals:      $IPSEC_IKE_PROPOSALS"
    log INFO "ESP proposals:      $IPSEC_ESP_PROPOSALS"
    log INFO "CA certificate:     $IPSEC_CA"
    printf '\r\n'
fi

# ---------------------------------------------------------------------------
# Server on vm2
# ---------------------------------------------------------------------------

if [[ "${TESTBED_NO_HEADER:-0}" != "1" ]]; then log INFO "Starting IPsec server (${MODE}) on ${VM2_HOST} ..."; fi

ssh_vm2 "${VM2_USER}@${VM2_HOST}" bash <<EOF
    sudo pkill -f charon 2>/dev/null || true
    sleep 0.5
    cd ${VM2_REPO}
    source env.sh
    nohup bash protocols/ipsec/server.sh ${MODE} > /tmp/ipsec-server-${MODE}.log 2>&1 &
EOF

for i in $(seq 1 30); do
    if ssh_vm2 "${VM2_USER}@${VM2_HOST}" \
        "pgrep -f 'libexec/ipsec/charon' > /dev/null 2>&1" 2>/dev/null; then
        if [[ "${TESTBED_NO_HEADER:-0}" != "1" ]]; then log INFO "Server is ready and accepting connections."; fi
        break
    fi
    if [[ $i -eq 30 ]]; then
        log ERROR "Server failed to start within 15s. Check /tmp/ipsec-server-${MODE}.log on ${VM2_HOST}."
        exit 1
    fi
    sleep 0.5
done

# ---------------------------------------------------------------------------
# Client charon on vm1 (stays resident; we re-initiate per connection)
# ---------------------------------------------------------------------------

CLIENT_VICI="/tmp/charon-ipsec-client-${MODE}.vici"
CLIENT_PID_FILE="/tmp/charon-ipsec-client-${MODE}.pid"
CLIENT_CONF_DIR="$(mktemp -d /tmp/ipsec-client-${MODE}-conf.XXXXXX)"

_STOP=0
# Fast signal handler: just flag the loop to stop. The first Ctrl-C interrupts a
# blocking swanctl call; the loop's _STOP check then breaks immediately. Cleanup
# runs once on EXIT, so a single Ctrl-C is enough to stop.
request_stop() { _STOP=1; }

_CLEANED=0
client_cleanup() {
    [[ $_CLEANED -eq 1 ]] && return
    _CLEANED=1
    _STOP=1
    if [[ -f "$CLIENT_PID_FILE" ]]; then
        local pid
        pid="$(cat "$CLIENT_PID_FILE" 2>/dev/null || true)"
        [[ -n "$pid" ]] && sudo kill "$pid" 2>/dev/null || true
        rm -f "$CLIENT_PID_FILE"
    fi
    sudo ip xfrm policy flush 2>/dev/null || true
    sudo ip xfrm state flush  2>/dev/null || true
    rm -rf "$CLIENT_CONF_DIR"
    # also stop server on vm2
    ssh_vm2 "${VM2_USER}@${VM2_HOST}" "sudo pkill -f charon 2>/dev/null || true" 2>/dev/null || true
}
trap request_stop INT TERM
trap client_cleanup EXIT

SWAN_CONF="${CLIENT_CONF_DIR}/strongswan.conf"
cat > "$SWAN_CONF" <<SCONF
charon {
    load_modular = yes
    port         = ${IPSEC_PORT}
    port_nat_t   = 0
    plugins {
        include ${STRONGSWAN}/etc/strongswan.d/charon/*.conf
        vici {
            load = yes
            socket = unix://${CLIENT_VICI}
        }
    }
    filelog {
        charon {
            path = /tmp/ipsec-client-${MODE}.log
            time_format = %Y-%m-%d %H:%M:%S
            ike_name = yes
            default = 1
        }
    }
    syslog {
        daemon {
            default = -1
        }
    }
}
SCONF

SWANCTL_CONF="${CLIENT_CONF_DIR}/swanctl/swanctl.conf"
mkdir -p "${CLIENT_CONF_DIR}/swanctl/x509" \
         "${CLIENT_CONF_DIR}/swanctl/private" \
         "${CLIENT_CONF_DIR}/swanctl/x509ca"
cp "$IPSEC_CLIENT_CERT" "${CLIENT_CONF_DIR}/swanctl/x509/client-cert.pem"
cp "$IPSEC_CLIENT_KEY"  "${CLIENT_CONF_DIR}/swanctl/private/client-key.pem"
cp "$IPSEC_CA"          "${CLIENT_CONF_DIR}/swanctl/x509ca/ca-cert.pem"

cat > "$SWANCTL_CONF" <<SCONF
connections {
    ${IPSEC_CONN} {
        version = 2
        local_addrs   = ${VM1_IP}
        remote_addrs  = ${VM2_IP}
        remote_port   = ${IPSEC_PORT}
        proposals     = ${IPSEC_IKE_PROPOSALS}

        local {
            auth = pubkey
            id   = ${VM1_IP}
        }
        remote {
            auth = pubkey
            id   = ${VM2_IP}
        }

        children {
            ${IPSEC_CONN} {
                esp_proposals = ${IPSEC_ESP_PROPOSALS}
                local_ts      = ${VM1_IP}/32
                remote_ts     = ${VM2_IP}/32
                mode          = tunnel
                start_action  = none
                close_action  = none
                dpd_action    = clear
            }
        }

        dpd_delay  = 0s
        rekey_time = 4h
    }
}
SCONF

log_tty_state "before charon start"
if [[ "${TESTBED_NO_HEADER:-0}" != "1" ]]; then log INFO "Starting client charon on vm1 ..."; fi
# Detach charon stdio from the tty; it logs via the filelog config above.
sudo STRONGSWAN_CONF="$SWAN_CONF" \
    LD_LIBRARY_PATH="${STRONGSWAN}/lib/ipsec" \
    "${CHARON}" </dev/null >/dev/null 2>&1 &
CHARON_PID=$!
echo "$CHARON_PID" > "$CLIENT_PID_FILE"
log_tty_state "after charon start"

READY=0
for i in $(seq 1 60); do
    if sudo env LD_LIBRARY_PATH="${STRONGSWAN}/lib/ipsec" \
        "$SWANCTL" --uri "unix://${CLIENT_VICI}" --list-algs > /dev/null 2>&1; then
        READY=1; break
    fi
    sleep 0.3
done
[[ "$READY" -eq 1 ]] || { log ERROR "Client charon not ready after 18s."; exit 1; }
log_tty_state "after readiness poll"

sw() { sudo env LD_LIBRARY_PATH="${STRONGSWAN}/lib/ipsec" "${SWANCTL}" --uri "unix://${CLIENT_VICI}" "$@"; }

sw --load-creds --noprompt --file "${SWANCTL_CONF}" > /dev/null 2>&1
sw --load-conns --file "${SWANCTL_CONF}" > /dev/null 2>&1
log_tty_state "after load-creds/conns"
if [[ "${TESTBED_NO_HEADER:-0}" != "1" ]]; then log INFO "Client charon ready."; fi

# ---------------------------------------------------------------------------
# Traffic loop
# ---------------------------------------------------------------------------

log_tty_state "before traffic_header"
traffic_header

set +m
COUNT=0
while [[ $_STOP -eq 0 ]]; do
    log_tty_state "loop top (#$((COUNT + 1)))"
    sw --initiate --child "${IPSEC_CONN}" --timeout 15 > /dev/null 2>&1 || true
    log_tty_state "after sw --initiate"
    [[ $_STOP -eq 0 ]] || break

    SA_OUT=""
    for _i in 1 2 3; do
        SA_OUT=$(sw --list-sas 2>/dev/null || true)
        printf '%s\n' "$SA_OUT" | grep -q "ESTABLISHED" && break
        sleep 0.3
    done
    log_tty_state "after sw --list-sas"

    [[ $_STOP -eq 0 ]] || break
    COUNT=$((COUNT + 1))
    printf -v TS '%(%Y-%m-%d %H:%M:%S)T' -1

    IKE_GRP=$(  printf '%s\n' "$SA_OUT" | grep -E '^  [A-Z_0-9-]+/[A-Z_0-9/-]+' | sed 's/^  //' | grep -oE '[^/]+$' | head -1 || true)
    ESP=$(      printf '%s\n' "$SA_OUT" | grep -oE 'ESP:(AES|CHACHA)[_A-Z0-9-]+' | sed 's/^ESP://' | head -1 || true)
    AUTH_OK=$(  printf '%s\n' "$SA_OUT" | grep -c "ESTABLISHED" || true)
    if [[ "$AUTH_OK" -gt 0 ]] && ping -c1 -W2 "${VM2_IP}" > /dev/null 2>&1; then
        VERIFY=0
    else
        VERIFY=1
    fi

    log_tty_state "before printf row"
    printf "%-21s %-16s %-7s %-28s %-36s %s\r\n" \
        "$TS" "${PROTO_TAG:-ipsec}" "#${COUNT}" "${IKE_GRP:--}" "${ESP:--}" "$VERIFY"

    sleep 2
    sw --terminate --ike "${IPSEC_CONN}" > /dev/null 2>&1 || true
    log_tty_state "after sw --terminate"
    sleep 0.3
done
