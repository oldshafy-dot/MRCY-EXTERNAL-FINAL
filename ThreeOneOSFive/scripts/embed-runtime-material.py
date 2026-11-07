#!/usr/bin/env python3
"""Fold build-setting material into opaque Swift byte arrays."""

from __future__ import annotations

import base64
import hashlib
import os
import re
import socket
import ssl
import sys
from urllib.parse import urlparse

SALT = bytes(
    (
        0x6B,
        0x2E,
        0xC1,
        0x94,
        0x0A,
        0x57,
        0xD3,
        0x18,
        0xF6,
        0x41,
        0x8C,
        0xB9,
        0x23,
        0x7A,
        0xE0,
        0x5D,
        0x11,
        0xA8,
        0x3F,
        0xC6,
        0x90,
        0x4B,
        0x72,
        0xDE,
        0x05,
        0x69,
        0xB4,
        0x2C,
        0x87,
        0xFA,
        0x13,
        0xE5,
    )
)

# Vita builds must use their own host pins; no Gojo fallback.
FALLBACK_PINS = ()


def normalize(value: str) -> str:
    return (
        (value or "")
        .strip()
        .replace("/$()/", "/")
        .replace("$(LICENSE_SERVER_BASE_URL)", "")
        .replace("$(CONTENT_MANIFEST_PUBLIC_KEY)", "")
        .replace("$(RESPONSE_RSA3072_PUBLIC_KEY)", "")
    )


def cloak(data: bytes) -> list[int]:
    out: list[int] = []
    for index, byte in enumerate(data):
        folded = byte ^ SALT[index % len(SALT)]
        folded ^= (0xA5 ^ ((index * 13) & 0xFF)) & 0xFF
        folded = ((folded << 5) | (folded >> 3)) & 0xFF
        folded ^= (0x3C ^ ((index * 29) & 0xFF)) & 0xFF
        folded = ((folded << 2) | (folded >> 6)) & 0xFF
        out.append(folded)
    return out


def fmt(values: list[int]) -> str:
    if not values:
        return ""
    parts = [f"0x{value:02X}" for value in values]
    lines: list[str] = []
    for offset in range(0, len(parts), 12):
        lines.append("        " + ", ".join(parts[offset : offset + 12]))
    return ",\n".join(lines)


def decode_key(raw: str) -> bytes:
    if not raw:
        return b""
    try:
        key = base64.b64decode(raw, validate=True)
    except Exception:
        return b""
    return key if len(key) == 32 else b""


def decode_rsa(raw: str) -> bytes:
    if not raw:
        return b""
    try:
        key = base64.b64decode(raw, validate=True)
    except Exception:
        return b""
    return key if 300 <= len(key) <= 800 and key[:1] == b"\x30" else b""


def read_len(data: bytes, index: int) -> tuple[int, int]:
    first = data[index]
    index += 1
    if first < 0x80:
        return first, index
    count = first & 0x7F
    if count == 0 or count > 4 or index + count > len(data):
        raise ValueError("invalid length")
    value = int.from_bytes(data[index : index + count], "big")
    return value, index + count


def read_tlv(data: bytes, index: int) -> tuple[int, bytes, bytes, int]:
    start = index
    tag = data[index]
    index += 1
    length, index = read_len(data, index)
    end = index + length
    if end > len(data):
        raise ValueError("truncated tlv")
    return tag, data[start:end], data[index:end], end


def extract_spki(der: bytes) -> bytes:
    tag, _, body, _ = read_tlv(der, 0)
    if tag != 0x30:
        raise ValueError("certificate is not a sequence")
    tag, _, tbs, _ = read_tlv(body, 0)
    if tag != 0x30:
        raise ValueError("tbs is not a sequence")
    fields: list[tuple[int, bytes]] = []
    index = 0
    while index < len(tbs):
        tag, raw, _, index = read_tlv(tbs, index)
        fields.append((tag, raw))
    offset = 1 if fields and fields[0][0] == 0xA0 else 0
    if len(fields) <= offset + 5:
        raise ValueError("spki missing")
    return fields[offset + 5][1]


def fetch_leaf_der(url: str) -> bytes:
    parsed = urlparse(url)
    host = parsed.hostname
    if parsed.scheme != "https" or not host:
        raise ValueError("pin source is not https")
    port = parsed.port or 443
    context = ssl.create_default_context()
    with socket.create_connection((host, port), timeout=15) as raw:
        with context.wrap_socket(raw, server_hostname=host) as sock:
            der = sock.getpeercert(binary_form=True)
    if not der:
        raise ValueError("server did not present a certificate")
    return der


def parse_hex_pins(raw: str) -> list[bytes]:
    pins: list[bytes] = []
    for part in re.split(r"[,\s;]+", raw or ""):
        token = part.strip().lower()
        if not token:
            continue
        if len(token) != 64 or any(char not in "0123456789abcdef" for char in token):
            raise ValueError("TLS pin is not a SHA-256 hex digest")
        pins.append(bytes.fromhex(token))
    return pins


def collect_pins(url: str) -> bytes:
    pins: list[bytes] = []

    def add(pin: bytes) -> None:
        if pin not in pins:
            pins.append(pin)

    if url:
        try:
            der = fetch_leaf_der(url)
            add(hashlib.sha256(extract_spki(der)).digest())
            add(hashlib.sha256(der).digest())
        except Exception as error:
            print(f"live TLS pin fetch failed: {error}", file=sys.stderr)

    for pin in parse_hex_pins(os.environ.get("TLS_PIN_SPKI_SHA256", "")):
        add(pin)

    if url:
        for pin in FALLBACK_PINS:
            add(pin)

    if url and not pins:
        raise SystemExit("TLS pin missing")
    if len(pins) > 8:
        raise SystemExit("too many TLS pins")
    return b"".join(pins)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: embed-runtime-material.py <output.swift>", file=sys.stderr)
        return 2

    wire = normalize(os.environ.get("LICENSE_SERVER_BASE_URL", "")).encode("utf-8")
    mark = decode_key(normalize(os.environ.get("CONTENT_MANIFEST_PUBLIC_KEY", "")))
    response = decode_rsa(normalize(os.environ.get("RESPONSE_RSA3072_PUBLIC_KEY", "")))
    if os.environ.get("CONFIGURATION") == "Release" or wire or mark or response:
        parsed = urlparse(wire.decode("utf-8"))
        if parsed.scheme != "https" or not parsed.hostname or len(mark) != 32 or not response:
            raise SystemExit("Configure the Vita HTTPS URL, Ed25519 public key and RSA public key before building.")
    pins = collect_pins(wire.decode("utf-8") if wire else "")
    packed = cloak(wire)
    mid = len(packed) // 2
    output = "\n".join(
        (
            "enum RuntimeBlob {",
            "    static let s: [UInt8] = [",
            fmt(list(SALT)),
            "    ]",
            "    static let w0: [UInt8] = [",
            fmt(packed[:mid]),
            "    ]",
            "    static let w1: [UInt8] = [",
            fmt(packed[mid:]),
            "    ]",
            "    static let m: [UInt8] = [",
            fmt(cloak(mark)),
            "    ]",
            "    static let r: [UInt8] = [",
            fmt(cloak(response)),
            "    ]",
            "    static let p: [UInt8] = [",
            fmt(cloak(pins)),
            "    ]",
            "}",
            "",
        )
    )
    destination = sys.argv[1]
    os.makedirs(os.path.dirname(destination) or ".", exist_ok=True)
    with open(destination, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
