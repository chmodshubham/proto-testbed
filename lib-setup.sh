#!/usr/bin/env bash
# setup.sh — clone the repo and build all libraries on this VM.
#
# Usage (run as the testbed user, NOT root):
#   bash setup.sh [--skip-openssl] [--skip-strongswan] [--skip-openssh]
#
# All libraries install into <repo>/os-lib/install/. Nothing touches system paths.
# Run this on every VM that will participate in the testbed.

set -euo pipefail

REPO_URL="https://github.com/chmodshubham/proto-testbed.git"
REPO_BRANCH="main"
REPO_DIR="proto-testbed"

SKIP_OPENSSL=0
SKIP_STRONGSWAN=0
SKIP_OPENSSH=0
SKIP_BORINGSSL=0
SKIP_NGINX=0

for arg in "$@"; do
    case "$arg" in
        --skip-openssl)    SKIP_OPENSSL=1 ;;
        --skip-strongswan) SKIP_STRONGSWAN=1 ;;
        --skip-openssh)    SKIP_OPENSSH=1 ;;
        --skip-boringssl)  SKIP_BORINGSSL=1 ;;
        --skip-nginx)      SKIP_NGINX=1 ;;
        *) printf 'Unknown flag: %s\n' "$arg" >&2; exit 1 ;;
    esac
done

log() { printf '[%s] %s\n' "$1" "$2"; }
die() { log ERROR "$1"; exit 1; }

# ---------------------------------------------------------------------------
# Step 1: Clone
# ---------------------------------------------------------------------------

log INFO "Checking for repo ..."

# Support running from inside the repo (development) or from any parent dir.
if [[ -f "pki/gen.sh" && -f "env.sh" ]]; then
    log INFO "Already inside repo. Skipping clone."
    REPO_DIR="."
elif [[ -d "$REPO_DIR/.git" ]]; then
    log INFO "Repo already exists at ${REPO_DIR}/. Skipping clone."
else
    command -v git >/dev/null 2>&1 || die "git not found. Install it: sudo apt-get install -y git"
    log INFO "Cloning ${REPO_URL} branch ${REPO_BRANCH} ..."
    git clone --branch "$REPO_BRANCH" "$REPO_URL" "$REPO_DIR"
    log INFO "Clone complete."
fi

cd "$REPO_DIR"
REPO_ROOT="$(pwd)"
log INFO "Repo root: ${REPO_ROOT}"
[[ -f "pki/gen.sh" ]]     || die "Unexpected layout: pki/gen.sh missing. Check clone."
[[ -f "env.sh" ]]         || die "Unexpected layout: env.sh missing. Check clone."
[[ -d "protocols" ]]      || die "Unexpected layout: protocols/ missing. Check clone."

# ---------------------------------------------------------------------------
# Step 2: OpenSSL 4.0
# ---------------------------------------------------------------------------

OSSL_PREFIX="${REPO_ROOT}/os-lib/install/openssl-4.0"
OSSL_BIN="${OSSL_PREFIX}/bin/openssl"
OSSL_LIB="${OSSL_PREFIX}/lib"
OSSL_SRC_DIR="${REPO_ROOT}/os-lib/src/openssl-4.0.0"
OSSL_TARBALL="${REPO_ROOT}/os-lib/src/openssl-4.0.0.tar.gz"

if [[ "$SKIP_OPENSSL" -eq 1 ]]; then
    log INFO "Skipping OpenSSL (--skip-openssl)."
elif [[ -x "$OSSL_BIN" ]]; then
    log INFO "OpenSSL already at ${OSSL_BIN}. Skipping build."
