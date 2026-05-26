# PQC Protocol Testbed

Two Ubuntu 24.04 VMs running TLS, mTLS, DTLS, QUIC, IPsec, and SSH side-by-side with a per-protocol toggle for post-quantum cryptography. `vm1` runs clients and the orchestrator; `vm2` runs servers.

## Topology

| Role | Hostname        | IP        | Runs                                  |
| ---- | --------------- | --------- | ------------------------------------- |
| vm1  | `$VM2_HOST` n/a | `$VM1_IP` | orchestrator + clients                |
| vm2  | `$VM2_HOST`     | `$VM2_IP` | protocol servers (TLS / IKEv2 / sshd) |

Both VMs must be Ubuntu 24.04 LTS (x86_64) on the same L3-reachable network.

## Protocol Support

| Protocol       | PQC | KEX (PQC)              | Port (classical / PQC) | Transport |
| -------------- | --- | ---------------------- | ---------------------- | --------- |
| TLS 1.2 / 1.3  | Yes | X25519MLKEM768         | 4433 / 4434            | TCP       |
| mTLS 1.2 / 1.3 | Yes | X25519MLKEM768         | 4435 / 4436            | TCP       |
| DTLS 1.2       | No  | n/a                    | 4437                   | UDP       |
| QUIC           | Yes | X25519MLKEM768         | 4438 / 4439            | UDP       |
| IPsec          | Yes | ML-KEM-768 (ml plugin) | 4440 / 4441            | UDP       |
| SSH            | Yes | mlkem768x25519-sha256  | 4442 / 4443            | TCP       |

## Step 1: Prepare both VMs

1. Provision two Ubuntu 24.04 hosts on the same network. Same subnet is simplest.
2. From vm1, set up passwordless SSH to vm2 (key-based). Verify:
   ```bash
   ssh ubuntu@<vm2-host>
   ```
   Must succeed without password prompt. If password is unavoidable, you can set `VM2_PASSWORD` later and the testbed falls back to `sshpass`.
3. Confirm `sudo` works on **both** VMs without password (or use `-S` style; only relevant for library builds and IPsec).

## Step 2: Open ports between vm1 and vm2

The orchestrator probes TCP reachability at startup and fails fast if a port is blocked. Open the testbed range on vm2's firewall (host firewall **and** any cloud network rule):

| Protocols         | Port range | Transport |
| ----------------- | ---------- | --------- |
| TLS, mTLS, SSH    | 4433–4443  | TCP       |
| DTLS, QUIC, IPsec | 4437–4441  | UDP       |

Restrict the source to vm1's IP or its security group; do not open to the public internet.

Verify reachability from vm1:

```bash
timeout 3 bash -c '</dev/tcp/<vm2-ip>/4433' && echo OPEN || echo BLOCKED
```

## Step 3: Clone the repo on both VMs

```bash
git clone https://github.com/chmodshubham/proto-testbed proto-testbed
cd proto-testbed
```

Identical path on both VMs is recommended (e.g. `/home/ubuntu/proto-testbed`).

## Step 4: Configure `env.sh` on vm1

Edit `env.sh` and set:

```bash
export VM2_USER=ubuntu
export VM2_HOST=<vm2-hostname>
export VM2_REPO="/home/ubuntu/proto-testbed"   # absolute path on vm2
export VM1_IP=<vm1-ip>
export VM2_IP=<vm2-ip>
export VM2_PASSWORD=""   # set only if vm2 SSH requires a password
```

### How to obtain each value

