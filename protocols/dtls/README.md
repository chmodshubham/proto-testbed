# DTLS 1.2 Setup

vm1 = client, vm2 = server. Servers run on vm2; traffic is driven from vm1.

| Mode      | Server cert | KEX       | Cipher                        | Port |
| --------- | ----------- | --------- | ----------------------------- | ---- |
| Classical | ECDSA P-521 | secp521r1 | ECDHE-ECDSA-AES256-GCM-SHA384 | 4437 |

DTLS 1.3 does not exist in any shipping implementation (RFC 9147 is published but OpenSSL support is not complete). ML-KEM hybrid groups require TLS 1.3 and are therefore unavailable. DTLS runs classical-only.

All commands run from the repo root. Every terminal session starts with:

```bash
cd /path/to/proto-testbed
source env.sh
```

## Prerequisites

Steps 1 through 4 are shared with TLS and mTLS. If you have already completed those setups, skip to Step 5.

- Ubuntu 24.04 LTS (x86_64) on both VMs
- Passwordless SSH from vm1 to vm2
- `sudo` access on both VMs

### Hardware requirements

| Resource     | Minimum | Notes                                                                                                                                                    |
| ------------ | ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Architecture | x86_64  | Build target is `linux-x86_64`; OpenSSL assembly optimisations are architecture-specific                                                                 |
| CPU          | 1 core  | Build uses `make -j$(nproc)`; more cores reduce compile time (~5 min on 4 cores)                                                                         |
| RAM          | 256 MB  | DTLS record buffer: 16384 B plain + 256 B overhead per connection (`SSL3_RT_MAX_PLAIN_LENGTH`, `ssl3.h`); DTLS 1.2 only, no PQC KEX, no extra key material |
| Disk         | 1.1 GB  | ~44 MB installed (`os-lib/install/openssl-4.0/`); source + build tree ~900 MB                                                                           |

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
./pki/gen.sh --proto dtls
```

## Step 6: Build binaries and copy certs to vm2

`openssl s_server` cannot hold a persistent UDP socket for DTLS, so server and client are custom C programs. Build on vm1, then sync sources and certs to vm2 and build there too.

Run on **vm1** from repo root.

```bash
make -C protocols/dtls

source env.sh

rsync -a --mkpath \
    protocols/dtls/ \
    "$VM2_USER@$VM2_HOST:$VM2_REPO/protocols/dtls/"

ssh "$VM2_USER@$VM2_HOST" "cd $VM2_REPO && make -C protocols/dtls"

rsync -a --mkpath \
    pki/out/ca/dtls/ \
    "$VM2_USER@$VM2_HOST:$VM2_REPO/pki/out/ca/dtls/"

rsync -a --mkpath \
    pki/out/dtls/ \
    "$VM2_USER@$VM2_HOST:$VM2_REPO/pki/out/dtls/"
```

Verify on **vm2**:

```bash
source env.sh

os-lib/install/openssl-4.0/bin/openssl verify -CAfile pki/out/ca/dtls/classical/ca-cert.pem \
    pki/out/dtls/classical/server-cert.pem
```

Should print `OK`.

## Step 7: Start server and run traffic

Run on **vm1** from repo root. Starts the server on vm2, waits until ready, then loops traffic. Press Ctrl-C to stop.

```bash
source env.sh

bash orchestrator/dtls.sh classical
```

Or via run.sh:

```bash
./run.sh --proto dtls --mode classical
```

Each connection prints one row: timestamp, connection number, KEX group, cipher suite, verify code. `Verify: 0` confirms certificate validation succeeded. After the handshake the client sends `PING` and the server replies `PONG`; the server log line `Data OK: PING received, sending PONG.` proves the encrypted DTLS record was decrypted on vm2.

> [!NOTE]
> `openssl s_server` exits immediately when used for DTLS because it calls `recvfrom` without first binding the socket. The server here is a small C program (`protocols/dtls/server.c`) that binds a UDP socket via `BIO_new_dgram`, loops accepting connections, and stays resident. The client (`protocols/dtls/client.c`) outputs one line per connection in the format the orchestrator greps for.