else
    log INFO "Installing OpenSSL build deps ..."
    sudo apt-get install -y build-essential cmake pkg-config perl

    mkdir -p "${REPO_ROOT}/os-lib/src"

    if [[ ! -f "$OSSL_TARBALL" ]]; then
        log INFO "Downloading OpenSSL 4.0.0 ..."
        curl -fL --retry 3 -o "$OSSL_TARBALL" \
            "https://github.com/openssl/openssl/releases/download/openssl-4.0.0/openssl-4.0.0.tar.gz"
    fi

    if [[ ! -d "$OSSL_SRC_DIR" ]]; then
        log INFO "Extracting OpenSSL ..."
        tar xzf "$OSSL_TARBALL" -C "${REPO_ROOT}/os-lib/src"
    fi

    log INFO "Configuring OpenSSL ..."
    cd "$OSSL_SRC_DIR"
    # --libdir=lib pins the library directory so env.sh LD_LIBRARY_PATH points correctly.
    ./Configure \
        --prefix="${OSSL_PREFIX}" \
        --openssldir="${OSSL_PREFIX}/ssl" \
        --libdir=lib \
        linux-x86_64

    log INFO "Building OpenSSL (takes a few minutes) ..."
    make -j"$(nproc)"
    make install
    cd "${REPO_ROOT}"
fi

if [[ "$SKIP_OPENSSL" -eq 0 ]]; then
    log INFO "Verifying OpenSSL ..."
    [[ -x "$OSSL_BIN" ]]           || die "Binary not found: ${OSSL_BIN}"
    [[ -f "${OSSL_LIB}/libssl.so" ]] || die "Library not found: ${OSSL_LIB}/libssl.so"
    LD_LIBRARY_PATH="${OSSL_LIB}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        "$OSSL_BIN" list -kem-algorithms | grep -q "ML-KEM" \
        || die "ML-KEM not listed. Re-run without --skip-openssl."
    LD_LIBRARY_PATH="${OSSL_LIB}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        "$OSSL_BIN" list -tls-groups | grep -q "MLKEM" \
        || die "MLKEM TLS group not listed. Re-run without --skip-openssl."
    log INFO "OpenSSL OK: ML-KEM and MLKEM TLS group present."
fi

# ---------------------------------------------------------------------------
# Step 3: strongSwan 6.0.6
# ---------------------------------------------------------------------------

SWAN_PREFIX="${REPO_ROOT}/os-lib/install/strongswan"
SWAN_SWANCTL="${SWAN_PREFIX}/sbin/swanctl"
SWAN_PKI="${SWAN_PREFIX}/bin/pki"
SWAN_SRC_DIR="${REPO_ROOT}/os-lib/src/strongswan-6.0.6"
SWAN_TARBALL="${REPO_ROOT}/os-lib/src/strongswan-6.0.6.tar.gz"

if [[ "$SKIP_STRONGSWAN" -eq 1 ]]; then
    log INFO "Skipping strongSwan (--skip-strongswan)."
elif [[ -x "$SWAN_SWANCTL" ]]; then
    log INFO "strongSwan already at ${SWAN_SWANCTL}. Skipping build."
else
    log INFO "Installing strongSwan build deps ..."
    sudo apt-get install -y build-essential pkg-config flex bison libssl-dev

    mkdir -p "${REPO_ROOT}/os-lib/src"

    if [[ ! -f "$SWAN_TARBALL" ]]; then
        log INFO "Downloading strongSwan 6.0.6 ..."
        curl -fL --retry 3 -o "$SWAN_TARBALL" \
            "https://download.strongswan.org/strongswan-6.0.6.tar.gz"
    fi

    if [[ ! -d "$SWAN_SRC_DIR" ]]; then
        log INFO "Extracting strongSwan ..."
        tar xzf "$SWAN_TARBALL" -C "${REPO_ROOT}/os-lib/src"
    fi

    log INFO "Configuring strongSwan ..."
    cd "$SWAN_SRC_DIR"
    # Must build against system OpenSSL (3.x) headers, not os-lib/install/openssl-4.0.
    # The ml plugin provides ML-KEM-768 independently of OpenSSL.
    ./configure \
        --prefix="${SWAN_PREFIX}" \
        --sysconfdir="${SWAN_PREFIX}/etc" \
        --disable-defaults \
        --enable-charon --enable-ikev2 --enable-vici --enable-swanctl --enable-pki \
        --enable-nonce --enable-random --enable-drbg \
        --enable-openssl --enable-pem --enable-pkcs1 --enable-pkcs8 --enable-pubkey \
        --enable-x509 --enable-revocation --enable-constraints \
        --enable-ml \
        --enable-kernel-netlink --enable-socket-default --enable-updown --enable-resolve

    log INFO "Building strongSwan (takes a few minutes) ..."
    make -j"$(nproc)"
    make install
    cd "${REPO_ROOT}"