| Variable       | Where to run | Command                                                   | Notes                                                                                                                                                      |
| -------------- | ------------ | --------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `VM2_USER`     | vm2          | `whoami`                                                  | Login username used in `ssh user@host`. Usually `ubuntu` on cloud images.                                                                                  |
| `VM2_HOST`     | vm1          | same hostname or address used in `ssh user@host` from vm1 | Private DNS, public DNS, or IP. Confirm with `ssh "$VM2_USER@$VM2_HOST" hostname`.                                                                         |
| `VM2_REPO`     | vm2          | `cd ~/proto-testbed && pwd`                               | Absolute path. No tilde, no relative path.                                                                                                                 |
| `VM1_IP`       | vm1          | `hostname -I \| awk '{print $1}'`                         | First non-loopback IPv4. If multi-NIC, pick the one on the subnet shared with vm2.                                                                         |
| `VM2_IP`       | vm2          | `hostname -I \| awk '{print $1}'`                         | First non-loopback IPv4. Must be reachable from vm1 (`ping -c1 $VM2_IP` from vm1). Cert SAN is built from this value, so regenerate PKI after changing it. |
| `VM2_PASSWORD` | vm1          | leave empty for key-based SSH                             | Triggers `sshpass` fallback when non-empty.                                                                                                                |

Verify values resolve and vm2 is reachable:

```bash
source env.sh
echo "vm1: $VM1_IP   vm2: $VM2_IP   host: $VM2_HOST   repo: $VM2_REPO"
ssh "$VM2_USER@$VM2_HOST" "hostname; pwd; ls $VM2_REPO/env.sh"
```

Sync `env.sh` to vm2:

```bash
rsync -a env.sh "$VM2_USER@$VM2_HOST:$VM2_REPO/"
```

All port variables (`PORT_TLS`, `PORT_SSH`, etc.) are defined in `env.sh` and can be overridden there.

## Step 5: Build the libraries on both VMs

`os-lib/` is gitignored. Each VM must build the libraries you need locally. Follow the canonical guide per library — each covers apt deps, configure flags, build, and smoke test on **both** VMs:

| Library    | Build guide                              | Used by               |
| ---------- | ---------------------------------------- | --------------------- |
| OpenSSL    | [docs/openssl.md](docs/openssl.md)       | TLS, mTLS, DTLS, QUIC |
| strongSwan | [docs/strongswan.md](docs/strongswan.md) | IPsec                 |
| OpenSSH    | [docs/openssh.md](docs/openssh.md)       | SSH                   |

| Library    | Version | Installed at                  |
| ---------- | ------- | ----------------------------- |
| OpenSSL    | 4.0     | `os-lib/install/openssl-4.0/` |
| strongSwan | 6.0+    | `os-lib/install/strongswan/`  |
| OpenSSH    | 10.3p1  | `os-lib/install/openssh/`     |

Skip the libraries you do not plan to test (e.g. skip strongSwan if you will not run IPsec). Hardware requirements and protocol-specific build notes also appear in the per-protocol README (e.g. [protocols/tls/README.md](protocols/tls/README.md), [protocols/ipsec/README.md](protocols/ipsec/README.md)).

## Step 6: Generate PKI on vm1, sync to vm2

PKI is generated on vm1 only and synced to vm2. Generator: [`pki/gen.sh`](pki/gen.sh) (CA config in [`pki/ca.cnf`](pki/ca.cnf)).

```bash
source env.sh
./pki/gen.sh --proto all          # or --proto tls / ssh / ipsec / etc.
```

Sync the generated certs and keys to vm2:

```bash
rsync -a pki/out/ "$VM2_USER@$VM2_HOST:$VM2_REPO/pki/out/"
```

Verify on vm2:

```bash
ssh "$VM2_USER@$VM2_HOST" "ls $VM2_REPO/pki/out/"
```

Per-protocol PKI layout (what gets generated under `pki/out/` and where it is consumed) is documented in each protocol README: [TLS](protocols/tls/README.md), [mTLS](protocols/mtls/README.md), [DTLS](protocols/dtls/README.md), [QUIC](protocols/quic/README.md), [IPsec](protocols/ipsec/README.md), [SSH](protocols/ssh/README.md).

## Step 7: Run the testbed

```bash
./run.sh [--proto PROTO] [--mode MODE] [--help]
```

| Flag      | Values                                         | Default |
| --------- | ---------------------------------------------- | ------- |
| `--proto` | `tls` `mtls` `dtls` `quic` `ipsec` `ssh` `all` | `all`   |
| `--mode`  | `classical` `pqc` `all`                        | `all`   |

Examples:

