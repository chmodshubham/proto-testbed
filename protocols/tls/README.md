# TLS Setup

vm1 connects to a TLS server running on vm2 in a loop. Each connection completes a full handshake and prints the KEX group, cipher, and verification result. Runs in classical or post-quantum mode.

| Mode      | Version | Cert        | KEX            | Port |
| --------- | ------- | ----------- | -------------- | ---- |
| Classical | 1.2     | ECDSA P-256 | X25519         | 4433 |
| PQC       | 1.3     | ML-DSA-65   | X25519MLKEM768 | 4434 |

## Pre-requisites

See the root [README.md](../../README.md) for VM setup, hardware, and per-protocol `env.sh` configuration. Install OpenSSL 4.0 on both VMs first per [docs/openssl.md](../../docs/openssl.md). Then on vm1:

## Run

`run.sh` generates the PKI on first run, syncs it (and the repo) to vm2, starts the server, and loops traffic until you press Ctrl-C.

```bash
./run.sh --proto tls --mode classical   # TLS 1.2 with X25519 KEX
./run.sh --proto tls --mode pqc         # TLS 1.3 with X25519MLKEM768 KEX
./run.sh --proto tls --mode all         # both modes in parallel
```

Each connection prints one row: timestamp, connection number, KEX group, cipher suite, verify code. `Verify: 0` means the handshake and certificate validation succeeded.

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

2. Sync the certificates to **vm2**:

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

## Flags reference

OpenSSL `s_server` / `s_client` flags used by `protocols/tls/server.sh` and `client.sh`:

| Flag              | Description                                        |
| ----------------- | -------------------------------------------------- |
| `-tls1_2`         | TLS 1.2 only (classical mode)                      |
| `-tls1_3`         | TLS 1.3 only (PQC mode)                            |
| `-cipher <list>`  | Colon-separated cipher suites (TLS 1.2, classical) |
| `-ciphersuites`   | Colon-separated cipher suites (TLS 1.3, PQC)       |
| `-groups <list>`  | Colon-separated KEX groups                         |
| `-sigalgs <list>` | Colon-separated signature algorithms               |
| `-WWW`            | HTTP-like GET mode (server)                        |
| `-keylogfile`     | NSS keylog for Wireshark decryption                |
