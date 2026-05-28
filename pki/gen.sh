#!/usr/bin/env bash
# pki/gen.sh — generate CA and leaf certificates for TLS / mTLS / DTLS / QUIC / IPsec / SSH
#
# Usage:
#   ./pki/gen.sh [--proto PROTO] [--mode MODE]
#   ./pki/gen.sh [PROTO [MODE]]            # positional fallback
#
#   PROTO: tls | mtls | dtls | all         (default: all)
#   MODE:  classical | pqc | all           (default: all)
#
# Examples:
#   ./pki/gen.sh                           # all protocols, both modes
#   ./pki/gen.sh tls                       # TLS only, both modes
#   ./pki/gen.sh tls classical             # TLS classical only
#   ./pki/gen.sh --proto mtls --mode pqc   # mTLS PQC only
#   ./pki/gen.sh --mode classical          # all protocols, classical only
#
# Run from repo root. Output lands in pki/out/ (gitignored).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OSSL="${REPO_ROOT}/os-lib/install/openssl-4.0/bin/openssl"

log() { printf '[%s] %s\n' "$1" "$2"; }

if [[ ! -x "$OSSL" ]]; then
    log ERROR "OpenSSL binary not found at: $OSSL"
    log ERROR "Complete the OpenSSL build before running this script (see protocols/tls/README.md Step 4)."
    exit 1
fi

export LD_LIBRARY_PATH="${REPO_ROOT}/os-lib/install/openssl-4.0/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

