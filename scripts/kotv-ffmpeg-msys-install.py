#!/usr/bin/env python3
"""MSYS/MinGW：把已编译的静态 FFmpeg 装进前缀（libs / headers / pkg-config）。

`make install` 会把头文件列表展开进一条 sh -c，触顶 ARG_MAX。
本脚本按文件拷贝。用法（在已 configure+make 的 ffmpeg 树根）：
  python3 kotv-ffmpeg-msys-install.py --prefix /path/to/prefix
"""
from __future__ import annotations

import argparse
import re
import shutil
import sys
from pathlib import Path

# 桌面 AV3A 静态构建启用的库（无 libavdevice）。
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


def is_ffmpeg_build_tree(root: Path) -> bool:
    # tip 把 config.h 写在树根（configure: cp_if_changed … config.h），不是 ffbuild/。
    if (root / "config.h").is_file():
        return True
    if (root / "ffbuild" / "config.h").is_file():
        return True
    # 兜底：静态库已编出。
    return (root / "libavutil" / "libavutil.a").is_file()


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
    if not pc.is_file():
        raise SystemExit(f"ERROR: missing {pc}")
    copy_file(pc, prefix / "lib" / "pkgconfig" / pc.name)

    makefile = sub / "Makefile"
    headers = parse_make_list(makefile, "HEADERS") + parse_make_list(
        makefile, "BUILT_HEADERS"
    )
    if not headers:
        raise SystemExit(f"ERROR: no HEADERS in {makefile}")

    inc = prefix / "include" / lib
    copied = 0
    skipped = 0
    for name in headers:
        src = sub / name
        if not src.is_file():
            skipped += 1
            continue
        copy_file(src, inc / name)
        copied += 1
    if copied < 1:
        raise SystemExit(f"ERROR: {lib} installed 0 headers")
    if skipped:
        print(f"ok {lib}: skipped {skipped} absent headers")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--prefix", required=True, type=Path)
    ap.add_argument(
        "--src",
        type=Path,
        default=Path.cwd(),
        help="FFmpeg build tree (default: cwd)",
    )
    args = ap.parse_args()
    root = args.src.resolve()
    prefix = args.prefix.resolve()
    if not is_ffmpeg_build_tree(root):
        print(
            f"ERROR: not a configured FFmpeg tree (no config.h / libavutil.a): {root}",
            file=sys.stderr,
        )
        return 1
    for lib in LIBS:
        install_lib(root, prefix, lib)
    print(f"ok FFmpeg prefix install → {prefix}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
