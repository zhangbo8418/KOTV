#!/usr/bin/env bash
# mpv-android buildscripts 的 KOTV 补丁（幂等）：
# - include/cmake-android.sh：CMake 4 拒绝 cmake_minimum_required < 3.5（如 uavs3d 仍写 3.1），
#   给 android_cmake_setup 统一加 POLICY_VERSION_MINIMUM。
# - scripts/freetype2.sh：-Dharfbuzz=disabled。freetype 先于 harfbuzz 构建，auto 会退成 dynamic，
#   自动微调时 dlsym(RTLD_DEFAULT) 取 hb_*；Android 7 拿到系统 libharfbuzz_ng.so，排字幕时 SIGSEGV。
set -euo pipefail
bs="${1:?usage: $0 <path/to/mpv-android/buildscripts>}"
python3 - "$bs" <<'PY'
from pathlib import Path
import re
import sys

bs = Path(sys.argv[1])

cmake_sh = bs / "include" / "cmake-android.sh"
text = cmake_sh.read_text(encoding="utf-8")
needle = "-DCMAKE_POSITION_INDEPENDENT_CODE=ON \\\n"
flag = "-DCMAKE_POLICY_VERSION_MINIMUM=3.5 \\\n\t\t"
if "CMAKE_POLICY_VERSION_MINIMUM" in text:
    print("ok cmake-android already sets CMAKE_POLICY_VERSION_MINIMUM")
elif needle not in text:
    raise SystemExit("ERROR: cmake-android.sh PIC flag line changed; update KOTV patch")
else:
    cmake_sh.write_text(text.replace(needle, needle + flag, 1), encoding="utf-8")
    print("ok cmake-android: CMAKE_POLICY_VERSION_MINIMUM=3.5")

freetype_sh = bs / "scripts" / "freetype2.sh"
text = freetype_sh.read_text(encoding="utf-8")
setup = re.compile(r"^(meson setup [^\n]*?)(\s*)$", re.M)
m = setup.search(text)
if m is None:
    raise SystemExit("ERROR: freetype2.sh has no 'meson setup' line; update KOTV patch")
if "-Dharfbuzz=" in m.group(1):
    print("ok freetype2 already sets -Dharfbuzz")
else:
    text = text[:m.end(1)] + " -Dharfbuzz=disabled" + text[m.end(1):]
    freetype_sh.write_text(text, encoding="utf-8")
    print("ok freetype2: -Dharfbuzz=disabled")
PY
