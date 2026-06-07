# PQC Protocol Testbed

Two Ubuntu 24.04 VMs running TLS, mTLS, DTLS, QUIC, IPsec, and SSH side-by-side with a per-protocol toggle for post-quantum cryptography. `vm1` runs clients and the orchestrator; `vm2` runs servers.

## Topology

| Role | Hostname    | IP        | Runs                                  |
| ---- | ----------- | --------- | ------------------------------------- |
| vm1  | n/a         | `$VM1_IP` | orchestrator + clients                |
| vm2  | `$VM2_HOST` | `$VM2_IP` | protocol servers (TLS / IKEv2 / sshd) |

Both VMs must be Ubuntu 24.04 LTS (x86_64) on the same L3-reachable network.

## Hardware Requirements

Minimum per VM:

| Resource     | Minimum |
| ------------ | ------- |
| Architecture | x86_64  |
| CPU          | 2 cores |
| RAM          | 2 GB    |
| Disk         | 10 GB   |

## Protocol Support

| Protocol       | PQC | KEX (PQC)                             | Port (classical / PQC) | Transport |
| -------------- | --- | ------------------------------------- | ---------------------- | --------- |
| TLS 1.2 / 1.3  | Yes | X25519MLKEM768                        | 4433 / 4434            | TCP       |
| mTLS 1.2 / 1.3 | Yes | SecP384r1MLKEM1024, X25519MLKEM768    | 4435 / 4436            | TCP       |
| DTLS 1.2       | No  | n/a                                   | 4437                   | UDP       |
| QUIC           | Yes | X25519MLKEM768                        | 4438 / 4439            | UDP       |
| IPsec          | Yes | ML-KEM-768 (ml plugin)                | 4440 / 4441            | UDP       |
| SSH            | Yes | mlkem768x25519-sha256                 | 4442 / 4443            | TCP       |

## Setup

### 1. Prerequisites

- Ubuntu 24.04 LTS (x86_64) on both VMs.
- Passwordless SSH from vm1 to vm2 (key-based), or set `VM2_PASSWORD` in `env.sh` for `sshpass` fallback.
- `sudo` access on both VMs (required for library builds and IPsec).
- IPsec only: kernel 5.1+ with `esp4`, `xfrm_user`, `xfrm_algo` modules.
- Open ports 4433-4443 (TCP and UDP) from vm1 to vm2 in firewall and any cloud security group.

### 2. Clone the repo on both VMs

```bash
git clone https://github.com/chmodshubham/proto-testbed proto-testbed
cd proto-testbed/
```

Use the same path on both VMs (e.g. `/home/ubuntu/proto-testbed`).

### 3. Configure `env.sh` on vm1

Each protocol reads its own `<PROTO>_*` variables. Set all six for every protocol you plan to run (`PROTO` is one of `TLS MTLS DTLS QUIC IPSEC SSH`):

```bash
# TLS — repeat the same six for MTLS_, DTLS_, QUIC_, IPSEC_, SSH_
export TLS_VM1_IP=<vm1-ip>
export TLS_VM2_IP=<vm2-ip>
export TLS_VM2_USER=ubuntu
export TLS_VM2_HOST=<vm2-hostname>
export TLS_VM2_REPO="/home/ubuntu/proto-testbed"   # absolute path on vm2
export TLS_VM2_PASSWORD=""                         # set only if password SSH is required
```

To point all protocols at the same VM pair, use identical values across all six prefixes. `VM2_REPO` must be an absolute path.

To route TLS, mTLS, or QUIC clients through a load balancer, set `NLB_HOST` to the load balancer DNS name or IP. When set, `run.sh` adds it to the server cert SAN and clients connect through it instead of directly to `VM2_IP`. Leave empty to connect directly.

Sync `env.sh` to vm2 after any change:

```bash
rsync -a env.sh "$TLS_VM2_USER@$TLS_VM2_HOST:$TLS_VM2_REPO/"
```

### 4. Build the libraries on both VMs

`os-lib/` is gitignored. Each VM must build the libraries locally.

Run the automated setup script (clones the repo if not already present, builds all libraries):

