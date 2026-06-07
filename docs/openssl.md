# OpenSSL Installation Guide

Builds OpenSSL 4.0 from source into `os-lib/install/openssl-4.0/` inside the repo. Nothing touches the system OpenSSL. Used by TLS, mTLS, DTLS, and QUIC for the ML-KEM and `X25519MLKEM768` post-quantum primitives.

Run on **both VMs** from the repo root.

## Pre-requisites

See the root [README.md](../README.md).

## Step 1: Install build dependencies

```bash
sudo apt install -y build-essential cmake pkg-config perl
```

## Step 2: Download and build

```bash
cd proto-testbed/
mkdir -p os-lib/src && cd os-lib/src
curl -LO https://github.com/openssl/openssl/releases/download/openssl-4.0.0/openssl-4.0.0.tar.gz
tar xzf openssl-4.0.0.tar.gz && cd openssl-4.0.0

./Configure \
    --prefix="$(cd ../../.. && pwd)/os-lib/install/openssl-4.0" \
    --openssldir="$(cd ../../.. && pwd)/os-lib/install/openssl-4.0/ssl" \
    --libdir=lib \
    linux-x86_64

make -j$(nproc) && make install
cd ../../..
```

## Step 3: Verify the PQ algorithms

```bash
os-lib/install/openssl-4.0/bin/openssl list -kem-algorithms | grep ML-KEM
os-lib/install/openssl-4.0/bin/openssl list -tls-groups     | grep MLKEM
```

Both must return at least one line. If empty, re-run Step 2 and check `make install` for errors.

## Next

| Protocol       | Guide                                                   |
| -------------- | ------------------------------------------------------- |
| TLS 1.2 / 1.3  | [protocols/tls/README.md](../protocols/tls/README.md)   |
| mTLS 1.2 / 1.3 | [protocols/mtls/README.md](../protocols/mtls/README.md) |
| DTLS 1.2       | [protocols/dtls/README.md](../protocols/dtls/README.md) |
| QUIC           | [protocols/quic/README.md](../protocols/quic/README.md) |