fi

if [[ "$SKIP_STRONGSWAN" -eq 0 ]]; then
    log INFO "Verifying strongSwan ..."
    [[ -x "$SWAN_SWANCTL" ]] || die "swanctl not found: ${SWAN_SWANCTL}"
    [[ -x "$SWAN_PKI" ]]     || die "pki not found: ${SWAN_PKI}"
    "$SWAN_PKI" --help 2>&1 | grep -qi "strongswan" \
        || die "pki --help output unexpected. Binary may be broken."
    # swanctl --version and --list-algs connect to charon VICI socket; verify ml plugin by file instead.
    SWAN_PLUGIN_DIR="${SWAN_PREFIX}/lib/ipsec/plugins"
    [[ -f "${SWAN_PLUGIN_DIR}/libstrongswan-ml.so" ]] \
        || die "ml plugin not found: ${SWAN_PLUGIN_DIR}/libstrongswan-ml.so. Re-run without --skip-strongswan."
    log INFO "strongSwan OK: ml plugin present."
fi

# ---------------------------------------------------------------------------
# Step 4: OpenSSH 10.3p1
# ---------------------------------------------------------------------------

SSHD_PREFIX="${REPO_ROOT}/os-lib/install/openssh"
SSHD_SSH="${SSHD_PREFIX}/bin/ssh"
SSHD_SSHD="${SSHD_PREFIX}/sbin/sshd"
SSHD_SRC_DIR="${REPO_ROOT}/os-lib/src/openssh-10.3p1"
SSHD_TARBALL="${REPO_ROOT}/os-lib/src/openssh-10.3p1.tar.gz"

if [[ "$SKIP_OPENSSH" -eq 1 ]]; then
    log INFO "Skipping OpenSSH (--skip-openssh)."
elif [[ -x "$SSHD_SSH" ]]; then
    log INFO "OpenSSH already at ${SSHD_SSH}. Skipping build."
else
    log INFO "Installing OpenSSH build deps ..."
    sudo apt-get install -y build-essential libpam0g-dev libssl-dev zlib1g-dev

    mkdir -p "${REPO_ROOT}/os-lib/src"

    if [[ ! -f "$SSHD_TARBALL" ]]; then
        log INFO "Downloading OpenSSH 10.3p1 ..."
        curl -fL --retry 3 -o "$SSHD_TARBALL" \
            "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-10.3p1.tar.gz"
    fi

    if [[ ! -d "$SSHD_SRC_DIR" ]]; then
        log INFO "Extracting OpenSSH ..."
        tar xzf "$SSHD_TARBALL" -C "${REPO_ROOT}/os-lib/src"
    fi

    log INFO "Configuring OpenSSH ..."
    cd "$SSHD_SRC_DIR"
    ./configure \
        --prefix="${SSHD_PREFIX}" \
        --sysconfdir="${SSHD_PREFIX}/etc" \
        --with-ssl-dir=/usr \
        --with-pam \
        --with-privsep-path=/var/empty \
        --with-sandbox=seccomp_filter

    log INFO "Building OpenSSH ..."
    make -j"$(nproc)"
    # sudo needed: installs files into /var/empty (root-owned privsep chroot)
    sudo make install
    cd "${REPO_ROOT}"
fi

