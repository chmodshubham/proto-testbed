# OpenSSH 10.3p1 Setup

Single source of truth for installing OpenSSH 10.3p1 on **vm1** and **vm2**. Required by the testbed SSH protocol (system `sshd` on port 22 is untouched).

All commands run from the repo root. Source `env.sh` first.

## Prerequisites

- Ubuntu 24.04 LTS (x86_64) on both VMs
- Passwordless SSH from vm1 to vm2 (or set `VM2_PASSWORD` in env.sh)
- `sudo` access on both VMs

### Hardware requirements

| Resource     | Minimum | Notes                                                                             |
| ------------ | ------- | --------------------------------------------------------------------------------- |
| Architecture | x86_64  | Build target is `linux-x86_64`                                                    |
| CPU          | 1 core  | Build uses `make -j$(nproc)`; ~2 min on 4 cores                                   |
| RAM          | 64 MB   | sshd privsep adds one child per connection; idle footprint under 20 MB            |
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

## Step 2: Build on vm1

From repo root:

```bash
source env.sh
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
cd ../../..
```

## Step 3: Build on vm2

`os-lib/` is gitignored and excluded from `rsync`, so vm2 must build independently.

```bash
ssh "${VM2_USER}@${VM2_HOST}" "
    cd ${VM2_REPO} &&
    mkdir -p os-lib/src &&
    cd os-lib/src &&
    curl -LO https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-10.3p1.tar.gz &&
    tar xzf openssh-10.3p1.tar.gz &&
    cd openssh-10.3p1 &&
    ./configure \
        --prefix=\"\$(cd ../../.. && pwd)/os-lib/install/openssh\" \
        --sysconfdir=\"\$(cd ../../.. && pwd)/os-lib/install/openssh/etc\" \
        --with-ssl-dir=/usr \
        --with-pam \
        --with-privsep-path=/var/empty \
        --with-sandbox=seccomp_filter &&
    make -j\$(nproc) &&
    sudo make install
"
```

## Step 4: Smoke test

Run on **both VMs**:

```bash
os-lib/install/openssh/bin/ssh   -Q kex | grep mlkem
os-lib/install/openssh/sbin/sshd -t -f /dev/null 2>&1 | head -1
```

The first must output `mlkem768x25519-sha256`. The second confirms the testbed sshd binary loads (a config error from `/dev/null` is expected; an exec error is not).

## Next

Continue with PKI generation and orchestrator setup:
[protocols/ssh/README.md](../protocols/ssh/README.md)
