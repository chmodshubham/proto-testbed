# strongSwan Installation Guide

Builds strongSwan 6.0.6 from source into `os-lib/install/strongswan/` inside the repo. Nothing touches the system strongSwan. Used by IPsec for `charon` (IKEv2), `swanctl`, `pki`, and the `ml` plugin (ML-KEM-768).

Run on **both VMs** from the repo root.

## Pre-requisites

See the root [README.md](../README.md). Verify or load the kernel XFRM modules on both VMs:

```bash
lsmod | grep -E "esp4|xfrm_user|xfrm_algo"
sudo modprobe esp4 xfrm_user xfrm_algo
```

## Step 1: Install build dependencies

```bash
sudo apt install -y build-essential pkg-config flex bison libssl-dev
```

> [!IMPORTANT]
> strongSwan must build against the system OpenSSL headers (3.x), not the local OpenSSL 4.0 install. Do not pass `--with-openssl-prefix` or point `PKG_CONFIG_PATH` at `os-lib/install/openssl-4.0/`. Building against 4.0 headers pulls in ML-KEM references the system runtime (3.x) cannot resolve, producing `creating KE payload failed` at runtime. The `ml` plugin provides ML-KEM-768 independently.

## Step 2: Download and build on both VMs

```bash
cd proto-testbed/
mkdir -p os-lib/src && cd os-lib/src
curl -LO https://download.strongswan.org/strongswan-6.0.6.tar.gz
tar xzf strongswan-6.0.6.tar.gz && cd strongswan-6.0.6

# Self-contained install; minimal plugin set: IKEv2 + vici/swanctl/pki control plane,
# openssl (system 3.x) for classical crypto, ml for ML-KEM-768, kernel-netlink for XFRM.
./configure \
    --prefix="$(cd ../../.. && pwd)/os-lib/install/strongswan" \
    --sysconfdir="$(cd ../../.. && pwd)/os-lib/install/strongswan/etc" \
    --disable-defaults \
    --enable-charon --enable-ikev2 --enable-vici --enable-swanctl --enable-pki \
    --enable-nonce --enable-random --enable-drbg \
    --enable-openssl --enable-pem --enable-pkcs1 --enable-pkcs8 --enable-pubkey \
    --enable-x509 --enable-revocation --enable-constraints \
    --enable-ml \
    --enable-kernel-netlink --enable-socket-default --enable-updown --enable-resolve

make -j$(nproc) && make install
cd ../../..
```

## Step 4: Verify the PQ algorithm

```bash
os-lib/install/strongswan/sbin/swanctl --version
os-lib/install/strongswan/bin/pki      --version
os-lib/install/strongswan/sbin/swanctl --list-algs | grep -i mlkem
```

> [!NOTE]
> All three must succeed; the last must show `ML_KEM_768`. If missing, the `ml` plugin did not build — re-run Step 2 and confirm `--enable-ml` was accepted by `configure`.

## Next

| Protocol | Guide                                                     |
| -------- | --------------------------------------------------------- |
| IPsec    | [protocols/ipsec/README.md](../protocols/ipsec/README.md) |
