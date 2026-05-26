# strongSwan 6.0.6 Setup

Single source of truth for installing strongSwan 6.0.6 on **vm1** and **vm2**. Required by IPsec.

All commands run from the repo root. Source `env.sh` first.

## Prerequisites

- Ubuntu 24.04 LTS (x86_64) on both VMs
- `sudo` access on both VMs (charon requires root for kernel XFRM)
- Kernel 5.1+ with `esp4`, `xfrm_user`, `xfrm_algo` (built-in or loadable)

### Hardware requirements

| Resource     | Minimum | Notes                                                                                          |
| ------------ | ------- | ---------------------------------------------------------------------------------------------- |
| Architecture | x86_64  | charon uses the `kernel-netlink` plugin; XFRM ABI is architecture-specific                     |
| CPU          | 1 core  | Build uses `make -j$(nproc)`; ~2 min on 4 cores                                                |
| RAM          | 512 MB  | charon idle RSS ~8 MB; ML-KEM-768 adds ~2.3 KB per SA                                          |
| Disk         | 500 MB  | ~16 MB installed (`os-lib/install/strongswan/`); source + build tree ~450 MB                  |

Kernel modules load automatically on first XFRM use. Verify:

```bash
lsmod | grep -E "esp4|xfrm_user|xfrm_algo"
```

If empty, load manually on both VMs:

```bash
sudo modprobe esp4 xfrm_user xfrm_algo
```

## Step 1: Install build dependencies

Run on **both VMs**.

```bash
sudo apt-get install -y build-essential pkg-config flex bison libssl-dev
```

| Package           | Role                                                |
| ----------------- | --------------------------------------------------- |
| `build-essential` | gcc, make, binutils                                 |
| `pkg-config`      | locates openssl headers at configure time           |
| `flex`            | lexer generator used by strongSwan configure        |
| `bison`           | parser generator used by strongSwan configure       |
| `libssl-dev`      | OpenSSL system headers; provides libcrypto.so.3 at runtime |

> [!IMPORTANT]
> Do not pass `--with-openssl-prefix` or set `PKG_CONFIG_PATH` to the local OpenSSL 4.0 install. strongSwan must build against the system OpenSSL headers (3.x). If built against OpenSSL 4.0 headers, the openssl plugin compiles in ML-KEM support that references NIDs absent in the system runtime library, causing `creating KE payload failed` at runtime. The `ml` plugin provides ML-KEM-768 independently.

## Step 2: Build on vm1

From repo root:

```bash
source env.sh
mkdir -p os-lib/src
cd os-lib/src
curl -LO https://download.strongswan.org/strongswan-6.0.6.tar.gz
tar xzf strongswan-6.0.6.tar.gz
cd strongswan-6.0.6

./configure \
    --prefix="$(cd ../../.. && pwd)/os-lib/install/strongswan" \
    --sysconfdir="$(cd ../../.. && pwd)/os-lib/install/strongswan/etc" \
    --disable-defaults \
    --enable-charon \
    --enable-ikev2 \
    --enable-vici \
    --enable-swanctl \
    --enable-pki \
    --enable-nonce \
    --enable-random \
    --enable-drbg \
    --enable-openssl \
    --enable-pem \
    --enable-pkcs1 \
    --enable-pkcs8 \
    --enable-pubkey \
    --enable-x509 \
    --enable-revocation \
    --enable-constraints \
    --enable-ml \
    --enable-kernel-netlink \
    --enable-socket-default \
    --enable-updown \
    --enable-resolve

make -j$(nproc)
make install
cd ../../..
```

> [!NOTE]
> If `make install` fails with `Is a directory` near the install target, an `INSTALL` env var was previously exported as a directory path. Either `unset INSTALL` and re-run, or override per call: `make INSTALL=/usr/bin/install install`. The repo's `env.sh` does not export `INSTALL`; this only bites when older shells inherit the variable.

## Step 3: Build on vm2

`os-lib/` is gitignored and excluded from `rsync`, so vm2 must build independently.

```bash
ssh "${VM2_USER}@${VM2_HOST}" "
    cd ${VM2_REPO} &&
    mkdir -p os-lib/src &&
    cd os-lib/src &&
    curl -LO https://download.strongswan.org/strongswan-6.0.6.tar.gz &&
    tar xzf strongswan-6.0.6.tar.gz &&
    cd strongswan-6.0.6 &&
    ./configure \
        --prefix=\"\$(cd ../../.. && pwd)/os-lib/install/strongswan\" \
        --sysconfdir=\"\$(cd ../../.. && pwd)/os-lib/install/strongswan/etc\" \
        --disable-defaults \
        --enable-charon --enable-ikev2 --enable-vici --enable-swanctl \
        --enable-pki --enable-nonce --enable-random --enable-drbg \
        --enable-openssl --enable-pem --enable-pkcs1 --enable-pkcs8 \
        --enable-pubkey --enable-x509 --enable-revocation --enable-constraints \
        --enable-ml --enable-kernel-netlink --enable-socket-default \
        --enable-updown --enable-resolve &&
    make -j\$(nproc) &&
    make install
"
```

## Step 4: Smoke test

Run on **both VMs**:

```bash
os-lib/install/strongswan/sbin/swanctl --version
os-lib/install/strongswan/bin/pki      --version
os-lib/install/strongswan/sbin/swanctl --list-algs | grep -i mlkem
```

All three must succeed; the last must show `ML_KEM_768`.

## Next

Continue with PKI generation and orchestrator setup:
[protocols/ipsec/README.md](../protocols/ipsec/README.md)
