#!/usr/bin/env python3
"""
Convert an ML-DSA private key from OpenSSL 4.0 format to BoringSSL seed format.

OpenSSL 4.0 inner key (PKCS#8 privateKey field content):
  SEQUENCE { OCTET STRING (32-byte seed), OCTET STRING (expanded key) }

BoringSSL inner key (PKCS#8 privateKey field content):
  [0] IMPLICIT (32-byte seed)  -- context-specific primitive, tag 0x80

Usage:
  python3 pki/mldsa_to_bssl.py input.pem output.pem
"""

import sys
import base64


def read_der(path):
    with open(path, "rb") as f:
        data = f.read()
    if b"-----BEGIN" in data:
        lines = [l for l in data.splitlines() if not l.startswith(b"-----")]
        return base64.b64decode(b"".join(lines))
    return data


def write_pem(path, der, label="PRIVATE KEY"):
    b64 = base64.b64encode(der).decode()
    lines = [f"-----BEGIN {label}-----"]
    for i in range(0, len(b64), 64):
        lines.append(b64[i:i+64])
    lines.append(f"-----END {label}-----\n")
    with open(path, "w") as f:
        f.write("\n".join(lines))


def decode_length(data, pos):
    b = data[pos]
    pos += 1
    if b < 0x80:
        return b, pos
    n = b & 0x7f
    length = int.from_bytes(data[pos:pos+n], "big")
    return length, pos + n


def encode_length(n):
    if n < 0x80:
        return bytes([n])
    if n < 0x100:
        return bytes([0x81, n])
    if n < 0x10000:
        return bytes([0x82, n >> 8, n & 0xff])
    raise ValueError(f"length too large: {n}")


def get_tlv(data, pos):
    tag = data[pos]; pos += 1
    length, pos = decode_length(data, pos)
    value = data[pos:pos+length]
    return tag, value, pos + length


def build_tlv(tag, value):
    return bytes([tag]) + encode_length(len(value)) + value


def convert(in_path, out_path):
    der = read_der(in_path)

    tag, outer, _ = get_tlv(der, 0)
    assert tag == 0x30, f"expected SEQUENCE, got 0x{tag:02x}"

    pos = 0
    tag, ver, pos = get_tlv(outer, pos)
    assert tag == 0x02, "expected INTEGER (version)"
    version_tlv = build_tlv(tag, ver)

    tag, algo, pos = get_tlv(outer, pos)
    assert tag == 0x30, "expected AlgorithmIdentifier SEQUENCE"
    algo_tlv = build_tlv(tag, algo)

    tag, pk_content, pos = get_tlv(outer, pos)
    assert tag == 0x04, "expected OCTET STRING for privateKey"

    inner_tag = pk_content[0]
    if inner_tag == 0x80:
        print(f"{in_path}: already BoringSSL seed format, copying unchanged.")
        with open(in_path, "rb") as f:
            raw = f.read()
        with open(out_path, "wb") as f:
            f.write(raw)
        return

    if inner_tag != 0x30:
        raise ValueError(
            f"Unknown inner key tag 0x{inner_tag:02x}. "
            "Expected 0x30 (OpenSSL SEQUENCE) or 0x80 (BoringSSL [0] IMPLICIT)."
        )

    _, seq_content, _ = get_tlv(pk_content, 0)
    seed_tag, seed, _ = get_tlv(seq_content, 0)
    assert seed_tag == 0x04, "expected OCTET STRING for seed"
    assert len(seed) == 32, f"expected 32-byte seed, got {len(seed)}"

    bssl_inner = build_tlv(0x80, seed)
    new_pk_tlv = build_tlv(0x04, bssl_inner)
    new_outer = version_tlv + algo_tlv + new_pk_tlv
    new_der = build_tlv(0x30, new_outer)

    write_pem(out_path, new_der)
    print(f"Converted: {in_path} -> {out_path}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} input.pem output.pem", file=sys.stderr)
        sys.exit(1)
    convert(sys.argv[1], sys.argv[2])
