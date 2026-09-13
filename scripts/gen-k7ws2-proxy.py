#!/usr/bin/env python3
"""Scan PE files for WS2_32 imports and emit a Win7-safe k7ws2 proxy DLL sources.

- GetHostNameW is implemented locally (Win8+; fallback via gethostname).
- Every other scanned import is forwarded to the real system ws2_32.dll.

Usage:
  gen-k7ws2-proxy.py --out-dir build/k7ws2 path/to/kotv.exe path/to/*.dll
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

# Win8+ WS2 APIs that must not be forwarded to system ws2_32 on Win7.
WIN8_PLUS = {
    "GetHostNameW",
    "FreeAddrInfoEx",
    "FreeAddrInfoExW",
    "GetAddrInfoExCancel",
    "GetAddrInfoExOverlappedResult",
    "ProcessSocketNotifications",
}
LOCAL_IMPL = {"GetHostNameW"}


def _u16(b: bytes, o: int) -> int:
    return struct.unpack_from("<H", b, o)[0]


def _u32(b: bytes, o: int) -> int:
    return struct.unpack_from("<I", b, o)[0]


def _i32(b: bytes, o: int) -> int:
    return struct.unpack_from("<i", b, o)[0]


def rva_to_off(data: bytes, rva: int) -> int | None:
    e = _i32(data, 0x3C)
    nsec = _u16(data, e + 6)
    opt = _u16(data, e + 20)
    sec = e + 24 + opt
    for i in range(nsec):
        so = sec + i * 40
        va = _u32(data, so + 12)
        vsz = _u32(data, so + 8)
        raw = _u32(data, so + 20)
        rsz = _u32(data, so + 16)
        if va <= rva < va + max(vsz, rsz):
            return rva - va + raw
    return None


def pe_ws2_imports(path: Path) -> set[str]:
    data = path.read_bytes()
    if len(data) < 0x40 or data[0:2] != b"MZ":
        return set()
    e = _i32(data, 0x3C)
    if data[e : e + 4] != b"PE\0\0":
        return set()
    magic = _u16(data, e + 24)
    if magic == 0x20B:
        import_rva = _u32(data, e + 24 + 112 + 8)
        entry_size = 8
        ord_flag = 1 << 63
    elif magic == 0x10B:
        import_rva = _u32(data, e + 24 + 96 + 8)
        entry_size = 4
        ord_flag = 1 << 31
    else:
        return set()
    if not import_rva:
        return set()
    desc = rva_to_off(data, import_rva)
    if desc is None:
        return set()
    found: set[str] = set()
    while True:
        oft = _u32(data, desc + 0)
        name_rva = _u32(data, desc + 12)
        ft = _u32(data, desc + 16)
        if oft == 0 and name_rva == 0 and ft == 0:
            break
        dll_off = rva_to_off(data, name_rva) if name_rva else None
        dll = ""
        if dll_off is not None:
            dll = data[dll_off : data.index(b"\0", dll_off)].decode("ascii", "replace")
        if dll.lower() not in ("ws2_32.dll", "ws2_32"):
            desc += 20
            continue
        thunk_rva = oft or ft
        thunk = rva_to_off(data, thunk_rva) if thunk_rva else None
        if thunk is None:
            desc += 20
            continue
        i = 0
        while True:
            eo = thunk + i * entry_size
            val = (
                struct.unpack_from("<Q", data, eo)[0]
                if entry_size == 8
                else _u32(data, eo)
            )
            if val == 0:
                break
            if not (val & ord_flag):
                hint_off = rva_to_off(data, val & 0x7FFFFFFF)
                if hint_off is not None:
                    n = data[hint_off + 2 : data.index(b"\0", hint_off + 2)].decode(
                        "ascii", "replace"
                    )
                    found.add(n)
            i += 1
        desc += 20
    return found


C_SRC = r"""/* Auto-generated Win7 ws2_32 proxy: GetHostNameW + forwards. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winsock2.h>

/* Win8+ API missing on Win7: implement via ANSI gethostname. */
__declspec(dllexport) int WSAAPI GetHostNameW(wchar_t *name, int namelen)
{
    char buf[256];
    int n;

    if (name == NULL || namelen <= 0) {
        WSASetLastError(WSAEFAULT);
        return SOCKET_ERROR;
    }
    if (gethostname(buf, (int)sizeof(buf)) != 0)
        return SOCKET_ERROR;
    n = MultiByteToWideChar(CP_ACP, 0, buf, -1, name, namelen);
    if (n == 0) {
        WSASetLastError(WSAEFAULT);
        return SOCKET_ERROR;
    }
    return 0;
}
"""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", type=Path, required=True)
    ap.add_argument("pe", nargs="+", type=Path)
    args = ap.parse_args()

    names: set[str] = set()
    for p in args.pe:
        if p.is_file():
            n = pe_ws2_imports(p)
            if n:
                print(f"  {p.name}: {len(n)} ws2 imports")
                names |= n
    if not names:
        print("WARN: no WS2_32 imports found; still emitting GetHostNameW-only stub", file=sys.stderr)
    names.add("GetHostNameW")

    args.out_dir.mkdir(parents=True, exist_ok=True)
    (args.out_dir / "k7ws2.c").write_text(C_SRC, encoding="utf-8")

    lines = ['LIBRARY "k7ws2.dll"', "EXPORTS"]
    for n in sorted(names):
        if n in LOCAL_IMPL:
            lines.append(f"  {n}")
        else:
            # Forward to the real system DLL (KnownDLL path via LoadLibrary name).
            lines.append(f"  {n} = ws2_32.{n}")
    def_text = "\n".join(lines) + "\n"
    (args.out_dir / "k7ws2.def").write_text(def_text, encoding="utf-8")
    print(f"ok wrote {args.out_dir}/k7ws2.{{c,def}} ({len(names)} exports)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
