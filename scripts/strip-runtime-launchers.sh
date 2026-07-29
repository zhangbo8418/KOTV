#!/usr/bin/env bash
# 从已拷贝的 runtime/ 去掉 java/python 启动器（embed 只用 libjvm/libpython + stdlib）。
# 用法: ./scripts/strip-runtime-launchers.sh <runtime-dir>
set -euo pipefail

RT="${1:?runtime dir}"
[[ -d "$RT" ]] || { echo "error: not a directory: $RT" >&2; exit 1; }

echo "==> strip java/python launchers under $RT"
# JRE：只删启动器；保留 bin 下 DLL（Windows jvm 依赖）与 lib/
rm -f \
  "$RT/jre/bin/java" "$RT/jre/bin/java.exe" \
  "$RT/jre/bin/javaw" "$RT/jre/bin/javaw.exe" \
  "$RT/jre/bin/keytool" "$RT/jre/bin/keytool.exe" \
  "$RT/jre/bin/jjs" "$RT/jre/bin/jjs.exe" \
  "$RT/jre/bin/rmiregistry" "$RT/jre/bin/rmiregistry.exe" 2>/dev/null || true

# Python：删解释器启动器；保留 python3.dll / libpython* / Lib/
rm -f \
  "$RT/python/bin/python" "$RT/python/bin/python3" \
  "$RT/python/python.exe" "$RT/python/python3.exe" \
  "$RT/python/pythonw.exe" 2>/dev/null || true
# python3.x 带版本号的启动器
if [[ -d "$RT/python/bin" ]]; then
  find "$RT/python/bin" -maxdepth 1 \( -type f -o -type l \) \
    \( -name 'python' -o -name 'python3' -o -name 'python3.*' \) \
    ! -name '*.dll' ! -name '*.so*' ! -name '*.dylib' \
    -exec rm -f {} + 2>/dev/null || true
fi

echo "  ok: launchers stripped (libs kept)"
