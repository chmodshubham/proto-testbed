# TLS 1.3 Setup

vm1 = client, vm2 = server. Servers run on vm2; traffic is driven from vm1.

| Mode      | Cert        | KEX            | Port |
| --------- | ----------- | -------------- | ---- |
| Classical | ECDSA P-256 | X25519         | 4433 |
| PQC       | ML-DSA-65   | X25519MLKEM768 | 4434 |

All commands run from the repo root. Every terminal session starts with:

```bash
cd /path/to/proto-testbed
source env.sh
```

## Prerequisites

- Ubuntu 24.04 LTS (x86_64) on both VMs
- Passwordless SSH from vm1 to vm2
- `sudo` access on both VMs

### Hardware requirements

| Resource     | Minimum | Notes                                                                                                                                                                  |
| ------------ | ------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Architecture | x86_64  | Build target is `linux-x86_64`; OpenSSL assembly optimisations are architecture-specific                                                                               |
| CPU          | 1 core  | Build uses `make -j$(nproc)`; more cores reduce compile time (~5 min on 4 cores)                                                                                       |
| RAM          | 256 MB  | TLS record buffer: 16384 B plain + 256 B overhead per connection (`SSL3_RT_MAX_PLAIN_LENGTH`, `ssl3.h`); PQC key_share adds 1184 B (ML-KEM-768 public key, `ml_kem.h`) |
| Disk         | 1.1 GB  | ~44 MB installed (`os-lib/install/openssl-4.0/`); source + build tree ~900 MB                                                                                          |

## Step 1: Install build dependencies

Run on **both VMs**.

```bash
sudo apt-get install -y build-essential cmake pkg-config perl rsync
```

## Step 2: Clone the repo

Run on **both VMs**.

```bash
git clone <repo-url> proto-testbed
cd proto-testbed
```

## Step 3: Configure env.sh

**vm1:** open `env.sh` and update the VM credentials and connection details to match your environment:

```bash
export VM2_USER=ubuntu
export VM2_HOST=<vm2-hostname>
export VM2_REPO="/home/ubuntu/proto-testbed"
export VM1_IP=<vm1-ip>
export VM2_IP=<vm2-ip>
```

Sync to vm2:

```bash
source env.sh
rsync -a env.sh "$VM2_USER@$VM2_HOST:$VM2_REPO/"
```

## Step 4: Build OpenSSL 4.0

See [docs/openssl.md](../../docs/openssl.md) for the full build and smoke test on both VMs.

## Step 5: Generate PKI

Run on **vm1** only, from repo root.

```bash
source env.sh
./pki/gen.sh --proto tls
```

Output:

```
pki/out/ca/tls/classical/ca-cert.pem
pki/out/ca/tls/pqc/ca-cert.pem
pki/out/tls/classical/server-cert.pem  server-key.pem
pki/out/tls/pqc/server-cert.pem        server-key.pem
```

## Step 6: Copy certs to vm2

Run on **vm1** from repo root.

```bash
source env.sh

rsync -a --mkpath \
    pki/out/ca/tls/ \
    "$VM2_USER@$VM2_HOST:$VM2_REPO/pki/out/ca/tls/"

rsync -a --mkpath \
    pki/out/tls/ \
    "$VM2_USER@$VM2_HOST:$VM2_REPO/pki/out/tls/"
```

Verify on **vm2**:

```bash
source env.sh

os-lib/install/openssl-4.0/bin/openssl verify -CAfile pki/out/ca/tls/classical/ca-cert.pem \
    pki/out/tls/classical/server-cert.pem

os-lib/install/openssl-4.0/bin/openssl verify -CAfile pki/out/ca/tls/pqc/ca-cert.pem \
    pki/out/tls/pqc/server-cert.pem
```

Both should print `OK`.

## Step 7: Start server and run traffic

Run on **vm1** from repo root. Starts the server on vm2, waits until ready, then loops traffic. Press Ctrl-C to stop.

```bash
source env.sh

bash orchestrator/tls.sh classical   # ECDSA P-256 cert, X25519 KEX
bash orchestrator/tls.sh pqc         # ML-DSA-65 cert, X25519MLKEM768 KEX
```

Or via run.sh:

```bash
./run.sh --proto tls --mode classical
./run.sh --proto tls --mode pqc
```

Each connection prints one row: timestamp, connection number, KEX group, cipher suite, verify code. `Verify: 0` means certificate validation succeeded.

## Key flags

| Flag              | Description                          |
| ----------------- | ------------------------------------ |
| `-tls1_3`         | TLS 1.3 only                         |
| `-groups <list>`  | Colon-separated KEX groups           |
| `-sigalgs <list>` | Colon-separated signature algorithms |
| `-WWW`            | HTTP-like GET mode (server)          |
| `-keylogfile`     | NSS keylog for Wireshark decryption  |
| `-Verify <depth>` | Require client cert (server only)    |

Groups: `X25519` (0x001D), `X25519MLKEM768` (0x11EC), `SecP256r1MLKEM768` (0x11EB).
Sigalgs: PQC = `mldsa44 mldsa65 mldsa87`. Classical = `ecdsa_secp256r1_sha256`.
