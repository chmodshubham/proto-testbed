#!/usr/bin/env bash
# protocols/ipsec/server.sh — start charon IKEv2 server for one mode
#
# Usage: bash protocols/ipsec/server.sh [classical|pqc]
# Run on vm2 from repo root after sourcing env.sh.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "${REPO_ROOT}/orchestrator/common.sh"

MODE="${1:-pqc}"
source "${REPO_ROOT}/protocols/ipsec/config.sh" "$MODE"

log INFO "Mode:               $MODE"
log INFO "Listening on:       ${VM2_IP}:${IPSEC_PORT} (UDP)"
log INFO "IKE proposals:      $IPSEC_IKE_PROPOSALS"
log INFO "ESP proposals:      $IPSEC_ESP_PROPOSALS"
log INFO "CA certificate:     $IPSEC_CA"
echo ""

VICI_SOCK="/tmp/charon-ipsec-${MODE}.vici"
CHARON_PID="/tmp/charon-ipsec-${MODE}.pid"
CHARON_LOG="/tmp/ipsec-server-${MODE}.log"
CONF_DIR="$(mktemp -d /tmp/ipsec-server-${MODE}-conf.XXXXXX)"

cleanup() {
    local pid
    if [[ -f "$CHARON_PID" ]]; then
        pid="$(cat "$CHARON_PID" 2>/dev/null || true)"
        [[ -n "$pid" ]] && sudo kill "$pid" 2>/dev/null || true
        rm -f "$CHARON_PID"
    fi
    sudo ip xfrm policy flush 2>/dev/null || true
    sudo ip xfrm state flush  2>/dev/null || true
    rm -rf "$CONF_DIR"
}
trap cleanup EXIT INT TERM

SWAN_CONF="${CONF_DIR}/strongswan.conf"
cat > "$SWAN_CONF" <<EOF
charon {
    load_modular = yes
    port         = ${IPSEC_PORT}
    port_nat_t   = 0
    plugins {
        include ${STRONGSWAN}/etc/strongswan.d/charon/*.conf
        vici {
            load = yes
            socket = unix://${VICI_SOCK}
        }
    }
    filelog {
        charon {
            path = ${CHARON_LOG}
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
EOF

# swanctl_dir is set to dirname of the --file path passed to swanctl.
# Placing swanctl.conf here causes --load-creds to scan x509/, private/, x509ca/ siblings.
SWANCTL_CONF="${CONF_DIR}/swanctl/swanctl.conf"
mkdir -p "${CONF_DIR}/swanctl/x509" \
         "${CONF_DIR}/swanctl/private" \
         "${CONF_DIR}/swanctl/x509ca"
cp "$IPSEC_SERVER_CERT" "${CONF_DIR}/swanctl/x509/server-cert.pem"
cp "$IPSEC_SERVER_KEY"  "${CONF_DIR}/swanctl/private/server-key.pem"
cp "$IPSEC_CA"          "${CONF_DIR}/swanctl/x509ca/ca-cert.pem"

cat > "$SWANCTL_CONF" <<EOF
connections {
    ${IPSEC_CONN} {
        version = 2
        local_addrs  = ${VM2_IP}
        remote_addrs = %any
        local_port   = ${IPSEC_PORT}
        proposals    = ${IPSEC_IKE_PROPOSALS}

        local {
            auth = pubkey
            id   = ${VM2_IP}
        }
        remote {
            auth = pubkey
            id   = ${VM1_IP}
        }

        children {
            ${IPSEC_CONN} {
                esp_proposals = ${IPSEC_ESP_PROPOSALS}
                local_ts      = ${VM2_IP}/32
                remote_ts     = ${VM1_IP}/32
                mode          = tunnel
                start_action  = none
                close_action  = none
                dpd_action    = clear
            }
        }

        dpd_delay  = 30s
        rekey_time = 1h
    }
}
EOF

log INFO "Starting charon (${MODE}, port ${IPSEC_PORT}) ..."
sudo STRONGSWAN_CONF="$SWAN_CONF" \
    LD_LIBRARY_PATH="${STRONGSWAN}/lib/ipsec" \
    "${CHARON}" &
CHARON_PID_VAL=$!
echo "$CHARON_PID_VAL" > "$CHARON_PID"

READY=0
for i in $(seq 1 40); do
    if sudo env LD_LIBRARY_PATH="${STRONGSWAN}/lib/ipsec" \
        "$SWANCTL" --uri "unix://${VICI_SOCK}" --list-algs > /dev/null 2>&1; then
        READY=1; break
    fi
    sleep 0.5
done
[[ "$READY" -eq 1 ]] || { log ERROR "charon vici not accepting connections after 20s."; exit 1; }

sw() { sudo env LD_LIBRARY_PATH="${STRONGSWAN}/lib/ipsec" "${SWANCTL}" --uri "unix://${VICI_SOCK}" "$@"; }

sw --load-creds --noprompt --file "${SWANCTL_CONF}"
sw --load-conns --file "${SWANCTL_CONF}"
log INFO "Server ready. Mode: ${MODE}  Port: ${IPSEC_PORT}"

wait "$CHARON_PID_VAL"
