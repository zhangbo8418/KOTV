#!/usr/bin/env python3
"""MSYS/MinGW 下安装静态 FFmpeg 前缀（libs / headers / pkg-config）。

`make install` 的 INSTALL_FILES 会把上百个头文件展开进一条 sh -c，
触顶 ARG_MAX 后在引号处截断。本脚本按文件拷贝，避免长命令行。
用法（在已编译的 ffmpeg 源码树根目录）：
  python3 kotv-ffmpeg-msys-install.py --prefix /path/to/prefix
"""
from __future__ import annotations

import argparse
import re
import shutil
import sys
from pathlib import Path

# 与桌面 AV3A 静态构建一致的库集合（无 libavdevice）。
LIBS = (
    "libavutil",
    "libavcodec",
    "libavformat",
    "libavfilter",
    "libswresample",
    "libswscale",
)


def parse_make_list(makefile: Path, var: str) -> list[str]:
    text = makefile.read_text(encoding="utf-8", errors="replace")
    m = re.search(rf"^{re.escape(var)}\s*=((?:.*\\\n)*.*)$", text, re.M)
    if not m:
        return []
    return re.findall(r"[\w./+-]+\.h", m.group(1))


def copy_file(src: Path, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dest)
    print(f"INSTALL\t{src.as_posix()} -> {dest.as_posix()}")


def install_lib(root: Path, prefix: Path, lib: str) -> None:
    sub = root / lib
    if not sub.is_dir():
        raise SystemExit(f"ERROR: missing {sub}")

    archive = sub / f"{lib}.a"
    if not archive.is_file():
        raise SystemExit(f"ERROR: missing {archive}")
    copy_file(archive, prefix / "lib" / archive.name)

    pc = sub / f"{lib}.pc"
    if pc.is_file():
        copy_file(pc, prefix / "lib" / "pkgconfig" / pc.name)
    else:
        raise SystemExit(f"ERROR: missing {pc}")

    makefile = sub / "Makefile"
    headers = parse_make_list(makefile, "HEADERS") + parse_make_list(
        makefile, "BUILT_HEADERS"
    )
    if not headers:
        raise SystemExit(f"ERROR: no HEADERS in {makefile}")
    inc = prefix / "include" / lib
    copied = 0
    skipped = []
    for name in headers:
        src = sub / name
        if not src.is_file():
            # SKIPHEADERS / 未启用后端的头可能不在树里；有则装、无则跳过。
            skipped.append(name)
            continue
        copy_file(src, inc / name)
        copied += 1
    if copied < 1:
        raise SystemExit(f"ERROR: {lib} installed 0 headers")
    if skipped:
        print(f"ok {lib}: skipped {len(skipped)} absent headers")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--prefix", required=True, type=Path)
    ap.add_argument(
        "--src",
        type=Path,
        default=Path.cwd(),
        help="FFmpeg build/source tree (default: cwd)",
    )
    args = ap.parse_args()
    root = args.src.resolve()
    prefix = args.prefix.resolve()
    if not (root / "ffbuild" / "config.h").is_file():
        print(f"ERROR: not an FFmpeg build tree: {root}", file=sys.stderr)
        return 1
    for lib in LIBS:
        install_lib(root, prefix, lib)
    print(f"ok FFmpeg prefix install → {prefix}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