```bash
./run.sh                               # all protocols, both modes
./run.sh --proto tls                   # TLS classical + PQC in parallel
./run.sh --proto tls --mode classical  # TLS classical only
./run.sh --proto ssh --mode pqc        # SSH PQC only
./run.sh --proto ipsec --mode pqc      # IPsec PQC only (two modes cannot run together)
./run.sh --proto all --mode classical  # all protocols, classical only
```

`run.sh` automatically:

1. Installs missing apt deps for the selected protocol(s).
2. Syncs the repo to vm2 (excludes `os-lib/` and `.git/`).
3. Kills stale servers on vm2 holding protocol ports.
4. Starts the server(s) on vm2 via SSH.
5. Waits until each server is ready.
6. Probes TCP reachability from vm1 to each server port (fails fast if blocked).
7. Loops traffic and prints one row per connection.

Notes:

- DTLS has no PQC mode (DTLS 1.2; ML-KEM requires TLS 1.3).
- IPsec cannot run classical and PQC in parallel (charon holds the kernel XFRM socket).
- If `VM2_PASSWORD` is set, install `sshpass` on vm1 first.

To skip the TCP reachability probe (when you know the firewall is open):

```bash
TESTBED_SKIP_REACH=1 ./run.sh --proto tls
```

## Step 8: Read the output

```
Timestamp             Protocol         Conn    Key Exchange                 Cipher Suite                         Verify
--------------------- ---------------- ------- ---------------------------- ------------------------------------ ------
2026-05-26 00:21:14   tls/classical    #1      X25519                       TLS_AES_256_GCM_SHA384               0
2026-05-26 00:21:14   tls/pqc          #1      X25519MLKEM768               TLS_AES_256_GCM_SHA384               0
```

- `Verify: 0` — handshake plus application-layer round-trip succeeded.
- `Verify: FAILED` or `unknown` columns — see Troubleshooting below.

Press **Ctrl-C** to stop. All servers on vm2 are torn down on exit.

## Step 9: Run a single orchestrator directly (optional)

Bypass `run.sh` for finer control. Source `env.sh` first:

```bash
source env.sh

bash orchestrator/tls.sh   classical   # or pqc
bash orchestrator/mtls.sh  classical   # or pqc
bash orchestrator/dtls.sh  classical   # classical only
bash orchestrator/quic.sh  classical   # or pqc
bash orchestrator/ipsec.sh pqc         # or classical (not both at once)
bash orchestrator/ssh.sh   classical   # or pqc
```

Each orchestrator starts its server on vm2, waits until ready, probes reachability, then loops traffic. Press Ctrl-C to stop. Orchestrator source: [`orchestrator/`](orchestrator/) (shared helpers in [`orchestrator/common.sh`](orchestrator/common.sh)).

## Manual repo sync (rare)

`run.sh` syncs automatically. To sync manually without starting a protocol:

```bash
source env.sh
rsync -a --delete --exclude='os-lib/' --exclude='.git/' \
    "${PWD}/" "${VM2_USER}@${VM2_HOST}:${VM2_REPO}/"
```

With password auth:

```bash
RSYNC_RSH="sshpass -p '$VM2_PASSWORD' ssh" rsync -a --delete \
    --exclude='os-lib/' --exclude='.git/' \
    "${PWD}/" "${VM2_USER}@${VM2_HOST}:${VM2_REPO}/"
```

## Per-protocol details

Each protocol has a README covering algorithm choices, ports, key flags, and verification:

| Protocol       | README                                                 |
| -------------- | ------------------------------------------------------ |
| TLS 1.2 / 1.3  | [protocols/tls/README.md](protocols/tls/README.md)     |
| mTLS 1.2 / 1.3 | [protocols/mtls/README.md](protocols/mtls/README.md)   |
| DTLS 1.2       | [protocols/dtls/README.md](protocols/dtls/README.md)   |
| QUIC           | [protocols/quic/README.md](protocols/quic/README.md)   |
| IPsec          | [protocols/ipsec/README.md](protocols/ipsec/README.md) |
| SSH            | [protocols/ssh/README.md](protocols/ssh/README.md)     |