if [[ "$SKIP_OPENSSH" -eq 0 ]]; then
    log INFO "Verifying OpenSSH ..."
    [[ -x "$SSHD_SSH" ]]  || die "ssh not found: ${SSHD_SSH}"
    [[ -x "$SSHD_SSHD" ]] || die "sshd not found: ${SSHD_SSHD}"
    "$SSHD_SSH" -Q kex 2>/dev/null | grep -q "mlkem768x25519-sha256" \
        || die "mlkem768x25519-sha256 not in ssh -Q kex. Re-run without --skip-openssh."
    # /dev/null config causes a config error (expected); library/exec errors are not
    if "$SSHD_SSHD" -t -f /dev/null 2>&1 | grep -qiE "error loading shared|symbol lookup"; then
        die "sshd has missing shared library. Check build."
    fi
    log INFO "OpenSSH OK: mlkem768x25519-sha256 present."
fi

# ---------------------------------------------------------------------------
# Step 5: BoringSSL 0.20260526.0
# ---------------------------------------------------------------------------

BSSL_VERSION="0.20260526.0"
BSSL_SRC_DIR="${REPO_ROOT}/os-lib/src/boringssl-${BSSL_VERSION}"
BSSL_TARBALL="${REPO_ROOT}/os-lib/src/boringssl-${BSSL_VERSION}.tar.gz"
BSSL_LIBSSL="${BSSL_SRC_DIR}/build/libssl.a"

if [[ "$SKIP_BORINGSSL" -eq 1 ]]; then
    log INFO "Skipping BoringSSL (--skip-boringssl)."
elif [[ -f "$BSSL_LIBSSL" ]]; then
    log INFO "BoringSSL already built at ${BSSL_SRC_DIR}/build. Skipping build."
else
    log INFO "Installing BoringSSL build deps ..."
    sudo apt-get install -y build-essential cmake ninja-build golang-go python3

    mkdir -p "${REPO_ROOT}/os-lib/src"

    if [[ ! -f "$BSSL_TARBALL" ]]; then
        log INFO "Downloading BoringSSL ${BSSL_VERSION} ..."
        curl -fL --retry 3 \
            -o "$BSSL_TARBALL" \
            "https://github.com/google/boringssl/archive/refs/tags/${BSSL_VERSION}.tar.gz"
    fi

    if [[ ! -d "$BSSL_SRC_DIR" ]]; then
        log INFO "Extracting BoringSSL ..."
        tar xzf "$BSSL_TARBALL" -C "${REPO_ROOT}/os-lib/src"
    fi

    log INFO "Building BoringSSL (takes a few minutes) ..."
    cmake -S "$BSSL_SRC_DIR" -B "${BSSL_SRC_DIR}/build" \
        -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    ninja -C "${BSSL_SRC_DIR}/build" ssl crypto
    cd "${REPO_ROOT}"
fi

if [[ "$SKIP_BORINGSSL" -eq 0 ]]; then
    log INFO "Verifying BoringSSL ..."
    [[ -f "${BSSL_SRC_DIR}/build/libssl.a" ]]    || die "libssl.a not found: ${BSSL_SRC_DIR}/build/libssl.a"
    [[ -f "${BSSL_SRC_DIR}/build/libcrypto.a" ]] || die "libcrypto.a not found: ${BSSL_SRC_DIR}/build/libcrypto.a"
    [[ -f "${BSSL_SRC_DIR}/include/openssl/ssl.h" ]]     || die "Headers not found: ${BSSL_SRC_DIR}/include/openssl/ssl.h"
    log INFO "BoringSSL OK: static libs and headers present."
fi

# ---------------------------------------------------------------------------
# Step 6: nginx 1.27.4 (HTTP/3, linked against BoringSSL)
# ---------------------------------------------------------------------------

NGINX_VERSION="1.27.4"
NGINX_PREFIX="${REPO_ROOT}/os-lib/install/nginx"
NGINX_BIN="${NGINX_PREFIX}/sbin/nginx"
NGINX_SRC_DIR="${REPO_ROOT}/os-lib/src/nginx-${NGINX_VERSION}"
NGINX_TARBALL="${REPO_ROOT}/os-lib/src/nginx-${NGINX_VERSION}.tar.gz"

if [[ "$SKIP_NGINX" -eq 1 ]]; then
    log INFO "Skipping nginx (--skip-nginx)."
