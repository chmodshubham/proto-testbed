# QUIC Setup

vm1 connects to a QUIC server running on vm2 in a loop. Each connection completes a full QUIC handshake (TLS 1.3 inside QUIC over UDP) and prints the KEX group, cipher, and verification result. Runs in classical or post-quantum mode.

| Mode      | Server cert | KEX            | Cipher                 | Port |
| --------- | ----------- | -------------- | ---------------------- | ---- |
| Classical | Ed25519     | X25519         | TLS_AES_128_GCM_SHA256 | 4438 |
| PQC       | ML-DSA-65   | X25519MLKEM768 | TLS_AES_128_GCM_SHA256 | 4439 |

## Pre-requisites

See the root [README.md](../../README.md) for VM setup, hardware, and per-protocol `env.sh` configuration. Install OpenSSL 4.0 on both VMs first per [docs/openssl.md](../../docs/openssl.md).

The QUIC server and client are small C programs ([`server.c`](server.c), [`client.c`](client.c)) using OpenSSL 4.0's native QUIC API (`OSSL_QUIC_server_method` / `OSSL_QUIC_client_method`). `run.sh` builds them automatically; for the direct-orchestrator path, build them by hand.

## Run

`run.sh` generates the PKI on first run, builds the C binaries on both VMs, syncs everything to vm2, starts the server, and loops traffic until you press Ctrl-C.

```bash
./run.sh --proto quic --mode classical   # Ed25519 cert, X25519 KEX
./run.sh --proto quic --mode pqc         # ML-DSA-65 cert, X25519MLKEM768 KEX
./run.sh --proto quic --mode all         # both modes in parallel
```

Each connection prints one row: timestamp, connection number, KEX group, cipher suite, verify code. `Verify: 0` means certificate validation succeeded. After the handshake the client sends `GET / HTTP/1.0` and the server replies with a short HTTP/200; the server log line `Data OK: N bytes received, sending response.` proves the QUIC stream carried application data.

## Run the orchestrator directly

`run.sh` is the recommended entry point. Running the orchestrator directly skips dependency installs, PKI generation, the vm2 sync, and the C build, so you have to do those steps manually first.

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

2. Build the C binaries and sync everything to **vm2**:

   ```bash
   make -C protocols/quic

   rsync -a --mkpath protocols/quic/      "$VM2_USER@$VM2_HOST:$VM2_REPO/protocols/quic/"
   rsync -a --mkpath pki/out/ca/quic/     "$VM2_USER@$VM2_HOST:$VM2_REPO/pki/out/ca/quic/"
   rsync -a --mkpath pki/out/quic/        "$VM2_USER@$VM2_HOST:$VM2_REPO/pki/out/quic/"

   ssh "$VM2_USER@$VM2_HOST" "cd $VM2_REPO && make -C protocols/quic"
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
