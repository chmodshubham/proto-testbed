# QUIC Setup

vm1 connects to a QUIC server running on vm2 in a loop. Each connection completes a full QUIC handshake (TLS 1.3 inside QUIC over UDP) and prints the KEX group, cipher, and verification result. Runs in classical or post-quantum mode.

| Mode      | Server cert | KEX            | Cipher                 | Port |
| --------- | ----------- | -------------- | ---------------------- | ---- |
| Classical | Ed25519     | X25519         | TLS_AES_128_GCM_SHA256 | 4438 |
| PQC       | ML-DSA-65   | X25519MLKEM768 | TLS_AES_128_GCM_SHA256 | 4439 |

## Pre-requisites

See the root [README.md](../../README.md) for VM setup, hardware, and per-protocol `env.sh` configuration.

Install on **both VMs**:

- OpenSSL 4.0: [docs/openssl.md](../../docs/openssl.md)
- nginx (BoringSSL): [docs/nginx.md](../../docs/nginx.md)

Install on **vm1** only (client build dependency):

```bash
sudo apt-get install -y libnghttp3-dev
```

`libnghttp3` is required by the QUIC C client to issue real HTTP/3 GET requests after the handshake. `run.sh` installs it automatically via `ensure_apt_deps`.

The QUIC client is a small C program ([`client.c`](client.c)) using OpenSSL 4.0's native QUIC API and nghttp3. `run.sh` builds it automatically; for the direct-orchestrator path, build it by hand on vm1.

The QUIC server is nginx built against BoringSSL with HTTP/3 support (`--with-http_v3_module`).

## Run

`run.sh` generates the PKI on first run, builds the client binary on vm1, syncs everything to vm2, starts the nginx server, and loops traffic until you press Ctrl-C.

```bash
./run.sh --proto quic --mode classical   # Ed25519 cert, X25519 KEX
./run.sh --proto quic --mode pqc         # ML-DSA-65 cert, X25519MLKEM768 KEX
./run.sh --proto quic --mode all         # both modes in parallel
```

Each connection prints one row: timestamp, connection number, KEX group, cipher suite, verify code. `Verify: 0` means certificate validation succeeded.

The nginx server stays running on vm2 after Ctrl-C and is reused on the next run. Manage it explicitly:

```bash
./nginx-server.sh status --proto quic            # UP/DOWN per mode
./nginx-server.sh stop   --proto quic            # stop both modes (do this after regenerating certs)
./nginx-server.sh start  --proto quic --mode pqc
```

## Reverse proxy (optional)

Set `QUIC_BACKEND_URL` in `env.sh`. Edit `env.sh` only — shell-level exports are not forwarded to vm2.

```bash
# in env.sh:
export QUIC_BACKEND_URL="http://<backend-ip>:8080/api/path"
```

Run as usual. If the proxy vars changed since nginx last started, it restarts automatically. The QUIC client issues a real HTTP/3 `GET /` each iteration, so the proxy is exercised on every connection.

## Run the orchestrator directly

`run.sh` is the recommended entry point. Running the orchestrator directly skips dependency installs, PKI generation, the vm2 sync, and the client build, so you have to do those steps manually first.

1. Generate the PKI on **vm1**:

   ```bash
   source env.sh
   ./pki/gen.sh --proto quic
   ```

   This produces:

   ```
   pki/out/ca/quic/classical/ca-cert.pem
   pki/out/ca/quic/pqc/ca-cert.pem
   pki/out/quic/classical/server-cert.pem  server-key.pem
   pki/out/quic/pqc/server-cert.pem        server-key.pem
   ```

2. Build the client binary and sync everything to **vm2**:

   ```bash
   make -C protocols/quic

   rsync -a --mkpath protocols/quic/      "$VM2_USER@$VM2_HOST:$VM2_REPO/protocols/quic/"
   rsync -a --mkpath pki/out/ca/quic/     "$VM2_USER@$VM2_HOST:$VM2_REPO/pki/out/ca/quic/"
   rsync -a --mkpath pki/out/quic/        "$VM2_USER@$VM2_HOST:$VM2_REPO/pki/out/quic/"
   ```

3. Verify on **vm2** (run from repo root; both must print `OK`):

   ```bash
   cd proto-testbed
   source env.sh

   os-lib/install/openssl-4.0/bin/openssl verify \
       -CAfile pki/out/ca/quic/classical/ca-cert.pem \
       pki/out/quic/classical/server-cert.pem

   os-lib/install/openssl-4.0/bin/openssl verify \
       -CAfile pki/out/ca/quic/pqc/ca-cert.pem \
       pki/out/quic/pqc/server-cert.pem
   ```

4. Start the orchestrator:

   ```bash
   bash orchestrator/quic.sh classical
   bash orchestrator/quic.sh pqc
   ```

## Algorithm reference

| Field          | Classical              | PQC                     |
| -------------- | ---------------------- | ----------------------- |
| CA key         | Ed25519                | ML-DSA-44               |
| Server key     | Ed25519                | ML-DSA-65               |
| KEX            | X25519                 | X25519MLKEM768 (hybrid) |
| Cipher         | TLS_AES_128_GCM_SHA256 | TLS_AES_128_GCM_SHA256  |
| Signature algs | ed25519                | mldsa65:mldsa44:ed25519 |

QUIC mandates TLS 1.3. The cipher `TLS_AES_128_GCM_SHA256` is distinct from TLS/mTLS (AES-256) and DTLS (AES-256-CBC via DTLS 1.2).
