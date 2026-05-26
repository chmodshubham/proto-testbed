# QUIC

QUIC over UDP using OpenSSL 4.0's native QUIC API (`OSSL_QUIC_server_method` / `OSSL_QUIC_client_method`).

Two modes: classical (Ed25519 certs, X25519 KEX) and PQC (ML-DSA certs, X25519MLKEM768 KEX).

## Algorithm Choices

| Field          | Classical              | PQC                     |
| -------------- | ---------------------- | ----------------------- |
| CA key         | Ed25519                | ML-DSA-44               |
| Server key     | Ed25519                | ML-DSA-65               |
| KEX            | X25519                 | X25519MLKEM768 (hybrid) |
| Cipher         | TLS_AES_128_GCM_SHA256 | TLS_AES_128_GCM_SHA256  |
| Signature algs | ed25519                | mldsa65:mldsa44:ed25519 |

QUIC mandates TLS 1.3. The cipher `TLS_AES_128_GCM_SHA256` is distinct from TLS/mTLS (AES-256) and DTLS (AES-256-CBC via DTLS 1.2).

## Prerequisites

- Ubuntu 24.04 LTS (x86_64) on both VMs
- Passwordless SSH from vm1 to vm2
- `sudo` access on both VMs

### Hardware requirements

| Resource     | Minimum | Notes                                                                                                                                                                                                                     |
| ------------ | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Architecture | x86_64  | Build target is `linux-x86_64`; OpenSSL assembly optimisations are architecture-specific                                                                                                                                  |
| CPU          | 1 core  | Build uses `make -j$(nproc)`; more cores reduce compile time (~5 min on 4 cores)                                                                                                                                          |
| RAM          | 256 MB  | QUIC connection RX flow-control window: 768 KB (`DEFAULT_INIT_CONN_RXFC_WND`, `quic_channel.c`); per-stream window: 512 KB (`DEFAULT_INIT_STREAM_RXFC_WND`); PQC key_share adds 1184 B ML-KEM-768 public key (`ml_kem.h`) |
| Disk         | 1.1 GB  | ~44 MB installed (`os-lib/install/openssl-4.0/`); source + build tree ~900 MB                                                                                                                                             |

All commands run from the repo root. Every terminal session starts with:

```bash
cd /path/to/proto-testbed
source env.sh
```

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

**vm1:** open `env.sh` and update VM credentials and connection details:

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

## Step 5: Build binaries

Run on **both VMs** from repo root.

```bash
make -C protocols/quic
```

## Step 6: Generate PKI

Run on **vm1** only, from repo root.

```bash
source env.sh
./pki/gen.sh --proto quic
```

Output:

```
pki/out/ca/quic/classical/ca-cert.pem
pki/out/quic/classical/server-cert.pem  server-key.pem
pki/out/ca/quic/pqc/ca-cert.pem
pki/out/quic/pqc/server-cert.pem  server-key.pem
```

## Step 7: Start server and run traffic

### Manual (two terminals)

**Terminal 1 — vm2** (server):

```bash
source env.sh
bash protocols/quic/server.sh classical   # Ed25519 cert, X25519 KEX
bash protocols/quic/server.sh pqc         # ML-DSA-65 cert, X25519MLKEM768 KEX
```

**Terminal 2 — vm1** (client, run once per connection):

```bash
source env.sh
bash protocols/quic/client.sh classical
bash protocols/quic/client.sh pqc
```

### Automated (orchestrator)

Run on **vm1** from repo root. Starts server on vm2, waits until ready, then loops traffic. Press Ctrl-C to stop.

```bash
source env.sh

bash orchestrator/quic.sh classical
bash orchestrator/quic.sh pqc
```

Or via run.sh:

```bash
./run.sh --proto quic --mode classical
./run.sh --proto quic --mode pqc
```

Each connection prints one row: timestamp, connection number, KEX group, cipher suite, verify code. `Verify: 0` means certificate validation succeeded. After the handshake the client sends `GET / HTTP/1.0` and the server replies with a short HTTP/200; the server log line `Data OK: N bytes received, sending response.` proves the QUIC stream carried application data.

## Ports

| Mode      | env.sh variable | Default | Transport |
| --------- | --------------- | ------- | --------- |
| classical | `PORT_QUIC`     | 4438    | UDP       |
| pqc       | `PORT_QUIC_PQC` | 4439    | UDP       |
