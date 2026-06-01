# nginx Installation Guide

Builds nginx 1.27.4 with HTTP/3 support, linked against BoringSSL, into `os-lib/install/nginx/` inside the repo. Nothing touches system paths. Used by TLS and QUIC as the server.

Run on **both VMs** from the repo root. Build BoringSSL first (Step 2).

## Pre-requisites

See the root [README.md](../README.md).

## Step 1: Install build dependencies

```bash
sudo apt-get install -y build-essential cmake ninja-build golang-go python3 libpcre2-dev zlib1g-dev
```

`golang-go` is required by BoringSSL's build system. `python3` is required by `pki/gen.sh` to convert ML-DSA private keys for BoringSSL.

## Step 2: Build BoringSSL

BoringSSL is linked statically into nginx. Build it first.

```bash
BSSL_VERSION="0.20260526.0"
BSSL_SRC="${PWD}/os-lib/src/boringssl-${BSSL_VERSION}"

mkdir -p os-lib/src
curl -fL --retry 3 \
    -o "os-lib/src/boringssl-${BSSL_VERSION}.tar.gz" \
    "https://github.com/google/boringssl/archive/refs/tags/${BSSL_VERSION}.tar.gz"
tar xzf "os-lib/src/boringssl-${BSSL_VERSION}.tar.gz" -C os-lib/src

cmake -S "$BSSL_SRC" -B "${BSSL_SRC}/build" \
    -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON
ninja -C "${BSSL_SRC}/build" ssl crypto
```

## Step 3: Patch and build nginx

Two patches are required before configure:

- ASN1 API: BoringSSL removed the deprecated field access used in nginx's OCSP stapling module. Replaced with `ASN1_STRING_length()` / `ASN1_STRING_get0_data()`.
- C++ runtime: BoringSSL is a C++ library. Add `-lstdc++` to the OpenSSL feature-test link line so the configure check passes.

```bash
NGINX_VERSION="1.27.4"
NGINX_SRC="${PWD}/os-lib/src/nginx-${NGINX_VERSION}"
BSSL_SRC="${PWD}/os-lib/src/boringssl-${BSSL_VERSION}"
NGINX_PREFIX="${PWD}/os-lib/install/nginx"

mkdir -p os-lib/src
curl -fL --retry 3 \
    -o "os-lib/src/nginx-${NGINX_VERSION}.tar.gz" \
    "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"
tar xzf "os-lib/src/nginx-${NGINX_VERSION}.tar.gz" -C os-lib/src

sed -i \
    -e 's/serial->length/ASN1_STRING_length(serial)/g' \
    -e 's/serial->data/ASN1_STRING_get0_data(serial)/g' \
    "${NGINX_SRC}/src/event/ngx_event_openssl_stapling.c"
sed -i 's/-lssl -lcrypto/-lssl -lcrypto -lstdc++/g' \
    "${NGINX_SRC}/auto/lib/openssl/conf"

cd "$NGINX_SRC"
./configure \
    --prefix="${NGINX_PREFIX}" \
    --with-http_ssl_module \
    --with-http_v2_module \
    --with-http_v3_module \
    --with-cc-opt="-I ${BSSL_SRC}/include -L ${BSSL_SRC}/build -lstdc++ -lpthread" \
    --with-ld-opt="-L ${BSSL_SRC}/build -lstdc++ -lpthread"

make -j$(nproc) && make install
cd -
```

## Step 4: Verify

```bash
os-lib/install/nginx/sbin/nginx -V 2>&1 | grep BoringSSL
```

Must print a line containing `BoringSSL`. If not, re-run Step 3.

## Automated setup

`lib-setup.sh` performs all steps above automatically, including skip guards:

```bash
bash lib-setup.sh                      # build everything
bash lib-setup.sh --skip-boringssl     # skip BoringSSL (must already be built)
bash lib-setup.sh --skip-nginx         # skip nginx
```

## Next

| Protocol | Guide                                                   |
| -------- | ------------------------------------------------------- |
| TLS      | [protocols/tls/README.md](../protocols/tls/README.md)   |
| QUIC     | [protocols/quic/README.md](../protocols/quic/README.md) |
