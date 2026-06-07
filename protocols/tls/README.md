# TLS Setup

vm1 connects to a TLS server running on vm2 in a loop. Each connection completes a full handshake and prints the KEX group, cipher, and verification result. Runs in classical or post-quantum mode.

| Mode      | Version | Cert        | KEX            | Port |
| --------- | ------- | ----------- | -------------- | ---- |
| Classical | 1.2     | ECDSA P-256 | X25519         | 4433 |
| PQC       | 1.3     | ML-DSA-65   | X25519MLKEM768 | 4434 |

## Pre-requisites

See the root [README.md](../../README.md) for VM setup, hardware, and per-protocol `env.sh` configuration.

Install on **both VMs**:

- OpenSSL 4.0: [docs/openssl.md](../../docs/openssl.md)
- nginx (BoringSSL): [docs/nginx.md](../../docs/nginx.md)

## Run

`run.sh` generates the PKI on first run, syncs the repo to vm2, starts the nginx server, and loops traffic until you press Ctrl-C.

```bash
./run.sh --proto tls --mode classical   # TLS 1.2 with X25519 KEX
./run.sh --proto tls --mode pqc         # TLS 1.3 with X25519MLKEM768 KEX
./run.sh --proto tls --mode all         # both modes in parallel
```

Each connection prints one row: timestamp, connection number, KEX group, cipher suite, verify code. `Verify: 0` means the handshake and certificate validation succeeded.

The nginx server stays running on vm2 after Ctrl-C and is reused on the next run. Manage it explicitly:

```bash
./nginx-server.sh status --proto tls            # UP/DOWN per mode
./nginx-server.sh stop   --proto tls            # stop both modes (do this after regenerating certs)
./nginx-server.sh start  --proto tls --mode pqc
```

## Reverse proxy (optional)

Set both `TLS_PROXY_HOST` and `TLS_PROXY_PORT` in `env.sh`. Edit `env.sh` only — shell-level exports are not forwarded to vm2.

```bash
# in env.sh:
export TLS_PROXY_HOST="<backend-ip>"
export TLS_PROXY_PORT="8080"
```

Run as usual. If the proxy vars changed since nginx last started, it restarts automatically. If the backend is unreachable, the client gets `502 Bad Gateway`.

## Run the orchestrator directly

`run.sh` is the recommended entry point. Running the orchestrator directly skips dependency installs, PKI generation, and the vm2 sync, so you have to do those steps manually first.

1. Generate the PKI on **vm1**:

   ```bash
   source env.sh
   ./pki/gen.sh --proto tls
   ```

   This produces:

   ```
   pki/out/ca/tls/classical/ca-cert.pem
   pki/out/ca/tls/pqc/ca-cert.pem
   pki/out/tls/classical/server-cert.pem  server-key.pem
   pki/out/tls/pqc/server-cert.pem        server-key.pem
   ```

2. Sync the certificates and repo to **vm2**:

   ```bash
   rsync -a --mkpath pki/out/ca/tls/ "$VM2_USER@$VM2_HOST:$VM2_REPO/pki/out/ca/tls/"
   rsync -a --mkpath pki/out/tls/    "$VM2_USER@$VM2_HOST:$VM2_REPO/pki/out/tls/"
   ```

3. Verify on **vm2** (run from repo root; both must print `OK`):

   ```bash
   cd proto-testbed
   source env.sh

   os-lib/install/openssl-4.0/bin/openssl verify \
       -CAfile pki/out/ca/tls/classical/ca-cert.pem \
       pki/out/tls/classical/server-cert.pem

   os-lib/install/openssl-4.0/bin/openssl verify \
       -CAfile pki/out/ca/tls/pqc/ca-cert.pem \
       pki/out/tls/pqc/server-cert.pem
   ```

4. Start the orchestrator:

   ```bash
   bash orchestrator/tls.sh classical
   bash orchestrator/tls.sh pqc
   ```

## Algorithm reference

| Field       | Classical                     | PQC                     |
| ----------- | ----------------------------- | ----------------------- |
| CA key      | P-256                         | ML-DSA-65               |
| Server key  | P-256                         | ML-DSA-65               |
| KEX         | X25519                        | X25519MLKEM768 (hybrid) |
| Cipher      | ECDHE-ECDSA-AES256-GCM-SHA384 | TLS_AES_256_GCM_SHA384  |
| TLS version | 1.2 and 1.3                   | 1.3 only                |

The server is nginx built against BoringSSL. The client is OpenSSL 4.0 `s_client`.
