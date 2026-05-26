# mTLS Setup

vm1 = client, vm2 = server. Servers run on vm2; traffic is driven from vm1.

| Mode      | Version | Server cert | Client cert | KEX                | Cipher                        | Port |
| --------- | ------- | ----------- | ----------- | ------------------ | ----------------------------- | ---- |
| Classical | 1.2     | ECDSA P-384 | Ed448       | X448               | ECDHE-ECDSA-CHACHA20-POLY1305 | 4435 |
| PQC       | 1.3     | ML-DSA-87   | ML-DSA-44   | SecP384r1MLKEM1024 | TLS_AES_256_GCM_SHA384        | 4436 |

All commands run from the repo root. Every terminal session starts with:

```bash
cd /path/to/proto-testbed
source env.sh
```

## Prerequisites

Steps 1 through 4 are shared with TLS. If you have already completed the TLS setup, skip to Step 5.

- Ubuntu 24.04 LTS (x86_64) on both VMs
- Passwordless SSH from vm1 to vm2
- `sudo` access on both VMs

### Hardware requirements

| Resource     | Minimum | Notes                                                                                                                                                                                                           |
| ------------ | ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Architecture | x86_64  | Build target is `linux-x86_64`; OpenSSL assembly optimisations are architecture-specific                                                                                                                        |
| CPU          | 1 core  | Build uses `make -j$(nproc)`; more cores reduce compile time (~5 min on 4 cores)                                                                                                                                |
| RAM          | 256 MB  | TLS record buffer: 16384 B plain + 256 B overhead per connection (`SSL3_RT_MAX_PLAIN_LENGTH`, `ssl3.h`); mTLS adds one client cert round-trip per handshake; PQC adds 1568 B ML-KEM-1024 key_share (`ml_kem.h`) |
| Disk         | 1.1 GB  | ~44 MB installed (`os-lib/install/openssl-4.0/`); source + build tree ~900 MB                                                                                                                                   |

## Step 1: Install build dependencies

Run on **both VMs**.

```bash
sudo apt-get install -y build-essential cmake pkg-config perl rsync
```

## Step 2: Clone the repo

Run on **both VMs**.

```bash
git clone https://github.com/chmodshubham/proto-testbed proto-testbed
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
./pki/gen.sh --proto mtls
```

## Step 6: Copy certs to vm2

Run on **vm1** from repo root. vm2 needs the CA certs and server certs. Client certs stay on vm1.

```bash
source env.sh

rsync -a --mkpath \
    pki/out/ca/mtls/ \
    "$VM2_USER@$VM2_HOST:$VM2_REPO/pki/out/ca/mtls/"

rsync -a --mkpath \
    pki/out/mtls/classical/server-cert.pem \
    pki/out/mtls/classical/server-key.pem \
    "$VM2_USER@$VM2_HOST:$VM2_REPO/pki/out/mtls/classical/"

rsync -a --mkpath \
    pki/out/mtls/pqc/server-cert.pem \
    pki/out/mtls/pqc/server-key.pem \
    "$VM2_USER@$VM2_HOST:$VM2_REPO/pki/out/mtls/pqc/"
```

Verify on **vm2**:

```bash
source env.sh

os-lib/install/openssl-4.0/bin/openssl verify -CAfile pki/out/ca/mtls/classical/ca-cert.pem \
    pki/out/mtls/classical/server-cert.pem

os-lib/install/openssl-4.0/bin/openssl verify -CAfile pki/out/ca/mtls/pqc/ca-cert.pem \
    pki/out/mtls/pqc/server-cert.pem
```

Both should print `OK`.

## Step 7: Start server and run traffic

Run on **vm1** from repo root. Starts the server on vm2, waits until ready, then loops traffic. Press Ctrl-C to stop.

```bash
source env.sh

bash orchestrator/mtls.sh classical   # ECDSA P-384 server, Ed448 client, X448 KEX
bash orchestrator/mtls.sh pqc         # ML-DSA-87 server, ML-DSA-44 client, SecP384r1MLKEM1024 KEX
```

Or via run.sh:

```bash
./run.sh --proto mtls --mode classical
./run.sh --proto mtls --mode pqc
```

Each connection prints one row: timestamp, connection number, KEX group, cipher suite, verify code. `Verify: 0` on every row confirms mutual authentication succeeded.

## Key flags

| Flag              | Description                                          |
| ----------------- | ---------------------------------------------------- |
| `-tls1_2`         | TLS 1.2 only (classical mode)                        |
| `-tls1_3`         | TLS 1.3 only (PQC mode)                              |
| `-cipher <list>`  | Colon-separated cipher suites (TLS 1.2, classical)   |
| `-ciphersuites`   | Colon-separated cipher suites (TLS 1.3, PQC)         |
| `-groups <list>`  | Colon-separated KEX groups                           |
| `-sigalgs <list>` | Colon-separated signature algorithms                 |
| `-Verify <depth>` | Require and verify client cert (server only)         |
| `-cert / -key`    | Client certificate and key (client only)             |
| `-WWW`            | HTTP-like GET mode (server)                          |
| `-keylogfile`     | NSS keylog for Wireshark decryption                  |
