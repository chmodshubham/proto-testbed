# IPsec Setup

vm1 establishes an IKEv2 SA with the strongSwan responder on vm2 in a loop. Each iteration negotiates IKE + ESP, runs one ICMP echo through the tunnel, and prints the IKE KEX group, ESP cipher, and verification result. Runs in classical or post-quantum mode.

| Mode      | Server cert | Client cert | IKE KEX    | IKE cipher            | ESP cipher  | Port |
| --------- | ----------- | ----------- | ---------- | --------------------- | ----------- | ---- |
| Classical | ECDSA P-256 | ECDSA P-256 | ECP-256    | AES-256-GCM + SHA-384 | AES-256-GCM | 4440 |
| PQC       | ECDSA P-256 | ECDSA P-256 | ML-KEM-768 | AES-256-GCM + SHA-384 | AES-256-GCM | 4441 |

ML-DSA certificate support is not available in strongSwan 6.0.6. Classical ECDSA certs are used for both modes; PQC applies to the IKE key exchange only (ML-KEM-768 via the built-in `ml` plugin).

## Pre-requisites

See the root [README.md](../../README.md) for VM setup, hardware, and per-protocol `env.sh` configuration. Install strongSwan 6.0.6 on both VMs first per [docs/strongswan.md](../../docs/strongswan.md).

Kernel XFRM modules must be present on both VMs. They usually load on first IPsec use; verify or load manually:

```bash
lsmod | grep -E "esp4|xfrm_user|xfrm_algo"
sudo modprobe esp4 xfrm_user xfrm_algo
```

## Run

`run.sh` generates the PKI on first run, syncs it to vm2, starts the responder, and loops traffic until you press Ctrl-C.

```bash
./run.sh --proto ipsec --mode classical   # ECP-256 KEX
./run.sh --proto ipsec --mode pqc         # ML-KEM-768 KEX
```

`--mode all` is not supported: two `charon` instances cannot share the host kernel XFRM state. Run modes sequentially instead.

Each connection prints one row: timestamp, connection number, IKE group, ESP cipher, verify code. `Verify: 0` means the IKE SA established and a single ICMP echo to `${VM2_IP}` succeeded through the tunnel.

## Run the orchestrator directly

`run.sh` is the recommended entry point. Running the orchestrator directly skips dependency installs, PKI generation, and the vm2 sync, so you have to do those steps manually first.

1. Generate the PKI on **vm1**:

   ```bash
   source env.sh
   ./pki/gen.sh --proto ipsec
   ```

   This produces:

   ```
   pki/out/ca/ipsec/classical/ca-cert.pem
   pki/out/ca/ipsec/pqc/ca-cert.pem
   pki/out/ipsec/classical/server-cert.pem  server-key.pem  client-cert.pem  client-key.pem
   pki/out/ipsec/pqc/server-cert.pem        server-key.pem  client-cert.pem  client-key.pem
   ```

2. Sync the certificates to **vm2**:

   ```bash
   rsync -a --mkpath pki/out/ca/ipsec/ "$VM2_USER@$VM2_HOST:$VM2_REPO/pki/out/ca/ipsec/"
   rsync -a --mkpath pki/out/ipsec/    "$VM2_USER@$VM2_HOST:$VM2_REPO/pki/out/ipsec/"
   ```

3. Verify on **vm2** (run from repo root; both must print `certificate trusted`):

   ```bash
   cd proto-testbed
   source env.sh

   os-lib/install/strongswan/bin/pki --verify \
       --in     pki/out/ipsec/classical/server-cert.pem \
       --cacert pki/out/ca/ipsec/classical/ca-cert.pem

   os-lib/install/strongswan/bin/pki --verify \
       --in     pki/out/ipsec/pqc/server-cert.pem \
       --cacert pki/out/ca/ipsec/pqc/ca-cert.pem
   ```

   Also confirm the `ml` plugin exposes ML-KEM-768:

   ```bash
   os-lib/install/strongswan/sbin/swanctl --list-algs | grep -i mlkem
   ```

   Must list `mlkem768` before proceeding.

4. Start the orchestrator:

   ```bash
   bash orchestrator/ipsec.sh classical
   bash orchestrator/ipsec.sh pqc
   ```
