# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Writing Style

Apply these rules to all code, scripts, configs, and documentation written in this repo:

- Use plain, technical language. No filler phrases, marketing tone, or conversational padding.
- No emojis or icons anywhere.
- No horizontal rules (no `---` dividers in markdown).
- No em dashes. Use a comma, colon, or rewrite the sentence instead.
- Comments in code and configs must describe what a block does or what a setting controls. Do not write comments about why a change was made, what issue it solves, or who added it.
- Keep comments short. One line is preferred. Skip the comment entirely if the name already explains it.
- In documentation, use short sentences and direct structure. Tables and lists over prose where possible.

## What This Is

PQC Protocol Testbed: two Ubuntu 24.04 VMs running TLS / mTLS / DTLS / QUIC / IPsec / SSH side-by-side with a per-protocol toggle for PQC on/off. An orchestrator starts/stops any subset and pushes dummy traffic, verifying bidirectional application-layer data on every connection.

## VM Topology

| Role | Hostname    | IP          | SSH                   |
| ---- | ----------- | ----------- | --------------------- |
| vm1  | `$VM1_IP`   | `$VM1_IP`   | set in `env.sh`       |
| vm2  | `$VM2_HOST` | `$VM2_IP`   | `$VM2_USER@$VM2_HOST` |

Both VMs share a single NIC. Protocol servers run on vm2; clients run on vm1.

## Repo Layout (current state)

```
proto-testbed/
├── CLAUDE.md
├── README.md
├── env.sh                       # source from repo root before any command; defines all ports and VM vars
├── orchestrator/
│   ├── tls.sh                   # start TLS server on vm2, run traffic loop until Ctrl-C
│   ├── mtls.sh                  # same for mTLS
│   ├── dtls.sh                  # same for DTLS (UDP)
│   ├── ipsec.sh                 # start IPsec server on vm2, client charon on vm1, loop traffic
│   ├── quic.sh                  # same for QUIC (UDP)
│   └── ssh.sh                   # start sshd on vm2, loop SSH connections until Ctrl-C
├── pki/
│   ├── ca.cnf                   # OpenSSL CA config; SANs: IP $VM2_IP, DNS $VM2_HOST — patched at gen time
│   ├── gen.sh                   # builds CA + classical and PQC leaves (TLS, mTLS, DTLS, QUIC, IPsec, SSH)
│   └── out/                     # GITIGNORED
│       ├── ca/
│       │   ├── tls/
│       │   │   ├── classical/   #   ca-cert.pem, ca-key.pem, db/
│       │   │   └── pqc/         #   ca-cert.pem, ca-key.pem, db/
│       │   ├── mtls/
│       │   │   ├── classical/   #   ca-cert.pem, ca-key.pem, db/
│       │   │   └── pqc/         #   ca-cert.pem, ca-key.pem, db/
│       │   ├── dtls/
│       │   │   └── classical/   #   ca-cert.pem, ca-key.pem, db/
│       │   ├── quic/
│       │   │   ├── classical/   #   ca-cert.pem, ca-key.pem, db/
│       │   │   └── pqc/         #   ca-cert.pem, ca-key.pem, db/
│       │   └── ipsec/
│       │       ├── classical/   #   ca-cert.pem, ca-key.pem (strongSwan pki, no db)
│       │       └── pqc/         #   ca-cert.pem, ca-key.pem
│       ├── tls/
│       │   ├── classical/       #   server-cert.pem, server-key.pem
│       │   └── pqc/             #   server-cert.pem, server-key.pem
│       ├── mtls/
│       │   ├── classical/       #   server-cert.pem, server-key.pem, client-cert.pem, client-key.pem
│       │   └── pqc/             #   server-cert.pem, server-key.pem, client-cert.pem, client-key.pem
│       ├── dtls/
│       │   └── classical/       #   server-cert.pem, server-key.pem
│       ├── quic/
│       │   ├── classical/       #   server-cert.pem, server-key.pem
│       │   └── pqc/             #   server-cert.pem, server-key.pem
│       ├── ipsec/
│       │   ├── classical/       #   server-cert.pem, server-key.pem, client-cert.pem, client-key.pem
│       │   └── pqc/             #   server-cert.pem, server-key.pem, client-cert.pem, client-key.pem
│       └── ssh/
│           ├── classical/       #   host-key, host-key.pub, client-key, client-key.pub, authorized_keys
│           └── pqc/             #   host-key, host-key.pub, client-key, client-key.pub, authorized_keys
├── protocols/
│   ├── tls/
│   │   ├── config.sh            # sourced by server.sh, client.sh, orchestrator/tls.sh
│   │   ├── server.sh            # s_server wrapper; run on vm2
│   │   ├── client.sh            # s_client wrapper; run on vm1
│   │   └── README.md
│   ├── mtls/
│   │   ├── config.sh            # sourced by server.sh, client.sh, orchestrator/mtls.sh
│   │   ├── server.sh            # s_server wrapper with -Verify 1; run on vm2
│   │   ├── client.sh            # s_client wrapper with -cert/-key; run on vm1
│   │   └── README.md
│   ├── dtls/
│   │   ├── config.sh            # sourced by server.sh, client.sh, orchestrator/dtls.sh
│   │   ├── server.sh            # execs protocols/dtls/server binary; run on vm2
│   │   ├── client.sh            # execs protocols/dtls/client binary; run on vm1
│   │   ├── server.c             # C server: binds UDP, loops via BIO_new_dgram
│   │   ├── client.c             # C client: connects, prints group/cipher/verify
│   │   ├── Makefile             # builds server and client against os-lib/install/openssl-4.0
│   │   └── README.md
│   ├── quic/
│   │   ├── config.sh            # sourced by server.sh, client.sh, orchestrator/quic.sh
│   │   ├── server.sh            # execs protocols/quic/server binary; run on vm2
│   │   ├── client.sh            # execs protocols/quic/client binary; run on vm1
│   │   ├── server.c             # C server: binds UDP, OSSL_QUIC_server_method, ALPN hq-interop
│   │   ├── client.c             # C client: connects, prints group/cipher/verify
│   │   ├── Makefile             # builds server and client against os-lib/install/openssl-4.0
│   │   └── README.md
│   ├── ipsec/
│   │   ├── config.sh            # sourced by server.sh, client.sh, orchestrator/ipsec.sh
│   │   ├── server.sh            # starts charon IKEv2 responder; run on vm2
│   │   ├── client.sh            # starts charon IKEv2 initiator, initiates one SA; run on vm1
│   │   └── README.md
│   └── ssh/
│       ├── config.sh            # sourced by server.sh, client.sh, orchestrator/ssh.sh
│       ├── server.sh            # sshd wrapper (generates temp config, execs sshd -D); run on vm2
│       ├── client.sh            # ssh client wrapper; run on vm1
│       └── README.md
└── os-lib/                      # GITIGNORED — manual installs land here
    ├── src/
    └── install/
```