```bash
bash lib-setup.sh [--skip-openssl] [--skip-strongswan] [--skip-openssh]
```

Or build manually using the per-library guides:

| Library    | Version | Build guide                              | Used by               |
| ---------- | ------- | ---------------------------------------- | --------------------- |
| OpenSSL    | 4.0     | [docs/openssl.md](docs/openssl.md)       | TLS, mTLS, DTLS, QUIC |
| strongSwan | 6.0+    | [docs/strongswan.md](docs/strongswan.md) | IPsec                 |
| OpenSSH    | 10.3p1  | [docs/openssh.md](docs/openssh.md)       | SSH                   |

Skip libraries not needed (e.g. `--skip-strongswan` if not running IPsec).

### 5. Run the testbed

```bash
./run.sh [--proto PROTO] [--mode MODE]
```

| Flag      | Values                                         | Default |
| --------- | ---------------------------------------------- | ------- |
| `--proto` | `tls` `mtls` `dtls` `quic` `ipsec` `ssh` `all` | `all`   |
| `--mode`  | `classical` `pqc` `all`                        | `all`   |

```bash
./run.sh                               # all protocols, both modes
./run.sh --proto tls --mode classical  # TLS classical only
./run.sh --proto tls --mode all        # TLS classical + PQC in parallel
./run.sh --proto ipsec --mode pqc      # IPsec PQC only (two modes cannot run in parallel)
```

`run.sh` auto-generates missing PKI, syncs the repo to vm2, starts servers, and loops traffic. Press **Ctrl-C** to stop the traffic loop.

The **nginx server (TLS / QUIC) is persistent**: it stays running on vm2 after the traffic loop stops, and is reused on the next run instead of being restarted. Stop it explicitly with:

```bash
./nginx-server.sh stop   --proto tls   # stop both modes
./nginx-server.sh status --proto quic  # UP/DOWN per mode
./nginx-server.sh start  --proto tls --mode pqc
```

Other servers (mTLS, DTLS, IPsec, SSH) are still torn down when `run.sh` exits.

Notes:

- DTLS has no PQC mode (DTLS 1.2; ML-KEM requires TLS 1.3).
- IPsec cannot run classical and PQC in parallel (charon holds the kernel XFRM socket).
- If `VM2_PASSWORD` is set, install `sshpass` on vm1 first: `sudo apt-get install -y sshpass`.
- After regenerating PKI/certs for TLS or QUIC, run `./nginx-server.sh stop` first so the next run starts with the new cert.
- The TLS and QUIC servers support reverse proxy mode. Set `TLS_PROXY_HOST` + `TLS_PROXY_PORT` (or the QUIC equivalents) in `env.sh` to forward traffic to a backend; nginx restarts automatically when the vars change. See [protocols/tls/README.md](protocols/tls/README.md#reverse-proxy-optional) and [protocols/quic/README.md](protocols/quic/README.md#reverse-proxy-optional).

## Output

```
Timestamp             Protocol         Conn    Key Exchange                 Cipher Suite                         Verify
--------------------- ---------------- ------- ---------------------------- ------------------------------------ ------
2026-05-26 00:21:14   tls/classical    #1      X25519                       ECDHE-ECDSA-AES256-GCM-SHA384        0
2026-05-26 00:21:14   tls/pqc          #1      X25519MLKEM768               TLS_AES_256_GCM_SHA384               0
```

`Verify: 0` means the handshake and application-layer round-trip both succeeded.

## Per-protocol details

| Protocol       | README                                                 |
| -------------- | ------------------------------------------------------ |
| TLS 1.2 / 1.3  | [protocols/tls/README.md](protocols/tls/README.md)     |
| mTLS 1.2 / 1.3 | [protocols/mtls/README.md](protocols/mtls/README.md)   |
| DTLS 1.2       | [protocols/dtls/README.md](protocols/dtls/README.md)   |
| QUIC           | [protocols/quic/README.md](protocols/quic/README.md)   |
| IPsec          | [protocols/ipsec/README.md](protocols/ipsec/README.md) |
| SSH            | [protocols/ssh/README.md](protocols/ssh/README.md)     |
