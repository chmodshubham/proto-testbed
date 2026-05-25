# SSH Setup

vm1 = client, vm2 = server. Servers run on vm2; traffic is driven from vm1.

| Mode      | Key Type | KEX                   | Port |
| --------- | -------- | --------------------- | ---- |
| Classical | ED25519  | curve25519-sha256     | 4442 |
| PQC       | ED25519  | mlkem768x25519-sha256 | 4443 |

All commands run from the repo root. Every terminal session starts with:

```bash
cd /path/to/proto-testbed
source env.sh
```

## Prerequisites

- Ubuntu 24.04 LTS (x86_64) on both VMs
- Passwordless SSH from vm1 to vm2 (or set `VM2_PASSWORD` in env.sh)
- `sudo` access on both VMs

### Hardware requirements

| Resource     | Minimum | Notes                                                                             |
| ------------ | ------- | --------------------------------------------------------------------------------- |
| Architecture | x86_64  | Build target is `linux-x86_64`                                                    |
| CPU          | 1 core  | Build uses `make -j$(nproc)`; more cores reduce compile time (~2 min on 4 cores)  |
| RAM          | 64 MB   | sshd privilege separation adds one child per connection; idle footprint under 20 MB |
| Disk         | 50 MB   | Installed tree (`os-lib/install/openssh/`); source + build tree ~30 MB            |

## Step 1: Install build dependencies

Run on **both VMs**.

```bash
sudo apt-get install -y build-essential libpam0g-dev libssl-dev zlib1g-dev
```

If vm2 requires password auth from vm1, also install on **vm1**:

```bash
sudo apt-get install -y sshpass
```

## Step 2: Clone the repo

Run on **both VMs**.

```bash
git clone <repo-url> proto-testbed
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
export VM2_PASSWORD=""   # set if vm2 system SSH requires password auth
```

Sync to vm2:

```bash
source env.sh
rsync -a env.sh "$VM2_USER@$VM2_HOST:$VM2_REPO/"
```

## Step 4: Build OpenSSH 10.3p1

Run on **both VMs** from repo root.

```bash
mkdir -p os-lib/src
cd os-lib/src
curl -LO https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-10.3p1.tar.gz
tar xzf openssh-10.3p1.tar.gz
cd openssh-10.3p1

./configure \
    --prefix="$(cd ../../.. && pwd)/os-lib/install/openssh" \
    --sysconfdir="$(cd ../../.. && pwd)/os-lib/install/openssh/etc" \
    --with-ssl-dir=/usr \
    --with-pam \
    --with-privsep-path=/var/empty \
    --with-sandbox=seccomp_filter

make -j$(nproc)
sudo make install
```

Verify from repo root:

```bash
cd ../../..
os-lib/install/openssh/bin/ssh -Q kex | grep mlkem
```

Expected output: `mlkem768x25519-sha256`

## Step 5: Generate PKI

Run on **vm1** only, from repo root.

SSH uses raw key files (ED25519), not X.509 certificates.

```bash
source env.sh
./pki/gen.sh --proto ssh
```

Output:

```
pki/out/ssh/classical/host-key
pki/out/ssh/classical/host-key.pub
pki/out/ssh/classical/client-key
pki/out/ssh/classical/client-key.pub
pki/out/ssh/classical/authorized_keys
pki/out/ssh/pqc/   (same set)
```

## Step 6: Sync keys to vm2

The orchestrator syncs keys automatically at startup. To sync manually:

```bash
source env.sh

rsync -a --mkpath \
    pki/out/ssh/classical/ \
    "$VM2_USER@$VM2_HOST:$VM2_REPO/pki/out/ssh/classical/"

rsync -a --mkpath \
    pki/out/ssh/pqc/ \
    "$VM2_USER@$VM2_HOST:$VM2_REPO/pki/out/ssh/pqc/"
```

If `VM2_PASSWORD` is set, prefix rsync commands with:

```bash
RSYNC_RSH="sshpass -p '$VM2_PASSWORD' ssh" rsync ...
```

Verify on **vm2**:

```bash
ls pki/out/ssh/classical/host-key pki/out/ssh/classical/authorized_keys
```

## Step 7: Start server and run traffic

Run on **vm1** from repo root. Starts sshd on vm2, waits until ready, then loops connections. Press Ctrl-C to stop.

```bash
source env.sh

bash orchestrator/ssh.sh classical   # ED25519 key, curve25519-sha256 KEX
bash orchestrator/ssh.sh pqc         # ED25519 key, mlkem768x25519-sha256 KEX
```

Or via run.sh:

```bash
./run.sh --proto ssh --mode classical
./run.sh --proto ssh --mode pqc
```

Each connection prints one row: timestamp, protocol, connection number, KEX algorithm, cipher suite, result. `Verify: 0` means authentication succeeded.

## Key flags

| Flag                          | Description                                  |
| ----------------------------- | -------------------------------------------- |
| `-p <port>`                   | Connect to non-default port                  |
| `-i <key>`                    | Identity file for pubkey auth                |
| `-o KexAlgorithms=<list>`     | Comma-separated KEX algorithm list           |
| `-o StrictHostKeyChecking=no` | Skip known_hosts check (testbed only)        |
| `-o BatchMode=yes`            | Disable interactive prompts                  |
| `-v`                          | Verbose output (shows negotiated algorithms) |
| `-Q kex`                      | List supported KEX algorithms                |

KEX algorithms: `curve25519-sha256` (classical), `mlkem768x25519-sha256` (PQC hybrid, ML-KEM-768 + X25519, default in OpenSSH 10.0+).

## Verifying PQC negotiated

```bash
source env.sh
bash protocols/ssh/client.sh pqc 2>&1 | grep 'kex: algorithm'
```

Expected: `debug1: kex: algorithm: mlkem768x25519-sha256`

## Notes

- System sshd stays on port 22. Testbed sshd runs on `$PORT_SSH` / `$PORT_SSH_PQC`.
- sshd must run as root (privilege separation requires it on Linux).
- `authorized_keys` path is set in the sshd config at server launch time.
- Client uses `-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null` to avoid known_hosts conflicts between classical and PQC runs.
- If the ubuntu account on vm2 is locked (shadow entry `!`), the orchestrator unlocks it automatically before starting sshd. This is required for pubkey auth with `UsePAM no`.
- `VM2_PASSWORD` controls access to the vm2 system sshd (port 22) used by the orchestrator for management. The testbed sshd (ports 4442/4443) always uses pubkey-only auth regardless of this variable.
