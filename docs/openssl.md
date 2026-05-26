# OpenSSL 4.0 Setup

Single source of truth for installing OpenSSL 4.0 on **vm1** and **vm2**. Required by TLS, mTLS, DTLS, and QUIC.

All commands run from the repo root. Source `env.sh` first.

## Prerequisites

- Ubuntu 24.04 LTS (x86_64) on both VMs
- `sudo` access on both VMs

### Hardware requirements

| Resource     | Minimum | Notes                                                                                    |
| ------------ | ------- | ---------------------------------------------------------------------------------------- |
| Architecture | x86_64  | Build target is `linux-x86_64`; OpenSSL assembly optimisations are architecture-specific |
| CPU          | 1 core  | Build uses `make -j$(nproc)`; ~5 min on 4 cores                                          |
| RAM          | 256 MB  | Build peak ~200 MB                                                                       |
| Disk         | 1.1 GB  | ~44 MB installed (`os-lib/install/openssl-4.0/`); source + build tree ~900 MB           |

## Step 1: Install build dependencies

Run on **both VMs**.

```bash
sudo apt-get install -y build-essential cmake pkg-config perl rsync
```

## Step 2: Build on vm1

From repo root:

```bash
source env.sh
mkdir -p os-lib/src
cd os-lib/src
curl -LO https://github.com/openssl/openssl/releases/download/openssl-4.0.0/openssl-4.0.0.tar.gz
tar xzf openssl-4.0.0.tar.gz
cd openssl-4.0.0

./Configure \
    --prefix="$(cd ../../.. && pwd)/os-lib/install/openssl-4.0" \
    --openssldir="$(cd ../../.. && pwd)/os-lib/install/openssl-4.0/ssl" \
    --libdir=lib \
    linux-x86_64

make -j$(nproc)
make install
cd ../../..
```

## Step 3: Build on vm2

`os-lib/` is gitignored and excluded from `rsync`, so vm2 must build independently.

```bash
ssh "${VM2_USER}@${VM2_HOST}" "
    cd ${VM2_REPO} &&
    mkdir -p os-lib/src &&
    cd os-lib/src &&
    curl -LO https://github.com/openssl/openssl/releases/download/openssl-4.0.0/openssl-4.0.0.tar.gz &&
    tar xzf openssl-4.0.0.tar.gz &&
    cd openssl-4.0.0 &&
    ./Configure \
        --prefix=\"\$(cd ../../.. && pwd)/os-lib/install/openssl-4.0\" \
        --openssldir=\"\$(cd ../../.. && pwd)/os-lib/install/openssl-4.0/ssl\" \
        --libdir=lib \
        linux-x86_64 &&
    make -j\$(nproc) &&
    make install
"
```

## Step 4: Smoke test

Run on **both VMs**:

```bash
os-lib/install/openssl-4.0/bin/openssl list -kem-algorithms | grep ML-KEM
os-lib/install/openssl-4.0/bin/openssl list -tls-groups   | grep MLKEM
```

Both must return results before proceeding.

## Next

Continue with PKI generation and orchestrator setup in the per-protocol README:

| Protocol | Next steps                                             |
| -------- | ------------------------------------------------------ |
| TLS 1.3  | [protocols/tls/README.md](../protocols/tls/README.md)   |
| mTLS 1.3 | [protocols/mtls/README.md](../protocols/mtls/README.md) |
| DTLS 1.2 | [protocols/dtls/README.md](../protocols/dtls/README.md) |
| QUIC     | [protocols/quic/README.md](../protocols/quic/README.md) |
