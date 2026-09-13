#!/usr/bin/env python3
"""Rewrite Win8+ PE imports to Win7-compatible equivalents (in-place).

Rust ≥1.78 std hard-imports GetSystemTimePreciseAsFileTime from KERNEL32.
That export does not exist on Windows 7, so LoadLibrary/startup fails with
"entry point not found". The Win7 API GetSystemTimeAsFileTime has the same
signature; rewriting the import name string is enough for a working fallback.

Usage:
  patch-win7-pe-imports.py path/to/mpv-2.dll [more.pe ...]
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

OLD = b"GetSystemTimePreciseAsFileTime"
NEW = b"GetSystemTimeAsFileTime"


def _u16(data: bytes, off: int) -> int:
    return struct.unpack_from("<H", data, off)[0]


def _u32(data: bytes, off: int) -> int:
    return struct.unpack_from("<I", data, off)[0]


def _i32(data: bytes, off: int) -> int:
    return struct.unpack_from("<i", data, off)[0]


def rva_to_off(data: bytes, rva: int) -> int | None:
    e = _i32(data, 0x3C)
    num_sections = _u16(data, e + 6)
    opt_size = _u16(data, e + 20)
    sec = e + 24 + opt_size
    for i in range(num_sections):
        so = sec + i * 40
        va = _u32(data, so + 12)
        vsz = _u32(data, so + 8)
        raw = _u32(data, so + 20)
        rawsz = _u32(data, so + 16)
        span = max(vsz, rawsz)
        if va <= rva < va + span:
            return rva - va + raw
    return None


def patch_file(path: Path) -> int:
    data = bytearray(path.read_bytes())
    if len(data) < 0x40 or data[0:2] != b"MZ":
        raise SystemExit(f"not a PE: {path}")
    e = _i32(data, 0x3C)
    if data[e : e + 4] != b"PE\0\0":
        raise SystemExit(f"not a PE: {path}")
    magic = _u16(data, e + 24)
    if magic == 0x20B:  # PE32+
        import_rva = _u32(data, e + 24 + 112 + 8)
    elif magic == 0x10B:  # PE32
        import_rva = _u32(data, e + 24 + 96 + 8)
    else:
        raise SystemExit(f"unsupported PE magic {magic:#x}: {path}")
    if import_rva == 0:
        print(f"ok {path.name}: no imports")
        return 0

    patched = 0
    desc = rva_to_off(data, import_rva)
    if desc is None:
        raise SystemExit(f"cannot map import RVA: {path}")

    # IMAGE_IMPORT_DESCRIPTOR is 20 bytes; last is all-zero.
    while True:
        oft_rva = _u32(data, desc + 0)
        name_rva = _u32(data, desc + 12)
        ft_rva = _u32(data, desc + 16)
        if oft_rva == 0 and name_rva == 0 and ft_rva == 0:
            break
        dll_off = rva_to_off(data, name_rva) if name_rva else None
        dll = b""
        if dll_off is not None:
            end = data.index(b"\0", dll_off)
            dll = bytes(data[dll_off:end])
        thunk_rva = oft_rva or ft_rva
        thunk = rva_to_off(data, thunk_rva) if thunk_rva else None
        if thunk is None:
            desc += 20
            continue
        entry_size = 8 if magic == 0x20B else 4
        ord_flag = 1 << (63 if magic == 0x20B else 31)
        i = 0
        while True:
            entry_off = thunk + i * entry_size
            if magic == 0x20B:
                val = struct.unpack_from("<Q", data, entry_off)[0]
            else:
                val = _u32(data, entry_off)
            if val == 0:
                break
            if val & ord_flag:
                i += 1
                continue
            hint_rva = val & 0x7FFFFFFF
            hint_off = rva_to_off(data, hint_rva)
            if hint_off is None:
                i += 1
                continue
            name_off = hint_off + 2
            # Read existing import name
            try:
                z = data.index(b"\0", name_off)
            except ValueError:
                i += 1
                continue
            name = bytes(data[name_off:z])
            if name == OLD:
                if len(NEW) > len(OLD):
                    raise SystemExit("replacement longer than original")
                data[name_off : name_off + len(OLD) + 1] = NEW + b"\0" * (len(OLD) - len(NEW) + 1)
                patched += 1
                dll_s = dll.decode("ascii", "replace")
                print(f"  patched {path.name}: {dll_s}!{OLD.decode()} -> {NEW.decode()}")
            i += 1
        desc += 20

    if patched:
        path.write_bytes(data)
    print(f"ok {path.name}: rewrote {patched} import(s)")
    return patched


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("pe", nargs="+", type=Path)
    args = ap.parse_args()
    total = 0
    for p in args.pe:
        if not p.is_file():
            print(f"ERROR: missing {p}", file=sys.stderr)
            return 1
        total += patch_file(p)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