Target layout for each new protocol (e.g. `protocols/quic/`):

```
protocols/<proto>/
├── config.sh       # sourced by server.sh, client.sh, orchestrator/<proto>.sh
├── server.sh       # server wrapper; run on vm2
├── client.sh       # client wrapper; run on vm1
└── README.md
```

And a corresponding `orchestrator/<proto>.sh` that sources `protocols/<proto>/config.sh`.

If the protocol cannot be driven by `openssl s_server`/`s_client` (e.g. DTLS needs
a persistent UDP `bind`), add `server.c`, `client.c`, and a `Makefile` alongside
the shell wrappers. The shell wrappers exec the binary; the orchestrator calls the
client binary directly for the traffic loop.

## env.sh

Must be sourced from the repo root before running any script:

```bash
cd /path/to/proto-testbed
source env.sh
```

Variables set:

| Variable        | Description                                              |
| --------------- | -------------------------------------------------------- |
| `LD_LIBRARY_PATH` | Prepends `os-lib/install/openssl-4.0/lib`             |
| `VM1_IP`        | IP address of vm1                                        |
| `VM2_IP`        | IP address of vm2                                        |
| `VM2_USER`      | SSH username for vm2                                     |
| `VM2_HOST`      | SSH hostname for vm2                                     |
| `VM2_REPO`      | Absolute path to the repo on vm2 (no tilde)              |
| `VM2_PASSWORD`  | Password for vm2 system SSH; empty for key-based auth    |
| `PORT_TLS`      | TLS classical port (default 4433)                        |
| `PORT_TLS_PQC`  | TLS PQC port (default 4434)                              |
| `PORT_MTLS`     | mTLS classical port (default 4435)                       |
| `PORT_MTLS_PQC` | mTLS PQC port (default 4436)                             |
| `PORT_DTLS`     | DTLS server port (default 4437)                          |
| `PORT_QUIC`     | QUIC classical port (default 4438)                       |
| `PORT_QUIC_PQC` | QUIC PQC port (default 4439)                             |
| `PORT_IPSEC`    | IPsec classical port (default 4440)                      |
| `PORT_IPSEC_PQC`| IPsec PQC port (default 4441)                            |
| `PORT_SSH`      | SSH classical port (default 4442)                        |
| `PORT_SSH_PQC`  | SSH PQC port (default 4443)                              |

