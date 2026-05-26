# IPsec

IKEv2 over UDP using strongSwan 6.0.6 with swanctl/VICI. Two modes: classical (ECDSA P-256 certs, ECP-256 KEX) and PQC (ECDSA P-256 certs, ML-KEM-768 KEX).

## Algorithm Choices

| Field      | Classical             | PQC                   |
| ---------- | --------------------- | --------------------- |
| CA key     | ECDSA P-384           | ECDSA P-384           |
| Server key | ECDSA P-256           | ECDSA P-256           |
| Client key | ECDSA P-256           | ECDSA P-256           |
| IKE KEX    | ECP-256               | ML-KEM-768            |
| IKE cipher | AES-256-GCM + SHA-384 | AES-256-GCM + SHA-384 |
| ESP cipher | AES-256-GCM           | AES-256-GCM           |
| Auth       | pubkey (cert)         | pubkey (cert)         |

ML-DSA certificate support is not available in strongSwan 6.0.6. Classical ECDSA certs are used for both modes; PQC applies to the IKE key exchange only (ML-KEM-768 via the built-in `ml` plugin).

## Prerequisites

- Ubuntu 24.04 LTS (x86_64) on both VMs
- Passwordless SSH from vm1 to vm2
- `sudo` access on both VMs (charon requires root for kernel XFRM)

### Hardware requirements

| Resource     | Minimum | Notes                                                                                                                                                       |
| ------------ | ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Architecture | x86_64  | charon uses the `kernel-netlink` plugin; XFRM ABI is architecture-specific                                                                                  |
| CPU          | 1 core  | Build uses `make -j$(nproc)`; more cores reduce compile time (~2 min on 4 cores)                                                                            |
| RAM          | 512 MB  | charon idle RSS ~8 MB; ML-KEM-768 adds ~2.3 KB per SA (1184 B public key + 1088 B ciphertext, per `ml_params.c`); total well under 50 MB under testbed load |
| Disk         | 500 MB  | ~16 MB installed (`os-lib/install/strongswan/`); source + build tree ~450 MB                                                                                |
| Kernel       | 5.1+    | Requires `esp4`, `xfrm_user`, `xfrm_algo` modules (built-in or loadable); verified on Linux 6.8                                                             |

Kernel modules load automatically on first XFRM use. Verify:

```bash
lsmod | grep -E "esp4|xfrm_user|xfrm_algo"
```

If empty, load manually:

```bash
sudo modprobe esp4 xfrm_user xfrm_algo
```

All commands run from the repo root. Every terminal session starts with:

```bash
cd /path/to/proto-testbed
source env.sh
```

## Step 1: Install build dependencies

Run on **both VMs**.

```bash
sudo apt-get install -y build-essential pkg-config flex bison libssl-dev
```

| Package           | Role                                                |
| ----------------- | --------------------------------------------------- |
| `build-essential` | gcc, make, binutils (ar, nm, ranlib, strip)         |
| `pkg-config`      | locates openssl headers at configure time           |
| `flex`            | lexer generator used by strongSwan configure        |
| `bison`           | parser generator used by strongSwan configure       |
| `libssl-dev`      | OpenSSL headers; provides libcrypto.so.3 at runtime |

## Step 2: Clone the repo

Run on **both VMs**.

```bash
git clone <repo-url> proto-testbed
cd proto-testbed
```

## Step 3: Configure env.sh

**vm1:** open `env.sh` and set VM credentials and IPs:

```bash
export VM2_USER=ubuntu
export VM2_HOST=<vm2-hostname>
export VM2_REPO="/home/ubuntu/proto-testbed"
export VM1_IP=<vm1-ip>
export VM2_IP=<vm2-ip>
```

Sync to vm2 and source on both:

```bash
source env.sh
rsync -a env.sh "$VM2_USER@$VM2_HOST:$VM2_REPO/"
```

## Step 4: Build strongSwan 6.0.6

See [docs/strongswan.md](../../docs/strongswan.md) for the full build and smoke test on both VMs.

## Step 5: Generate PKI

Run on **vm1** only, from repo root.

```bash
source env.sh
./pki/gen.sh --proto ipsec
```

Output:

```
pki/out/ca/ipsec/classical/ca-cert.pem
pki/out/ipsec/classical/server-cert.pem  server-key.pem  client-cert.pem  client-key.pem
pki/out/ca/ipsec/pqc/ca-cert.pem
pki/out/ipsec/pqc/server-cert.pem  server-key.pem  client-cert.pem  client-key.pem
```

## Step 6: Sync certs to vm2

Run on **vm1** from repo root.

```bash
source env.sh

rsync -a --mkpath \
    pki/out/ca/ipsec/ \
    "$VM2_USER@$VM2_HOST:$VM2_REPO/pki/out/ca/ipsec/"

rsync -a --mkpath \
    pki/out/ipsec/ \
    "$VM2_USER@$VM2_HOST:$VM2_REPO/pki/out/ipsec/"
```

Verify on **vm2**:

```bash
source env.sh

os-lib/install/strongswan/bin/pki --verify \
    --in pki/out/ipsec/classical/server-cert.pem \
    --cacert pki/out/ca/ipsec/classical/ca-cert.pem

os-lib/install/strongswan/bin/pki --verify \
    --in pki/out/ipsec/pqc/server-cert.pem \
    --cacert pki/out/ca/ipsec/pqc/ca-cert.pem
```

Both should print `certificate trusted`.

```bash
os-lib/install/strongswan/sbin/swanctl --list-algs | grep -i mlkem
```

Should list `mlkem768` before proceeding.

## Step 7: Start server and run traffic

Run on **vm1** from repo root. Starts charon on vm2, waits until ready, then loops traffic. Press Ctrl-C to stop.

```bash
source env.sh

bash orchestrator/ipsec.sh classical   # ECDSA certs, ECP-256 KEX
bash orchestrator/ipsec.sh pqc         # ECDSA certs, ML-KEM-768 KEX
```

Or via run.sh:

```bash
./run.sh --proto ipsec --mode classical
./run.sh --proto ipsec --mode pqc
```

`--mode all` is not supported for IPsec and will exit with an error. Two charon instances cannot share kernel XFRM on the same host.

Each connection prints one row: timestamp, connection number, IKE group, ESP cipher, verify code. `Verify: 0` means the IKE SA established AND a single ICMP echo to `${VM2_IP}` succeeded through the tunnel. Inspect `ip -s xfrm state` while the SA is up to confirm ESP byte/packet counters increase across the ping, proving ICMP traversed ESP rather than plaintext.

## Ports

| Mode      | env.sh variable  | Default | Transport |
| --------- | ---------------- | ------- | --------- |
| classical | `PORT_IPSEC`     | 4440    | UDP       |
| pqc       | `PORT_IPSEC_PQC` | 4441    | UDP       |
