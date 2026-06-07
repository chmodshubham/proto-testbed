# SSH Setup

vm1 opens an SSH session to a testbed `sshd` running on vm2 in a loop. Each connection completes a full SSH handshake, authenticates via the testbed key pair, and prints the negotiated KEX, cipher, and verification result. Runs in classical or post-quantum mode. The system `sshd` on port 22 is untouched.

| Mode      | Key Type | KEX                   | Port |
| --------- | -------- | --------------------- | ---- |
| Classical | ED25519  | curve25519-sha256     | 4442 |
| PQC       | ED25519  | mlkem768x25519-sha256 | 4443 |

SSH uses raw key files (ED25519), not X.509 certificates. PQC applies to the KEX only (ML-KEM-768 + X25519 hybrid, default in OpenSSH 10.0+).

## Pre-requisites

See the root [README.md](../../README.md) for VM setup, hardware, and per-protocol `env.sh` configuration. Install OpenSSH 10.3p1 on both VMs first per [docs/openssh.md](../../docs/openssh.md).

If vm2 requires password auth from vm1, also install `sshpass` on **vm1**:

```bash
sudo apt-get install -y sshpass
```

## Run

`run.sh` generates the SSH keys on first run, syncs them (and the repo) to vm2, starts the testbed `sshd`, and loops connections until you press Ctrl-C.

```bash
./run.sh --proto ssh --mode classical   # curve25519-sha256 KEX
./run.sh --proto ssh --mode pqc         # mlkem768x25519-sha256 KEX
./run.sh --proto ssh --mode all         # both modes in parallel
```

Each connection prints one row: timestamp, connection number, KEX algorithm, cipher, verify code. `Verify: 0` means authentication succeeded.

## Run the orchestrator directly

`run.sh` is the recommended entry point. Running the orchestrator directly skips dependency installs, key generation, and the vm2 sync, so you have to do those steps manually first.

1. Generate the keys on **vm1**:

   ```bash
   source env.sh
   ./pki/gen.sh --proto ssh
   ```

   This produces:

   ```
   pki/out/ssh/classical/host-key  host-key.pub  client-key  client-key.pub  authorized_keys
   pki/out/ssh/pqc/        (same set)
   ```

2. Sync the keys to **vm2**:

   ```bash
   rsync -a --mkpath pki/out/ssh/classical/ "$VM2_USER@$VM2_HOST:$VM2_REPO/pki/out/ssh/classical/"
   rsync -a --mkpath pki/out/ssh/pqc/       "$VM2_USER@$VM2_HOST:$VM2_REPO/pki/out/ssh/pqc/"
   ```

   If `VM2_PASSWORD` is set, prefix each rsync with `RSYNC_RSH="sshpass -p '$VM2_PASSWORD' ssh"`.

3. Verify on **vm2** (run from repo root; both must list the files):

   ```bash
   cd proto-testbed
   source env.sh

   ls pki/out/ssh/classical/host-key pki/out/ssh/classical/authorized_keys
   ls pki/out/ssh/pqc/host-key       pki/out/ssh/pqc/authorized_keys
   ```

4. Start the orchestrator:

   ```bash
   bash orchestrator/ssh.sh classical
   bash orchestrator/ssh.sh pqc
   ```
