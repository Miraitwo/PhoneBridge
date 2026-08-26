#!/usr/bin/env python3

"""Build a modern macOS ICNS container from a prepared iconset directory."""

from __future__ import annotations

import argparse
import struct
from pathlib import Path


ICON_ENTRIES = (
    (b"ic07", "icon_128x128.png"),
    (b"ic08", "icon_256x256.png"),
    (b"ic09", "icon_512x512.png"),
    (b"ic10", "icon_512x512@2x.png"),
    (b"ic11", "icon_16x16@2x.png"),
    (b"ic12", "icon_32x32@2x.png"),
    (b"ic13", "icon_128x128@2x.png"),
    (b"ic14", "icon_256x256@2x.png"),
)


def chunk(kind: bytes, payload: bytes) -> bytes:
    return kind + struct.pack(">I", 8 + len(payload)) + payload


def build_icns(iconset: Path, output: Path) -> None:
    entries = [(kind, (iconset / filename).read_bytes()) for kind, filename in ICON_ENTRIES]
    toc_payload = b"".join(kind + struct.pack(">I", 8 + len(payload)) for kind, payload in entries)
    body = chunk(b"TOC ", toc_payload) + b"".join(chunk(kind, payload) for kind, payload in entries)
    output.write_bytes(b"icns" + struct.pack(">I", 8 + len(body)) + body)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("iconset", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    build_icns(args.iconset, args.output)


if __name__ == "__main__":
    main()
