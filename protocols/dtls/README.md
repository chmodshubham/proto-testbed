# DTLS Setup

vm1 connects to a DTLS server running on vm2 in a loop. Each connection completes a full DTLS handshake over UDP and prints the KEX group, cipher, and verification result. DTLS runs classical-only: OpenSSL has no shipping DTLS 1.3 implementation, and ML-KEM hybrid groups require TLS 1.3.

| Mode      | Version | Server cert | KEX       | Cipher                        | Port |
| --------- | ------- | ----------- | --------- | ----------------------------- | ---- |
| Classical | 1.2     | ECDSA P-521 | secp521r1 | ECDHE-ECDSA-AES256-GCM-SHA384 | 4437 |

## Pre-requisites

See the root [README.md](../../README.md) for VM setup, hardware, and per-protocol `env.sh` configuration. Install OpenSSL 4.0 on both VMs first per [docs/openssl.md](../../docs/openssl.md).

`openssl s_server` cannot hold a persistent UDP socket for DTLS, so the server and client are small C programs ([`server.c`](server.c), [`client.c`](client.c)) built with the bundled Makefile. `run.sh` builds them automatically; for the direct-orchestrator path, build them by hand.

## Run

`run.sh` generates the PKI on first run, builds the C binaries on both VMs, syncs everything to vm2, starts the server, and loops traffic until you press Ctrl-C.

```bash
./run.sh --proto dtls --mode classical   # DTLS 1.2 with secp521r1 KEX
```

Each connection prints one row: timestamp, connection number, KEX group, cipher suite, verify code. `Verify: 0` means certificate validation succeeded. After the handshake the client sends `PING` and the server replies `PONG`; the server log line `Data OK: PING received, sending PONG.` proves the encrypted DTLS record was decrypted on vm2.

## Run the orchestrator directly

`run.sh` is the recommended entry point. Running the orchestrator directly skips dependency installs, PKI generation, the vm2 sync, and the C build, so you have to do those steps manually first.

1. Generate the PKI on **vm1**:

   ```bash
   source env.sh
   ./pki/gen.sh --proto dtls
   ```

   This produces:

   ```
   pki/out/ca/dtls/classical/ca-cert.pem
   pki/out/dtls/classical/server-cert.pem  server-key.pem
   ```

2. Build the C binaries and sync everything to **vm2**:

   ```bash
   make -C protocols/dtls

   rsync -a --mkpath protocols/dtls/      "$VM2_USER@$VM2_HOST:$VM2_REPO/protocols/dtls/"
   rsync -a --mkpath pki/out/ca/dtls/     "$VM2_USER@$VM2_HOST:$VM2_REPO/pki/out/ca/dtls/"
   rsync -a --mkpath pki/out/dtls/        "$VM2_USER@$VM2_HOST:$VM2_REPO/pki/out/dtls/"

   ssh "$VM2_USER@$VM2_HOST" "cd $VM2_REPO && make -C protocols/dtls"
   ```

3. Verify on **vm2** (run from repo root; must print `OK`):

   ```bash
   cd proto-testbed
   source env.sh

   os-lib/install/openssl-4.0/bin/openssl verify \
       -CAfile pki/out/ca/dtls/classical/ca-cert.pem \
       pki/out/dtls/classical/server-cert.pem
   ```

4. Start the orchestrator:

   ```bash
   bash orchestrator/dtls.sh classical
   ```

## Implementation notes

The C server (`server.c`) binds a UDP socket via `BIO_new_dgram`, loops accepting connections, and stays resident. The C client (`client.c`) outputs one line per connection in the format the orchestrator parses. `openssl s_server` cannot replace this because it calls `recvfrom` without first binding the socket and exits immediately under DTLS.
