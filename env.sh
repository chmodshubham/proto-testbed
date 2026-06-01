# env.sh — testbed environment configuration
#
# Source from the repo root before running any script or command:
#
#   cd /path/to/proto-testbed
#   source env.sh
#
# All scripts guard against missing variables with ${VAR:?...} and will
# fail immediately if this file was not sourced.

if [[ ! -f "pki/gen.sh" ]]; then
    printf 'ERROR: source env.sh from the repo root (the directory containing pki/, protocols/, etc.)\n' >&2
    return 1
fi

# ---------------------------------------------------------------------------
# Build toolchain
# ---------------------------------------------------------------------------

export LD_LIBRARY_PATH="$(pwd)/os-lib/install/openssl-4.0/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PATH="$(pwd)/os-lib/install/nginx/sbin${PATH:+:$PATH}"

# ---------------------------------------------------------------------------
# Per-protocol VM topology
# ---------------------------------------------------------------------------
# Each protocol connects to its own pair of VMs. There is no shared default:
# the protocol you run reads only its own <PROTO>_* variables. resolve_vm_config
# in orchestrator/common.sh maps these onto VM1_IP / VM2_IP / VM2_USER /
# VM2_HOST / VM2_REPO / VM2_PASSWORD for the running protocol.
#
# For each protocol set all six variables:
#   <PROTO>_VM1_IP        client IP (vm1)
#   <PROTO>_VM2_IP        server IP (vm2), connect target and cert SAN
#   <PROTO>_VM2_USER      SSH login user on vm2
#   <PROTO>_VM2_HOST      SSH host for vm2 (DNS or IP)
#   <PROTO>_VM2_REPO      absolute repo path on vm2 (no tilde)
#   <PROTO>_VM2_PASSWORD  vm2 SSH password; empty for key-based auth
#
# PROTO is one of: TLS MTLS DTLS QUIC IPSEC SSH

# TLS
export TLS_VM1_IP="10.141.230.126"
export TLS_VM2_IP="10.141.230.126"
export TLS_VM2_USER=ubuntu
export TLS_VM2_HOST="localhost"
export TLS_VM2_REPO="/home/ubuntu/proto-testbed"
export TLS_VM2_PASSWORD=""

# mTLS
export MTLS_VM1_IP=""
export MTLS_VM2_IP=""
export MTLS_VM2_USER=ubuntu
export MTLS_VM2_HOST=""
export MTLS_VM2_REPO="/home/ubuntu/proto-testbed"
export MTLS_VM2_PASSWORD=""

# DTLS
export DTLS_VM1_IP=""
export DTLS_VM2_IP=""
export DTLS_VM2_USER=ubuntu
export DTLS_VM2_HOST=""
export DTLS_VM2_REPO="/home/ubuntu/proto-testbed"
export DTLS_VM2_PASSWORD=""

# QUIC
export QUIC_VM1_IP="10.141.230.126"
export QUIC_VM2_IP="10.141.230.126"
export QUIC_VM2_USER=ubuntu
export QUIC_VM2_HOST="localhost"
export QUIC_VM2_REPO="/home/ubuntu/proto-testbed"
export QUIC_VM2_PASSWORD=""

# IPsec
export IPSEC_VM1_IP=""
export IPSEC_VM2_IP=""
export IPSEC_VM2_USER=ubuntu
export IPSEC_VM2_HOST=""
export IPSEC_VM2_REPO="/home/ubuntu/proto-testbed"
export IPSEC_VM2_PASSWORD=""

# SSH
export SSH_VM1_IP=""
export SSH_VM2_IP=""
export SSH_VM2_USER=ubuntu
export SSH_VM2_HOST=""
export SSH_VM2_REPO="/home/ubuntu/proto-testbed"
export SSH_VM2_PASSWORD=""

# Client connect target for TLS/mTLS/QUIC. 
# Empty: connect directly to VM2_IP.
# Non-empty: connect to this address (e.g. an AWS NLB DNS name) that forwards to vm2.
# When set, pki/gen.sh adds it to the server cert SAN. See docs/nlb-setup.md.
export NLB_HOST=""

# ---------------------------------------------------------------------------
# Protocol ports (all listeners on vm2)
# ---------------------------------------------------------------------------

export PORT_TLS=4433         # TLS classical
export PORT_TLS_PQC=4434     # TLS PQC
export PORT_MTLS=4435        # mTLS classical
export PORT_MTLS_PQC=4436    # mTLS PQC
export PORT_DTLS=4437        # DTLS classical
export PORT_QUIC=4438        # QUIC classical
export PORT_QUIC_PQC=4439    # QUIC PQC
export PORT_IPSEC=4440       # IPSec classical
export PORT_IPSEC_PQC=4441   # IPSec PQC
export PORT_SSH=4442         # SSH classical
export PORT_SSH_PQC=4443     # SSH PQC
