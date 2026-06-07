# OpenSSH Installation Guide

Builds OpenSSH 10.3p1 from source into `os-lib/install/openssh/` inside the repo. The system `sshd` on port 22 stays untouched. Used by the testbed SSH protocol for the `mlkem768x25519-sha256` post-quantum KEX.

Run on **both VMs** from the repo root.

## Pre-requisites

See the root [README.md](../README.md).

## Step 1: Install build dependencies

```bash
sudo apt install -y build-essential libpam0g-dev libssl-dev zlib1g-dev
```

## Step 2: Download and build

```bash
cd proto-testbed/
mkdir -p os-lib/src && cd os-lib/src
curl -LO https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-10.3p1.tar.gz
tar xzf openssh-10.3p1.tar.gz && cd openssh-10.3p1

./configure \
    --prefix="$(cd ../../.. && pwd)/os-lib/install/openssh" \
    --sysconfdir="$(cd ../../.. && pwd)/os-lib/install/openssh/etc" \
    --with-ssl-dir=/usr \
    --with-pam \
    --with-privsep-path=/var/empty \
    --with-sandbox=seccomp_filter

make -j$(nproc) && sudo make install
cd ../../..
```

`sudo make install` is needed because `/var/empty` is owned by root.

## Step 3: Verify the PQ KEX

```bash
os-lib/install/openssh/bin/ssh   -Q kex | grep mlkem
os-lib/install/openssh/sbin/sshd -t -f /dev/null 2>&1 | head -1
```

First must print `mlkem768x25519-sha256`. Second confirms `sshd` executes (config error from `/dev/null` is expected; exec or missing-library errors are not).

## Next

| Protocol | Guide                                                 |
| -------- | ----------------------------------------------------- |
| SSH      | [protocols/ssh/README.md](../protocols/ssh/README.md) |
