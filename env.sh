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

export INSTALL="$(pwd)/os-lib/install/openssl-4.0"
export LD_LIBRARY_PATH="${INSTALL}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# ---------------------------------------------------------------------------
# VM topology
# ---------------------------------------------------------------------------

export VM1_IP=10.141.230.62       # vm1  — client
export VM2_IP=10.141.230.76       # vm2  — server

# vm2 SSH connection (used by orchestrator scripts on vm1 only)
export VM2_USER=ubuntu
export VM2_HOST=vm14
export VM2_REPO="/home/ubuntu/proto-testbed"   # absolute path
export VM2_PASSWORD=""                     # set if vm2 system SSH requires password; leave empty for key-based auth

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