elif [[ -x "$NGINX_BIN" ]] && "$NGINX_BIN" -V 2>&1 | grep -q "BoringSSL"; then
    log INFO "nginx already at ${NGINX_BIN}. Skipping build."
else
    [[ -f "$BSSL_LIBSSL" ]] \
        || die "BoringSSL not found. Build it first (Step 5) or use --skip-nginx."

    log INFO "Installing nginx build deps ..."
    sudo apt-get install -y build-essential libpcre2-dev zlib1g-dev

    mkdir -p "${REPO_ROOT}/os-lib/src"

    if [[ ! -f "$NGINX_TARBALL" ]]; then
        log INFO "Downloading nginx ${NGINX_VERSION} ..."
        curl -fL --retry 3 \
            -o "$NGINX_TARBALL" \
            "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"
    fi

    if [[ ! -d "$NGINX_SRC_DIR" ]]; then
        log INFO "Extracting nginx ${NGINX_VERSION} ..."
        tar xzf "$NGINX_TARBALL" -C "${REPO_ROOT}/os-lib/src"
    fi

    log INFO "Patching nginx for BoringSSL (ASN1 API and C++ runtime) ..."
    sed -i \
        -e 's/serial->length/ASN1_STRING_length(serial)/g' \
        -e 's/serial->data/ASN1_STRING_get0_data(serial)/g' \
        "${NGINX_SRC_DIR}/src/event/ngx_event_openssl_stapling.c"
    # BoringSSL is C++; add -lstdc++ after -lssl -lcrypto in all OpenSSL feature tests.
    sed -i 's/-lssl -lcrypto/-lssl -lcrypto -lstdc++/g' \
        "${NGINX_SRC_DIR}/auto/lib/openssl/conf"

    log INFO "Configuring nginx against BoringSSL at ${BSSL_SRC_DIR} ..."
    cd "$NGINX_SRC_DIR"
    ./configure \
        --prefix="${NGINX_PREFIX}" \
        --with-http_ssl_module \
        --with-http_v2_module \
        --with-http_v3_module \
        --with-cc-opt="-I ${BSSL_SRC_DIR}/include -L ${BSSL_SRC_DIR}/build -lstdc++ -lpthread" \
        --with-ld-opt="-L ${BSSL_SRC_DIR}/build -lstdc++ -lpthread"

    log INFO "Building nginx (takes a minute) ..."
    make -j"$(nproc)"
    make install
    cd "${REPO_ROOT}"
fi

if [[ "$SKIP_NGINX" -eq 0 ]]; then
    log INFO "Verifying nginx ..."
    [[ -x "$NGINX_BIN" ]] || die "Binary not found: ${NGINX_BIN}"
    "$NGINX_BIN" -V 2>&1 | grep -q "BoringSSL" \
        || die "nginx not linked against BoringSSL. Re-run without --skip-nginx."
    log INFO "nginx OK: BoringSSL confirmed."
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\n'
log INFO "All done. Installed:"
[[ "$SKIP_OPENSSL"    -eq 0 ]] && log INFO "  OpenSSL      ${OSSL_PREFIX}"
[[ "$SKIP_STRONGSWAN" -eq 0 ]] && log INFO "  strongSwan   ${SWAN_PREFIX}"
[[ "$SKIP_OPENSSH"    -eq 0 ]] && log INFO "  OpenSSH      ${SSHD_PREFIX}"
[[ "$SKIP_BORINGSSL"  -eq 0 ]] && log INFO "  BoringSSL    ${BSSL_SRC_DIR}/build"
[[ "$SKIP_NGINX"      -eq 0 ]] && log INFO "  nginx        ${NGINX_PREFIX}"
printf '\n'
log INFO "Next steps:"
log INFO "  1. Edit ${REPO_ROOT}/env.sh with your VM IPs and hostnames."
log INFO "  2. source ${REPO_ROOT}/env.sh"
log INFO "  3. Run: ./run.sh --proto tls --mode classical"