usage() {
    printf 'Usage: %s [--proto PROTO] [--mode MODE] [--help]\n' "$0"
    printf '       %s [PROTO [MODE]]\n\n' "$0"
    printf '  PROTO  tls | mtls | dtls | quic | ipsec | ssh | all   (default: all)\n'
    printf '  MODE   classical | pqc | all      (default: all)\n'
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

# Fill unset vars from positional args; reject extras.
if [[ ${#POSITIONAL[@]} -gt 0 && -z "$PROTO" ]]; then PROTO="${POSITIONAL[0]}"; POSITIONAL=("${POSITIONAL[@]:1}"); fi
if [[ ${#POSITIONAL[@]} -gt 0 && -z "$MODE"  ]]; then MODE="${POSITIONAL[0]}";  POSITIONAL=("${POSITIONAL[@]:1}"); fi
if [[ ${#POSITIONAL[@]} -gt 0 ]]; then
    log ERROR "Unexpected argument(s): ${POSITIONAL[*]}."; usage >&2; exit 1
fi

PROTO="${PROTO:-all}"
MODE="${MODE:-all}"

# Detect common proto/mode swap (e.g. gen.sh classical tls).
if [[ "$PROTO" == "classical" || "$PROTO" == "pqc" ]] && [[ "$MODE" == "tls" || "$MODE" == "mtls" || "$MODE" == "dtls" || "$MODE" == "quic" || "$MODE" == "ipsec" || "$MODE" == "ssh" || "$MODE" == "all" ]]; then
    log ERROR "Arguments look swapped: protocol='$PROTO' mode='$MODE'. Did you mean: --proto $MODE --mode $PROTO?"
    exit 1
fi

case "$PROTO" in tls|mtls|dtls|quic|ipsec|ssh|all) ;;
    *) log ERROR "Invalid protocol '$PROTO'. Valid values: tls, mtls, dtls, quic, ipsec, ssh, all."; usage >&2; exit 1 ;;
esac
case "$MODE" in classical|pqc|all) ;;
    *) log ERROR "Invalid mode '$MODE'. Valid values: classical, pqc, all."; usage >&2; exit 1 ;;
esac

if [[ "$PROTO" == "dtls" && "$MODE" == "pqc" ]]; then
    log ERROR "DTLS does not support PQC (DTLS 1.2 only; ML-KEM requires TLS 1.3)."
    exit 1
fi

if [[ "$PROTO" == "ssh" || "$PROTO" == "all" ]]; then
    SSH_KEYGEN_CHK="${REPO_ROOT}/os-lib/install/openssh/bin/ssh-keygen"
    if [[ ! -x "$SSH_KEYGEN_CHK" ]]; then
        log ERROR "ssh-keygen not found at: ${SSH_KEYGEN_CHK}"
        log ERROR "Build OpenSSH first. See protocols/ssh/README.md."
        exit 1
    fi
fi

if [[ "$PROTO" == "ipsec" || "$PROTO" == "all" ]]; then
    PKI_CHK="${REPO_ROOT}/os-lib/install/strongswan/bin/pki"
    if [[ ! -x "$PKI_CHK" ]]; then
        log ERROR "strongSwan pki not found at: ${PKI_CHK}"
        log ERROR "Build strongSwan first. See protocols/ipsec/README.md."
        exit 1
    fi
fi

BASE_CNF="$(mktemp --suffix=.cnf)"
trap 'rm -f "$BASE_CNF"' EXIT

set_proto_vm() {
    local proto="$1" p
    p="$(printf '%s' "$proto" | tr '[:lower:]' '[:upper:]')"
    local v1="${p}_VM1_IP" v2ip="${p}_VM2_IP" v2host="${p}_VM2_HOST"
    VM1_IP="${!v1:?${v1} not set. Set per-protocol VM vars in env.sh.}"
    VM2_IP="${!v2ip:?${v2ip} not set. Set per-protocol VM vars in env.sh.}"
    VM2_HOST="${!v2host:?${v2host} not set. Set per-protocol VM vars in env.sh.}"
    sed \
        -e "s|^IP\.1.*|IP.1  = ${VM2_IP}|" \
        -e "s|^DNS\.1.*|DNS.1 = ${VM2_HOST}|" \
        "${REPO_ROOT}/pki/ca.cnf" > "$BASE_CNF"
    if [[ -n "${NLB_HOST:-}" ]] && [[ "$proto" == "tls" || "$proto" == "mtls" || "$proto" == "quic" ]]; then
        sed -i "/^DNS\.1/a DNS.2 = ${NLB_HOST}" "$BASE_CNF"
    fi
}

# init_ca <ca_dir>
# Initialises the CA database under <ca_dir>/db/ and prints the cnf path.
# Writes the cnf once to <ca_dir>/db/openssl.cnf; reuses it on subsequent calls.
init_ca() {
    local ca_dir="$1"
    local db="${ca_dir}/db"
    mkdir -p "${db}/newcerts"
    [[ -f "${db}/index.txt" ]]      || touch "${db}/index.txt"
    [[ -f "${db}/serial" ]]         || printf '1000\n' > "${db}/serial"
    [[ -f "${db}/crlnumber" ]]      || printf '00\n'   > "${db}/crlnumber"
    [[ -f "${db}/index.txt.attr" ]] || printf 'unique_subject = no\n' > "${db}/index.txt.attr"

    local cnf="${db}/openssl.cnf"
    [[ -f "$cnf" ]] || sed "s|^dir .*|dir = ${db}|" "$BASE_CNF" > "$cnf"
    printf '%s' "$cnf"
}

# gen_ca <ca_dir> <algorithm> <cn> [extra_genpkey_opts...]
gen_ca() {
    local ca_dir="$1" algo="$2" cn="$3"
    shift 3
    local cnf
    cnf="$(init_ca "$ca_dir")"

    "$OSSL" genpkey -algorithm "$algo" "$@" -out "${ca_dir}/ca-key.pem" 2>/dev/null
    "$OSSL" req -new -x509 -key "${ca_dir}/ca-key.pem" \
        -out "${ca_dir}/ca-cert.pem" \
        -days 3650 \
        -subj "/CN=${cn}" \
        -config "$cnf" \
        -extensions v3_ca 2>/dev/null
}

# gen_leaf <leaf_dir> <ca_dir> <algorithm> <ext> <cn> [extra_genpkey_opts...]
# ext: server_cert | client_cert
gen_leaf() {
    local leaf_dir="$1" ca_dir="$2" algo="$3" ext="$4" cn="$5"
    shift 5
    mkdir -p "$leaf_dir"

    local role cnf csr
    [[ "$ext" == "client_cert" ]] && role="client" || role="server"
    cnf="$(init_ca "$ca_dir")"
    csr="$(mktemp --suffix=.csr)"
    trap 'rm -f "$csr"' RETURN

    "$OSSL" genpkey -algorithm "$algo" "$@" -out "${leaf_dir}/${role}-key.pem" 2>/dev/null
    "$OSSL" req -new -key "${leaf_dir}/${role}-key.pem" \
        -out "$csr" -subj "/CN=${cn}" -config "$cnf" 2>/dev/null
    "$OSSL" ca -batch -config "$cnf" -extensions "$ext" -days 3650 \
        -in "$csr" -out "${leaf_dir}/${role}-cert.pem" \
        -keyfile "${ca_dir}/ca-key.pem" -cert "${ca_dir}/ca-cert.pem" 2>/dev/null
    rm -f "$csr"
    trap - RETURN
}

gen_tls_classical() {
    local ca="${REPO_ROOT}/pki/out/ca/tls/classical"
    local leaf="${REPO_ROOT}/pki/out/tls/classical"
    mkdir -p "$ca" "$leaf"
    log INFO "TLS classical: generating CA (P-256) ..."
    gen_ca  "$ca"  EC         "Testbed TLS Classical CA" -pkeyopt ec_paramgen_curve:P-256
    log INFO "TLS classical: generating server leaf (P-256) ..."
    gen_leaf "$leaf" "$ca" EC server_cert vm2            -pkeyopt ec_paramgen_curve:P-256
    log INFO "TLS classical done."
    log INFO "  CA cert:     pki/out/ca/tls/classical/ca-cert.pem"
    log INFO "  Server cert: pki/out/tls/classical/server-cert.pem"
}

gen_tls_pqc() {
    local ca="${REPO_ROOT}/pki/out/ca/tls/pqc"
    local leaf="${REPO_ROOT}/pki/out/tls/pqc"
    mkdir -p "$ca" "$leaf"
    log INFO "TLS PQC: generating CA (ML-DSA-65) ..."
    gen_ca   "$ca"  ML-DSA-65 "Testbed TLS PQC CA"
    log INFO "TLS PQC: generating server leaf (ML-DSA-65) ..."
    gen_leaf "$leaf" "$ca" ML-DSA-65 server_cert vm2
    log INFO "TLS PQC done."
    log INFO "  CA cert:     pki/out/ca/tls/pqc/ca-cert.pem"
    log INFO "  Server cert: pki/out/tls/pqc/server-cert.pem"
}

gen_mtls_classical() {
    local ca="${REPO_ROOT}/pki/out/ca/mtls/classical"
    local leaf="${REPO_ROOT}/pki/out/mtls/classical"
    mkdir -p "$ca" "$leaf"
    log INFO "mTLS classical: generating CA (P-256) ..."
    gen_ca   "$ca"  EC         "Testbed mTLS Classical CA" -pkeyopt ec_paramgen_curve:P-256
    log INFO "mTLS classical: generating server leaf (P-384) ..."
    gen_leaf "$leaf" "$ca" EC  server_cert vm2             -pkeyopt ec_paramgen_curve:P-384
    log INFO "mTLS classical: generating client leaf (Ed448) ..."
    gen_leaf "$leaf" "$ca" ED448 client_cert vm1
    log INFO "mTLS classical done."
    log INFO "  CA cert:     pki/out/ca/mtls/classical/ca-cert.pem"
    log INFO "  Server cert: pki/out/mtls/classical/server-cert.pem"
    log INFO "  Client cert: pki/out/mtls/classical/client-cert.pem"
}

gen_mtls_pqc() {
    local ca="${REPO_ROOT}/pki/out/ca/mtls/pqc"
    local leaf="${REPO_ROOT}/pki/out/mtls/pqc"
    mkdir -p "$ca" "$leaf"
    log INFO "mTLS PQC: generating CA (ML-DSA-65) ..."
    gen_ca   "$ca"  ML-DSA-65  "Testbed mTLS PQC CA"
    log INFO "mTLS PQC: generating server leaf (ML-DSA-87) ..."
    gen_leaf "$leaf" "$ca" ML-DSA-87 server_cert vm2
    log INFO "mTLS PQC: generating client leaf (ML-DSA-44) ..."
    gen_leaf "$leaf" "$ca" ML-DSA-44 client_cert vm1
    log INFO "mTLS PQC done."
    log INFO "  CA cert:     pki/out/ca/mtls/pqc/ca-cert.pem"
    log INFO "  Server cert: pki/out/mtls/pqc/server-cert.pem"
    log INFO "  Client cert: pki/out/mtls/pqc/client-cert.pem"
}

gen_dtls_classical() {
    local ca="${REPO_ROOT}/pki/out/ca/dtls/classical"
    local leaf="${REPO_ROOT}/pki/out/dtls/classical"
    mkdir -p "$ca" "$leaf"
    log INFO "DTLS classical: generating CA (P-256) ..."
    gen_ca   "$ca"  EC         "Testbed DTLS Classical CA" -pkeyopt ec_paramgen_curve:P-256
    log INFO "DTLS classical: generating server leaf (P-521) ..."
    gen_leaf "$leaf" "$ca" EC server_cert vm2              -pkeyopt ec_paramgen_curve:P-521
    log INFO "DTLS classical done."
    log INFO "  CA cert:     pki/out/ca/dtls/classical/ca-cert.pem"
    log INFO "  Server cert: pki/out/dtls/classical/server-cert.pem"
}

gen_quic_classical() {
    local ca="${REPO_ROOT}/pki/out/ca/quic/classical"
    local leaf="${REPO_ROOT}/pki/out/quic/classical"
    mkdir -p "$ca" "$leaf"
    log INFO "QUIC classical: generating CA (Ed25519) ..."
    gen_ca   "$ca"  ED25519    "Testbed QUIC Classical CA"
    log INFO "QUIC classical: generating server leaf (Ed25519) ..."
    gen_leaf "$leaf" "$ca" ED25519 server_cert vm2
    log INFO "QUIC classical done."
    log INFO "  CA cert:     pki/out/ca/quic/classical/ca-cert.pem"
    log INFO "  Server cert: pki/out/quic/classical/server-cert.pem"
}

gen_ipsec_classical() {
    local ca="${REPO_ROOT}/pki/out/ca/ipsec/classical"
    local leaf="${REPO_ROOT}/pki/out/ipsec/classical"
    local PKI="${REPO_ROOT}/os-lib/install/strongswan/bin/pki"
    mkdir -p "$ca" "$leaf"

    log INFO "IPsec classical: generating CA (P-384) ..."
    "$PKI" --gen --type ecdsa --size 384 --outform pem > "${ca}/ca-key.pem"
    "$PKI" --self --ca --lifetime 3650 \
        --in "${ca}/ca-key.pem" --type priv \
        --dn "CN=Testbed IPsec Classical CA" \
        --outform pem > "${ca}/ca-cert.pem"

    log INFO "IPsec classical: generating server leaf (P-256) ..."
    "$PKI" --gen --type ecdsa --size 256 --outform pem > "${leaf}/server-key.pem"
    local csr
    csr="$(mktemp --suffix=.csr)"
    trap 'rm -f "$csr"' RETURN
    "$PKI" --req --type priv --in "${leaf}/server-key.pem" \
        --dn "CN=${VM2_HOST}" --outform pem > "$csr"
    "$PKI" --issue --lifetime 3650 \
        --cacert "${ca}/ca-cert.pem" --cakey "${ca}/ca-key.pem" \
        --in "$csr" --type pkcs10 \
        --san "${VM2_IP}" --san "${VM2_HOST}" \
        --flag serverAuth --flag ikeIntermediate \
        --outform pem > "${leaf}/server-cert.pem"
    rm -f "$csr"
    trap - RETURN

    log INFO "IPsec classical: generating client leaf (P-256) ..."
    "$PKI" --gen --type ecdsa --size 256 --outform pem > "${leaf}/client-key.pem"
    local csr2
    csr2="$(mktemp --suffix=.csr)"
    trap 'rm -f "$csr2"' RETURN
    "$PKI" --req --type priv --in "${leaf}/client-key.pem" \
        --dn "CN=vm1" --outform pem > "$csr2"
    "$PKI" --issue --lifetime 3650 \
        --cacert "${ca}/ca-cert.pem" --cakey "${ca}/ca-key.pem" \
        --in "$csr2" --type pkcs10 \
        --san "${VM1_IP}" --san "vm1" \
        --flag clientAuth \
        --outform pem > "${leaf}/client-cert.pem"
    rm -f "$csr2"
    trap - RETURN

    log INFO "IPsec classical done."
    log INFO "  CA cert:     pki/out/ca/ipsec/classical/ca-cert.pem"
    log INFO "  Server cert: pki/out/ipsec/classical/server-cert.pem"
    log INFO "  Client cert: pki/out/ipsec/classical/client-cert.pem"
}

gen_ipsec_pqc() {
    local ca="${REPO_ROOT}/pki/out/ca/ipsec/pqc"
    local leaf="${REPO_ROOT}/pki/out/ipsec/pqc"
    local PKI="${REPO_ROOT}/os-lib/install/strongswan/bin/pki"
    mkdir -p "$ca" "$leaf"

    log INFO "IPsec PQC: generating CA (P-384) ..."
    "$PKI" --gen --type ecdsa --size 384 --outform pem > "${ca}/ca-key.pem"
    "$PKI" --self --ca --lifetime 3650 \
        --in "${ca}/ca-key.pem" --type priv \
        --dn "CN=Testbed IPsec PQC CA" \
        --outform pem > "${ca}/ca-cert.pem"

    log INFO "IPsec PQC: generating server leaf (P-256) ..."
    "$PKI" --gen --type ecdsa --size 256 --outform pem > "${leaf}/server-key.pem"
    local csr
    csr="$(mktemp --suffix=.csr)"
    trap 'rm -f "$csr"' RETURN
    "$PKI" --req --type priv --in "${leaf}/server-key.pem" \
        --dn "CN=${VM2_HOST}" --outform pem > "$csr"
    "$PKI" --issue --lifetime 3650 \
        --cacert "${ca}/ca-cert.pem" --cakey "${ca}/ca-key.pem" \
        --in "$csr" --type pkcs10 \
        --san "${VM2_IP}" --san "${VM2_HOST}" \
        --flag serverAuth --flag ikeIntermediate \
        --outform pem > "${leaf}/server-cert.pem"
    rm -f "$csr"
    trap - RETURN

    log INFO "IPsec PQC: generating client leaf (P-256) ..."
    "$PKI" --gen --type ecdsa --size 256 --outform pem > "${leaf}/client-key.pem"
    local csr2
    csr2="$(mktemp --suffix=.csr)"
    trap 'rm -f "$csr2"' RETURN
    "$PKI" --req --type priv --in "${leaf}/client-key.pem" \
        --dn "CN=vm1" --outform pem > "$csr2"
    "$PKI" --issue --lifetime 3650 \
        --cacert "${ca}/ca-cert.pem" --cakey "${ca}/ca-key.pem" \
        --in "$csr2" --type pkcs10 \
        --san "${VM1_IP}" --san "vm1" \
        --flag clientAuth \
        --outform pem > "${leaf}/client-cert.pem"
    rm -f "$csr2"
    trap - RETURN

    log INFO "IPsec PQC done."
    log INFO "  CA cert:     pki/out/ca/ipsec/pqc/ca-cert.pem"
    log INFO "  Server cert: pki/out/ipsec/pqc/server-cert.pem"
    log INFO "  Client cert: pki/out/ipsec/pqc/client-cert.pem"
}

gen_quic_pqc() {
    local ca="${REPO_ROOT}/pki/out/ca/quic/pqc"
    local leaf="${REPO_ROOT}/pki/out/quic/pqc"
    mkdir -p "$ca" "$leaf"
    log INFO "QUIC PQC: generating CA (ML-DSA-44) ..."
    gen_ca   "$ca"  ML-DSA-44  "Testbed QUIC PQC CA"
    log INFO "QUIC PQC: generating server leaf (ML-DSA-65) ..."
    gen_leaf "$leaf" "$ca" ML-DSA-65 server_cert vm2
    log INFO "QUIC PQC done."
    log INFO "  CA cert:     pki/out/ca/quic/pqc/ca-cert.pem"
    log INFO "  Server cert: pki/out/quic/pqc/server-cert.pem"
}

gen_ssh_classical() {
    local SSHKEYGEN="${REPO_ROOT}/os-lib/install/openssh/bin/ssh-keygen"
    local out="${REPO_ROOT}/pki/out/ssh/classical"
    mkdir -p "$out"
    log INFO "SSH classical: generating host key (ed25519) ..."
    "$SSHKEYGEN" -t ed25519 -N "" -C "testbed-ssh-host" -f "${out}/host-key" -q
    log INFO "SSH classical: generating client auth key (ed25519) ..."
    "$SSHKEYGEN" -t ed25519 -N "" -C "testbed-ssh-client" -f "${out}/client-key" -q
    cp "${out}/client-key.pub" "${out}/authorized_keys"
    log INFO "SSH classical done."
    log INFO "  Host key:    pki/out/ssh/classical/host-key"
    log INFO "  Client key:  pki/out/ssh/classical/client-key"
}

gen_ssh_pqc() {
    local SSHKEYGEN="${REPO_ROOT}/os-lib/install/openssh/bin/ssh-keygen"
    local out="${REPO_ROOT}/pki/out/ssh/pqc"
    mkdir -p "$out"
    log INFO "SSH PQC: generating host key (ed25519) ..."
    "$SSHKEYGEN" -t ed25519 -N "" -C "testbed-ssh-host-pqc" -f "${out}/host-key" -q
    log INFO "SSH PQC: generating client auth key (ed25519) ..."
    "$SSHKEYGEN" -t ed25519 -N "" -C "testbed-ssh-client-pqc" -f "${out}/client-key" -q
    cp "${out}/client-key.pub" "${out}/authorized_keys"
    log INFO "SSH PQC done."
    log INFO "  Host key:    pki/out/ssh/pqc/host-key"
    log INFO "  Client key:  pki/out/ssh/pqc/client-key"
}

verify_certs() {
    log INFO "Verifying certificates ..."
    local pairs=(
        "pki/out/tls/classical/server-cert.pem:pki/out/ca/tls/classical/ca-cert.pem"
        "pki/out/tls/pqc/server-cert.pem:pki/out/ca/tls/pqc/ca-cert.pem"
        "pki/out/mtls/classical/server-cert.pem:pki/out/ca/mtls/classical/ca-cert.pem"
        "pki/out/mtls/classical/client-cert.pem:pki/out/ca/mtls/classical/ca-cert.pem"
        "pki/out/mtls/pqc/server-cert.pem:pki/out/ca/mtls/pqc/ca-cert.pem"
        "pki/out/mtls/pqc/client-cert.pem:pki/out/ca/mtls/pqc/ca-cert.pem"
        "pki/out/dtls/classical/server-cert.pem:pki/out/ca/dtls/classical/ca-cert.pem"
        "pki/out/quic/classical/server-cert.pem:pki/out/ca/quic/classical/ca-cert.pem"
        "pki/out/quic/pqc/server-cert.pem:pki/out/ca/quic/pqc/ca-cert.pem"
    )
    for pair in "${pairs[@]}"; do
        local cert="${REPO_ROOT}/${pair%%:*}"
        local ca="${REPO_ROOT}/${pair##*:}"
        [[ -f "$cert" ]] || continue
        "$OSSL" verify -CAfile "$ca" "$cert" >/dev/null 2>&1 \
            && log INFO "${cert##*/}: OK" || log ERROR "${cert##*/}: FAILED"
    done

    # IPsec certs are generated by strongSwan pki; verify with pki --verify.
    local PKI="${REPO_ROOT}/os-lib/install/strongswan/bin/pki"
    if [[ -x "$PKI" ]]; then
        local ipsec_pairs=(
            "pki/out/ipsec/classical/server-cert.pem:pki/out/ca/ipsec/classical/ca-cert.pem"
            "pki/out/ipsec/classical/client-cert.pem:pki/out/ca/ipsec/classical/ca-cert.pem"
            "pki/out/ipsec/pqc/server-cert.pem:pki/out/ca/ipsec/pqc/ca-cert.pem"
            "pki/out/ipsec/pqc/client-cert.pem:pki/out/ca/ipsec/pqc/ca-cert.pem"
        )
        for pair in "${ipsec_pairs[@]}"; do
            local cert="${REPO_ROOT}/${pair%%:*}"
            local ca="${REPO_ROOT}/${pair##*:}"
            [[ -f "$cert" ]] || continue
            "$PKI" --verify --in "$cert" --cacert "$ca" >/dev/null 2>&1 \
                && log INFO "${cert##*/}: OK" || log ERROR "${cert##*/}: FAILED"
        done
    fi
}

run_proto_mode() {
    local proto="$1" mode="$2"
    [[ "$proto" == "dtls" && "$mode" == "pqc" ]] && return
    set_proto_vm "$proto"
    "gen_${proto}_${mode}"
}

if [[ "$MODE" == "all" ]]; then
    if [[ "$PROTO" == "all" ]]; then
        for p in tls mtls dtls quic ipsec ssh; do
            run_proto_mode "$p" classical
            run_proto_mode "$p" pqc
        done
    else
        run_proto_mode "$PROTO" classical
        run_proto_mode "$PROTO" pqc
    fi
else
    if [[ "$PROTO" == "all" ]]; then
        for p in tls mtls dtls quic ipsec ssh; do run_proto_mode "$p" "$MODE"; done
    else
        run_proto_mode "$PROTO" "$MODE"
    fi
fi

verify_certs
log INFO "PKI generation complete."