`VM2_*` vars are used only on vm1 (orchestrator scripts). vm2 does not need them.

`VM2_REPO` must be an absolute path. Tilde paths break heredoc expansion over SSH.

All scripts use `${PORT_X:?PORT_X not set. Source env.sh from repo root.}` so they fail immediately if env.sh was not sourced. C binaries read ports via `getenv()` with a compile-time fallback.

## Key Decisions

- All libraries built manually into `os-lib/install/<lib>/`. No system PATH or `ldconfig` pollution.
- `LD_LIBRARY_PATH` set with `${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}` form to avoid a trailing colon when the variable is unset.
- Each protocol/mode gets its own CA under `pki/out/ca/<proto>/<mode>/`. Each CA has an isolated `db/` directory (index, serial, newcerts). No shared CA database.
- `GROUPS` is a bash built-in (expands to numeric GIDs). Use `TLS_GROUPS` or `<PROTO>_GROUPS` for KEX group lists.
- System `sshd` stays on port 22; testbed `sshd` on `$PORT_SSH` (default 4442).
- `VM2_PASSWORD`: when set, `ssh_vm2` and `rsync_vm2` helpers in `orchestrator/common.sh` prepend `sshpass`; testbed sshd always uses pubkey-only regardless.
- PQC: hybrid ML-KEM-768 KEX everywhere. Certs: ML-DSA-65 leaves where the protocol accepts PQ signatures, else classical leaf signed by PQ CA.
- CSR tempfiles use `mktemp` + `trap 'rm -f "$CSR"' RETURN` for cleanup on error.

## Logging Standard

All scripts use a `log()` helper. Use this exact pattern in every new script:

```bash
# Scripts with timestamps (orchestrator, server, client):
log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2"; }

# Interactive scripts without timestamps (pki/gen.sh style):
log() { printf '[%s] %s\n' "$1" "$2"; }
```

Usage: `log INFO "message"` / `log ERROR "message"` / `log DEBUG "message"`

Log levels: `INFO`, `ERROR`, and `DEBUG`.

`DEBUG` lines are suppressed unless `TESTBED_DEBUG=1` is set in the environment.
They carry diagnostic detail (e.g. terminal line-discipline state) and are off by
default so normal output is unchanged.

The orchestrator `common.sh` provides `log_tty_state <stage>`: a `DEBUG` helper
that records the live tty flags (`onlcr`, `opost`, `icrnl`) at a stage boundary.
Used to locate where terminal output corruption begins. Also gated on `TESTBED_DEBUG=1`.

Output format: `YYYY-MM-DD HH:MM:SS [INFO] Message text.`

Message style:
- Capitalise first word.
- Label lines use aligned colons: `log INFO "Mode:               $MODE"`
- Action lines: `log INFO "Starting TLS server (${MODE}) on ${VM2_HOST} ..."`
- Completion lines: `log INFO "Server is ready and accepting connections."`
- Error lines: full sentence, actionable. `log ERROR "Server failed to start within 10s. Check /tmp/tls-server.log on ${VM2_HOST}."`

Traffic table (orchestrator scripts): use `printf` columnar format. Strip raw OpenSSL prefixes from captured values before printing:

```bash
KEX=$(  printf '%s' "$RESULT" | grep -oE 'Temp Key: [^,]+|group: \S+' | sed 's/^Temp Key: //;s/^group: //' | head -1 || true)
CIPH=$( printf '%s' "$RESULT" | grep -oE 'Cipher is \S+'               | sed 's/^Cipher is //'             | head -1 || true)
RC=$(   printf '%s' "$RESULT" | grep -oE 'Verify return code: [0-9]+'  | sed 's/^Verify return code: //'   | head -1 || true)
```

## Libraries

| Lib        | Version | Install path                  |
| ---------- | ------- | ----------------------------- |
| OpenSSL    | 4.0     | `os-lib/install/openssl-4.0/` |
| strongSwan | 6.0+    | `os-lib/install/strongswan/`  |
| OpenSSH    | 10.3p1  | `os-lib/install/openssh/`     |

