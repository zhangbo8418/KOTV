#!/usr/bin/env python3
"""Minimal pkg-config for KOTV desktop builds (Windows meson / FFmpeg).

Reads .pc files from PKG_CONFIG_PATH only — never falls back to Strawberry.
Supports: --exists, --modversion, --cflags, --libs [--static], --variable=NAME.
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

_VAR_RE = re.compile(r"\$\{([A-Za-z0-9_]+)\}")


def split_pc_path(raw: str) -> list[str]:
    raw = raw.strip()
    if not raw:
        return []
    if ";" in raw:
        return [p.strip() for p in raw.split(";") if p.strip()]
    # Windows D:/foo — 不能按 : 切开盘符
    if re.match(r"^[A-Za-z]:[\\/]", raw):
        if raw.count(":") == 1:
            return [raw]
        return [p for p in re.split(r":(?=[A-Za-z]:[\\/])", raw) if p]
    return [p for p in raw.split(":") if p]


def pc_dirs() -> list[Path]:
    return [Path(p) for p in split_pc_path(os.environ.get("PKG_CONFIG_PATH", ""))]


def expand(value: str, variables: dict[str, str], depth: int = 0) -> str:
    if depth > 20:
        return value

    def repl(m: re.Match[str]) -> str:
        key = m.group(1)
        if key not in variables:
            return m.group(0)
        return expand(variables[key], variables, depth + 1)

    return _VAR_RE.sub(repl, value)


def parse_pc(path: Path) -> tuple[dict[str, str], dict[str, str]]:
    variables: dict[str, str] = {}
    fields: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if ":" in line:
            key, _, val = line.partition(":")
            key = key.strip()
            # Distinguish Name: from weird vars; field keys are capitalized conventionally
            if key and ("=" not in key):
                fields[key] = val.strip()
                continue
        if "=" in line:
            key, _, val = line.partition("=")
            variables[key.strip()] = val.strip()
    # Expand field values with variables
    for k, v in list(fields.items()):
        fields[k] = expand(v, variables)
    for k, v in list(variables.items()):
        variables[k] = expand(v, variables)
    return variables, fields


def find_pc(name: str) -> Path | None:
    for d in pc_dirs():
        cand = d / f"{name}.pc"
        if cand.is_file():
            return cand
    return None


def load(name: str) -> tuple[dict[str, str], dict[str, str]]:
    path = find_pc(name)
    if path is None:
        raise FileNotFoundError(name)
    return parse_pc(path)


_OPS = (">=", "<=", "!=", "=", ">", "<")
_MOD_VER_RE = re.compile(
    r"^([A-Za-z0-9_+./-]+)\s*(>=|<=|!=|=|>|<)\s*(\S+)\s*$"
)


def split_mods(s: str) -> list[str]:
    out: list[str] = []
    for tok in s.replace(",", " ").split():
        # strip version constraints: libfoo >= 1.0
        if tok in _OPS:
            continue
        if tok[0:1] in "0123456789":
            continue
        out.append(tok)
    return out


def parse_module_spec(spec: str) -> tuple[str, str | None, str | None]:
    """Parse 'libfoo' or 'libfoo >= 1.2' → (name, op|None, version|None)."""
    spec = spec.strip()
    m = _MOD_VER_RE.match(spec)
    if m:
        return m.group(1), m.group(2), m.group(3)
    parts = spec.split()
    return (parts[0] if parts else spec), None, None


def normalize_module_args(
    raw: list[str],
) -> list[tuple[str, str | None, str | None]]:
    """FFmpeg may pass 'libaribcaption >= 1.1.1' as one argv or three."""
    out: list[tuple[str, str | None, str | None]] = []
    i = 0
    while i < len(raw):
        if i + 2 < len(raw) and raw[i + 1] in _OPS:
            out.append((raw[i], raw[i + 1], raw[i + 2]))
            i += 3
            continue
        out.append(parse_module_spec(raw[i]))
        i += 1
    return out


def ver_tuple(s: str) -> tuple[int, ...]:
    parts: list[int] = []
    for p in s.replace("-", ".").split("."):
        digits = "".join(ch for ch in p if ch.isdigit())
        parts.append(int(digits) if digits else 0)
    return tuple(parts)


def ver_compare(got: str, op: str, want: str) -> bool:
    g, w = ver_tuple(got), ver_tuple(want)
    if op == ">=":
        return g >= w
    if op == "<=":
        return g <= w
    if op == ">":
        return g > w
    if op == "<":
        return g < w
    if op in ("=", "=="):
        return g == w
    if op == "!=":
        return g != w
    return False


def collect(
    modules: list[str],
    *,
    static: bool,
    want_cflags: bool,
    want_libs: bool,
) -> tuple[list[str], list[str]]:
    cflags: list[str] = []
    libs: list[str] = []
    seen: set[str] = set()

    def walk(mod: str) -> None:
        if mod in seen:
            return
        seen.add(mod)
        _vars, fields = load(mod)
        if want_cflags and fields.get("Cflags"):
            cflags.extend(fields["Cflags"].split())
        if want_libs:
            if fields.get("Libs"):
                libs.extend(fields["Libs"].split())
            # 前缀全是静态库；Windows meson 经常不传 --static
            if fields.get("Libs.private"):
                libs.extend(fields["Libs.private"].split())
        req = f"{fields.get('Requires', '')} {fields.get('Requires.private', '')}"
        for dep in split_mods(req):
            try:
                walk(dep)
            except FileNotFoundError:
                # Windows PREFIX 常缺 zlib.pc 等 Requires.private；静态链接已由调用方补 -l。
                continue

    _ = static  # 保留参数：调用方仍传 static=

    for m in modules:
        walk(m)
    return cflags, libs


def dedupe_flags(flags: list[str]) -> list[str]:
    # Keep order; allow duplicate -l only once from the end for static link quirks —
    # pkg-config usually keeps all -l; we keep first occurrence of -I/-L and all -l.
    out: list[str] = []
    seen_path: set[str] = set()
    for f in flags:
        if f.startswith(("-I", "-L")):
            if f in seen_path:
                continue
            seen_path.add(f)
        out.append(f)
    return out


def main(argv: list[str]) -> int:
    if not argv:
        print("kotv-pkg-config: missing args", file=sys.stderr)
        return 1

    exists = False
    modversion = False
    cflags = False
    libs = False
    static = False
    atleast: str | None = None
    variable: str | None = None
    modules: list[str] = []

    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("--version", "-v"):
            print("0.29.2")
            return 0
        elif a == "--exists":
            exists = True
        elif a == "--modversion":
            modversion = True
        elif a == "--cflags":
            cflags = True
        elif a == "--libs":
            libs = True
        elif a == "--static":
            static = True
        elif a.startswith("--atleast-version="):
            atleast = a.split("=", 1)[1]
        elif a == "--atleast-version" and i + 1 < len(argv):
            i += 1
            atleast = argv[i]
        elif a.startswith("--variable="):
            variable = a.split("=", 1)[1]
        elif a == "--variable" and i + 1 < len(argv):
            i += 1
            variable = argv[i]
        elif a.startswith("-"):
            # ignore unknown flags meson may pass (--print-errors etc.)
            pass
        else:
            modules.append(a)
        i += 1

    if not modules:
        print("kotv-pkg-config: no modules", file=sys.stderr)
        return 1

    specs = normalize_module_args(modules)
    names = [n for n, _, _ in specs]

    try:
        if exists or atleast is not None or any(op for _, op, _ in specs):
            for name, op, want in specs:
                _v, fields = load(name)
                got = fields.get("Version", "0")
                if atleast is not None:
                    if ver_tuple(got) < ver_tuple(atleast):
                        print(
                            f"Requested '{name}' version '{atleast}' but version of {name} is '{got}'",
                            file=sys.stderr,
                        )
                        return 1
                if op and want and not ver_compare(got, op, want):
                    print(
                        f"Requested '{name} {op} {want}' but version of {name} is '{got}'",
                        file=sys.stderr,
                    )
                    return 1
            # --exists / 纯版本探测到此结束；若同时要 cflags/libs 则继续。
            if exists or (
                atleast is not None and not (cflags or libs or modversion or variable)
            ):
                return 0
            if any(op for _, op, _ in specs) and not (
                cflags or libs or modversion or variable or exists
            ):
                return 0
        if modversion:
            _v, fields = load(names[0])
            print(fields.get("Version", "0"))
            return 0
        if variable is not None:
            variables, _fields = load(names[0])
            print(variables.get(variable, ""))
            return 0
        cf, lf = collect(
            names, static=static, want_cflags=cflags, want_libs=libs
        )
        parts: list[str] = []
        if cflags:
            parts.extend(dedupe_flags(cf))
        if libs:
            parts.extend(dedupe_flags(lf))
        if parts:
            print(" ".join(parts))
        return 0
    except FileNotFoundError as e:
        print(f"Package {e} was not found in the pkg-config search path.", file=sys.stderr)
        print(f"PKG_CONFIG_PATH={os.environ.get('PKG_CONFIG_PATH', '')}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
