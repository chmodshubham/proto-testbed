# PQC Protocol Testbed

Two Ubuntu 24.04 VMs running TLS, mTLS, DTLS, QUIC, IPsec, and SSH side-by-side with a per-protocol toggle for post-quantum cryptography. vm1 runs clients and the orchestrator; vm2 runs servers.

## Quick Start

```bash
cd /path/to/proto-testbed
./run.sh
```

`run.sh` sources `env.sh` automatically. No manual sourcing needed.

## run.sh Options

```
./run.sh [--proto PROTO] [--mode MODE] [--help]
```

| Flag      | Values                                         | Default |
| --------- | ---------------------------------------------- | ------- |
| `--proto` | `tls` `mtls` `dtls` `quic` `ipsec` `ssh` `all` | `all`   |
| `--mode`  | `classical` `pqc` `all`                        | `all`   |

```bash
./run.sh                               # all protocols, both modes
./run.sh --proto tls                   # TLS classical + PQC in parallel
./run.sh --proto tls --mode classical  # TLS classical only
./run.sh --proto tls --mode pqc        # TLS PQC only
./run.sh --proto ssh --mode pqc        # SSH PQC only
./run.sh --proto ipsec --mode pqc      # IPsec PQC only (two modes can't run together)
./run.sh --proto all --mode classical  # all protocols, classical only
```

Press Ctrl-C to stop. All servers on vm2 are stopped on exit.

Notes:

- DTLS has no PQC mode (DTLS 1.2 only; ML-KEM requires TLS 1.3).
- IPsec cannot run classical and PQC in parallel (charon holds the kernel XFRM socket). Specify a mode explicitly or it defaults to `pqc`.
- If `VM2_PASSWORD` is set in `env.sh`, install `sshpass` on vm1 first.

## What run.sh Does

1. Checks and installs missing apt dependencies for the selected protocol(s).
2. Syncs the repo to vm2 via rsync (excludes `os-lib/` and `.git/`).
3. Kills any stale servers on vm2 holding protocol ports.
4. Starts the server(s) on vm2 via SSH.
5. Waits until each server is ready.
6. Loops traffic from vm1 and prints one row per connection:

```
Timestamp             Protocol         Conn    Key Exchange                 Cipher Suite                         Verify
--------------------- ---------------- ------- ---------------------------- ------------------------------------ ------
2026-05-26 00:21:14   tls/classical    #1      X25519                       TLS_AES_256_GCM_SHA384               0
2026-05-26 00:21:14   tls/pqc          #1      X25519MLKEM768               TLS_AES_256_GCM_SHA384               0
```

`Verify: 0` means certificate or key validation succeeded.

## Running a Single Protocol Directly

You can run any orchestrator directly without `run.sh`. Source `env.sh` first.

```bash
source env.sh

bash orchestrator/tls.sh  classical   # or pqc
bash orchestrator/mtls.sh classical   # or pqc
bash orchestrator/dtls.sh classical   # classical only
bash orchestrator/quic.sh classical   # or pqc
bash orchestrator/ipsec.sh pqc        # or classical (not both at once)
bash orchestrator/ssh.sh  classical   # or pqc
```

Each orchestrator starts its server on vm2, waits until ready, then loops traffic. Press Ctrl-C to stop.

## Protocol Summary

| Protocol | PQC | KEX (PQC)              | Port (classical / PQC) | Transport |
| -------- | --- | ---------------------- | ---------------------- | --------- |
| TLS 1.3  | Yes | X25519MLKEM768         | 4433 / 4434            | TCP       |
| mTLS 1.3 | Yes | X25519MLKEM768         | 4435 / 4436            | TCP       |
| DTLS 1.2 | No  | n/a                    | 4437                   | UDP       |
| QUIC     | Yes | X25519MLKEM768         | 4438 / 4439            | UDP       |
| IPsec    | Yes | ML-KEM-768 (ml plugin) | 4440 / 4441            | UDP       |
| SSH      | Yes | mlkem768x25519-sha256  | 4442 / 4443            | TCP       |

## env.sh Configuration

Edit `env.sh` before first use:

```bash
export VM2_USER=ubuntu
export VM2_HOST=<vm2-hostname>
export VM2_REPO="/home/ubuntu/proto-testbed"   # must be absolute path
export VM1_IP=<vm1-ip>
export VM2_IP=<vm2-ip>
export VM2_PASSWORD=""   # set if vm2 system SSH requires a password
```

All port variables (`PORT_TLS`, `PORT_SSH`, etc.) are defined in `env.sh` and can be overridden there.

## Setup Guides

Each protocol has a README with full build, PKI, and run instructions. Steps 1-3 (dependencies, repo clone, env.sh) are shared. Complete them once, then follow the protocol-specific steps.

| Protocol | README                                                 |
| -------- | ------------------------------------------------------ |
| TLS 1.3  | [protocols/tls/README.md](protocols/tls/README.md)     |
| mTLS 1.3 | [protocols/mtls/README.md](protocols/mtls/README.md)   |
| DTLS 1.2 | [protocols/dtls/README.md](protocols/dtls/README.md)   |
| QUIC     | [protocols/quic/README.md](protocols/quic/README.md)   |
| IPsec    | [protocols/ipsec/README.md](protocols/ipsec/README.md) |
| SSH      | [protocols/ssh/README.md](protocols/ssh/README.md)     |

## Libraries Used

| Library    | Version | Installed at                  |
| ---------- | ------- | ----------------------------- |
| OpenSSL    | 4.0     | `os-lib/install/openssl-4.0/` |
| strongSwan | 6.0+    | `os-lib/install/strongswan/`  |
| OpenSSH    | 10.3p1  | `os-lib/install/openssh/`     |

All libraries are built from source into `os-lib/install/`. Nothing is installed system-wide. `os-lib/` is gitignored and must be built independently on each VM.

Build guides (Step 4 in each README):

| Library    | Build guide                                                     |
| ---------- | --------------------------------------------------------------- |
| OpenSSL    | [protocols/tls/README.md](protocols/tls/README.md#step-4-build-openssl-40) — used by TLS, mTLS, DTLS, QUIC |
| strongSwan | [protocols/ipsec/README.md](protocols/ipsec/README.md#step-4-build-strongswan-606) — used by IPsec |
| OpenSSH    | [protocols/ssh/README.md](protocols/ssh/README.md#step-4-build-openssh-103p1) — used by SSH |