strongSwan must be built against system OpenSSL headers (not the 4.0 install). If built against OpenSSL 4.0 headers, the openssl plugin registers ML-KEM via OpenSSL NIDs that are absent in the system runtime library (3.x), causing `creating KE payload failed`. The ml plugin provides ML-KEM independently of OpenSSL. Charon and swanctl use `LD_LIBRARY_PATH=${STRONGSWAN}/lib/ipsec` — do not inherit the OpenSSL 4.0 lib path.

Smoke tests after build:

```bash
LD_LIBRARY_PATH=os-lib/install/openssl-4.0/lib os-lib/install/openssl-4.0/bin/openssl list -kem-algorithms | grep -i ML-KEM
os-lib/install/strongswan/sbin/swanctl --list-algs | grep -i mlkem
os-lib/install/openssh/bin/ssh -Q kex | grep mlkem
```

## Protocol Ports (all on vm2)

Ports are set in `env.sh` and must not be hardcoded in scripts or source files.

| Protocol | env.sh variable | Default | Transport |
| -------- | --------------- | ------- | --------- |
| TLS (classical) | `PORT_TLS`      | 4433    | TCP       |
| TLS (PQC)       | `PORT_TLS_PQC`  | 4434    | TCP       |
| mTLS (classical)| `PORT_MTLS`     | 4435    | TCP       |
| mTLS (PQC)      | `PORT_MTLS_PQC` | 4436    | TCP       |
| DTLS            | `PORT_DTLS`     | 4437    | UDP       |
| QUIC (classical)| `PORT_QUIC`     | 4438    | UDP       |
| QUIC (PQC)      | `PORT_QUIC_PQC` | 4439    | UDP       |
| IPsec (classical)| `PORT_IPSEC`   | 4440    | UDP       |
| IPsec (PQC)     | `PORT_IPSEC_PQC`| 4441    | UDP       |
| SSH (classical) | `PORT_SSH`      | 4442    | TCP       |
| SSH (PQC)       | `PORT_SSH_PQC`  | 4443    | TCP       |

## Orchestrator Usage

```bash
# Run via run.sh (syncs repo, installs deps, starts servers, loops traffic):
./run.sh [--proto PROTO] [--mode MODE]

# PROTO: tls | mtls | dtls | quic | ipsec | ssh | all   (default: all)
# MODE:  classical | pqc | all                           (default: all)

# Run a single protocol orchestrator directly (source env.sh first):
source env.sh
bash orchestrator/tls.sh  classical   # or pqc
bash orchestrator/mtls.sh classical   # or pqc
bash orchestrator/dtls.sh classical   # classical only (DTLS 1.2; no PQC)
bash orchestrator/quic.sh classical   # or pqc
bash orchestrator/ipsec.sh pqc        # or classical (not both: charon holds kernel XFRM)
bash orchestrator/ssh.sh  classical   # or pqc
```

## PQC Knobs Per Protocol

| Protocol       | Knob                                         | Note                          |
| -------------- | -------------------------------------------- | ----------------------------- |
| TLS / mTLS     | `-groups X25519MLKEM768`                     | TLS 1.3 required              |
| QUIC           | `-groups X25519MLKEM768`                     | TLS 1.3 required              |
| DTLS           | no PQC KEX                                   | DTLS 1.2 only; ML-KEM needs TLS 1.3 |
| IPsec          | `proposals = aes256gcm16-prfsha384-mlkem768` |                               |
| SSH            | `KexAlgorithms mlkem768x25519-sha256`        |                               |

## Verifying PQC Negotiated

```bash
# TLS/mTLS/DTLS/QUIC
SSLKEYLOGFILE=capture.keys tshark -Y tls.handshake.extensions.key_share_group

# IPsec
swanctl --list-sas

# SSH
ssh -vv -p $PORT_SSH $VM2_USER@$VM2_HOST exit 2>&1 | grep 'kex: algorithm:'
```

## Build Dependencies (apt)

OpenSSL 4.0 (TLS/mTLS/DTLS/QUIC):

```bash
sudo apt-get install -y build-essential cmake pkg-config
```

strongSwan 6.0.6 (IPsec):

```bash
sudo apt-get install -y build-essential pkg-config flex bison libssl-dev
```

`libssl-dev` provides the system OpenSSL 3.x headers and `libcrypto.so.3`. strongSwan must be built against these headers, not the local OpenSSL 4.0 install. See `protocols/ipsec/README.md` for details.
