# mTLS Setup

vm1 connects to an mTLS server running on vm2 in a loop. Each connection completes a full mutual handshake (server proves identity to client, client proves identity to server) and prints the KEX group, cipher, and verification result. Runs in classical or post-quantum mode.

| Mode      | Version | Server cert | Client cert | KEX                | Cipher                        | Port |
| --------- | ------- | ----------- | ----------- | ------------------ | ----------------------------- | ---- |
| Classical | 1.2     | ECDSA P-384 | Ed448       | X448               | ECDHE-ECDSA-CHACHA20-POLY1305 | 4435 |
| PQC       | 1.3     | ML-DSA-87   | ML-DSA-44   | SecP384r1MLKEM1024 | TLS_AES_256_GCM_SHA384        | 4436 |

## Pre-requisites

See the root [README.md](../../README.md) for VM setup, hardware, and per-protocol `env.sh` configuration. Install OpenSSL 4.0 on both VMs first per [docs/openssl.md](../../docs/openssl.md).

## Run

`run.sh` generates the PKI on first run, syncs it (and the repo) to vm2, starts the server, and loops traffic until you press Ctrl-C.

```bash
./run.sh --proto mtls --mode classical   # TLS 1.2 with X448 KEX, Ed448 client cert
./run.sh --proto mtls --mode pqc         # TLS 1.3 with SecP384r1MLKEM1024 KEX, ML-DSA-44 client cert
./run.sh --proto mtls --mode all         # both modes in parallel
```

Each connection prints one row: timestamp, connection number, KEX group, cipher suite, verify code. `Verify: 0` means the mutual handshake and certificate validation on both sides succeeded.

## Run the orchestrator directly

`run.sh` is the recommended entry point. Running the orchestrator directly skips dependency installs, PKI generation, and the vm2 sync, so you have to do those steps manually first.

1. Generate the PKI on **vm1**:

   ```bash
   source env.sh
   ./pki/gen.sh --proto mtls
   ```

   This produces:

   ```
   pki/out/ca/mtls/classical/ca-cert.pem
   pki/out/ca/mtls/pqc/ca-cert.pem
   pki/out/mtls/classical/server-cert.pem  server-key.pem  client-cert.pem  client-key.pem
   pki/out/mtls/pqc/server-cert.pem        server-key.pem  client-cert.pem  client-key.pem
   ```

2. Sync to **vm2** (vm2 needs the CA certs and server certs; client certs stay on vm1):

   ```bash
   rsync -a --mkpath pki/out/ca/mtls/ "$VM2_USER@$VM2_HOST:$VM2_REPO/pki/out/ca/mtls/"
   rsync -a --mkpath \
       pki/out/mtls/classical/server-cert.pem \
       pki/out/mtls/classical/server-key.pem \
       "$VM2_USER@$VM2_HOST:$VM2_REPO/pki/out/mtls/classical/"
   rsync -a --mkpath \
       pki/out/mtls/pqc/server-cert.pem \
       pki/out/mtls/pqc/server-key.pem \
       "$VM2_USER@$VM2_HOST:$VM2_REPO/pki/out/mtls/pqc/"
   ```

3. Verify on **vm2** (run from repo root; both must print `OK`):

   ```bash
   cd proto-testbed
   source env.sh

   os-lib/install/openssl-4.0/bin/openssl verify \
       -CAfile pki/out/ca/mtls/classical/ca-cert.pem \
       pki/out/mtls/classical/server-cert.pem

   os-lib/install/openssl-4.0/bin/openssl verify \
       -CAfile pki/out/ca/mtls/pqc/ca-cert.pem \
       pki/out/mtls/pqc/server-cert.pem
   ```

4. Start the orchestrator:

   ```bash
   bash orchestrator/mtls.sh classical
   bash orchestrator/mtls.sh pqc
   ```
