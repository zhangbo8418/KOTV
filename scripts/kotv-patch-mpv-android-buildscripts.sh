#!/usr/bin/env bash
# mpv-android：CMake 4 拒绝 cmake_minimum_required < 3.5（如 uavs3d 仍写 3.1）。
# 给 include/cmake-android.sh 的 android_cmake_setup 统一加 POLICY_VERSION_MINIMUM。
set -euo pipefail
cmake_sh="${1:?usage: $0 <path/to/cmake-android.sh>}"
python3 - "$cmake_sh" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
needle = "-DCMAKE_POSITION_INDEPENDENT_CODE=ON \\\n"
flag = "-DCMAKE_POLICY_VERSION_MINIMUM=3.5 \\\n\t\t"
if "CMAKE_POLICY_VERSION_MINIMUM" in text:
    print("ok cmake-android already sets CMAKE_POLICY_VERSION_MINIMUM")
elif needle not in text:
    raise SystemExit("ERROR: cmake-android.sh PIC flag line changed; update KOTV patch")
else:
    path.write_text(text.replace(needle, needle + flag, 1), encoding="utf-8")
    print("ok cmake-android: CMAKE_POLICY_VERSION_MINIMUM=3.5")
PY
