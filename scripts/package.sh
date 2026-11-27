#!/usr/bin/env bash
# 组装发行目录：二进制 + 随包运行时 + bridge
# 用法: ./scripts/package.sh [platform]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=kotv-release-name.sh
source "$ROOT/scripts/kotv-release-name.sh"
# shellcheck source=kotv-win-build-env.sh
source "$ROOT/scripts/kotv-win-build-env.sh"

PLAT="${1:-$(kotv_detect_host_plat)}"
DIST="$ROOT/dist/KOTV-$PLAT"
RUNTIME_SRC="$ROOT/runtime"
# 版本号：KOTV_VERSION / VERSION 优先，否则读 pubspec。
if [[ -z "${KOTV_VERSION:-}" && -n "${VERSION:-}" ]]; then
  KOTV_VERSION="$VERSION"
fi
VERSION="$(kotv_release_version "$ROOT/flutter/pubspec.yaml")"
kotv_check_version_literals "$VERSION"

echo "platform=$PLAT"
echo "dist=$DIST"
echo "version=$VERSION"

if [[ ! -d "$RUNTIME_SRC" || ! -d "$RUNTIME_SRC/bridge" || ( ! -x "$RUNTIME_SRC/node/node" && ! -f "$RUNTIME_SRC/node/node.exe" ) ]]; then
  echo "runtime missing (need bridge + node), running prepare-runtime.sh $PLAT ..."
  "$ROOT/scripts/prepare-runtime.sh" "$PLAT"
fi

rm -rf "$DIST"
mkdir -p "$DIST/runtime"

echo "building binary..."
case "$PLAT" in
  macos-arm64)  export GOOS=darwin  GOARCH=arm64 ;;
  macos-x64)    export GOOS=darwin  GOARCH=amd64 ;;
  linux-arm64)  export GOOS=linux   GOARCH=arm64 ;;
  linux-x64)    export GOOS=linux   GOARCH=amd64 ;;
  windows-x64)    export GOOS=windows GOARCH=amd64 ;;
  windows-arm64)  export GOOS=windows GOARCH=arm64 ;;
esac
export CGO_ENABLED=1
BIN="KOTV"
[[ "$GOOS" == "windows" ]] && BIN="KOTV.exe"

# Windows：QuickJS(CGO) Win7 —— MSVCRT MinGW + 静态链 MinGW 运行时 + 链接子系统 6.01
# QuickJS / crawshaw 等会用 pthread；crawshaw 还显式 #cgo LDFLAGS: -lwinpthread，
# 即便 win32 线程模型也会动态依赖 libwinpthread-1.dll → 必须强制静态链。
# 勿在 CGO_*FLAGS 里再 -D_WIN32_WINNT：go-libutp 等依赖已带 -D_WIN32_WINNT=0x600，会刷 redefine 警告。
# 勿用 UCRT 工具链，否则 Win7 上常见 Can't find dependent libraries / 缺 api-ms-win-crt-*
if [[ "$PLAT" == "windows-x64" ]]; then
  export CC="${CC:-gcc}"
  export CXX="${CXX:-g++}"
  export CGO_CFLAGS="${CGO_CFLAGS:--O2}"
  export CGO_CXXFLAGS="${CGO_CXXFLAGS:--O2}"
  if ! command -v "$CC" >/dev/null 2>&1; then
    echo "ERROR: Windows 打包需要 MinGW gcc（建议 MSVCRT + win32 线程模型）" >&2
    exit 1
  fi
  # 探测是否误用 UCRT 工具链
  if "$CC" -v 2>&1 | grep -qi 'ucrt'; then
    echo "WARNING: 当前 gcc 像是 UCRT 工具链，Win7 上 QuickJS/CGO 可能无法加载。请改用 msvcrt MinGW。" >&2
  fi
  # 删掉 winpthread 的 DLL import lib，迫使 -lwinpthread（含 crawshaw 注入的）走 .a 静态库
  mingw_root="$("$CC" -print-sysroot 2>/dev/null || true)"
  if [[ -z "$mingw_root" || "$mingw_root" == "/" ]]; then
    mingw_root="$(dirname "$(dirname "$(command -v "$CC")")")"
  fi
  while IFS= read -r dll_a; do
    echo "[cgo] remove DLL import to force static: $dll_a"
    rm -f "$dll_a"
  done < <(find "$mingw_root" -name 'libwinpthread.dll.a' -o -name 'libpthread.dll.a' 2>/dev/null || true)
  # -l:libwinpthread.a 明确静态；再加 -Bstatic 兜底（QuickJS pthread / crawshaw）
  WIN_PTHREAD_LD="-Wl,-Bstatic -l:libwinpthread.a -Wl,-Bdynamic"
  export CGO_LDFLAGS="${CGO_LDFLAGS:--static-libgcc -static-libstdc++ ${WIN_PTHREAD_LD}}"
  echo "[cgo] Win7 QuickJS flags: CC=$CC CGO_CFLAGS=$CGO_CFLAGS CGO_LDFLAGS=$CGO_LDFLAGS"
  if "$CC" -v 2>&1 | grep -qi 'Thread model: posix'; then
    echo "[cgo] gcc Thread model=posix（仍强制静态 winpthread）"
  fi
fi

if [[ "$PLAT" == "windows-arm64" ]]; then
  kotv_windows_export_cgo_arm64 || exit 1
fi

# Windows：嵌入 .ico 到 exe（Explorer / 任务栏）
if [[ "$PLAT" == windows-* ]]; then
  "$ROOT/scripts/gen-windows-icons.sh"
  "$ROOT/scripts/gen-win-syso.sh" "$PLAT" || true
fi

# ModuleLoader CGO 依赖 quickjs-go 头文件（qjsinc/ 不入库，构建前生成）
echo "generating spider qjsinc headers..."
(cd "$ROOT/internal/spider" && go run gen_qjsinc.go)

VER_LD="$(kotv_engine_version_ldflags "$VERSION")"
LDFLAGS="-s -w ${VER_LD}"
if [[ "$PLAT" == "windows-x64" ]]; then
  # 最终链接：静态 MinGW 运行时 + 强制静态 winpthread（crawshaw/QuickJS）+ Win7 子系统
  EXTLD="-static-libgcc -static-libstdc++ ${WIN_PTHREAD_LD:--Wl,-Bstatic -l:libwinpthread.a -Wl,-Bdynamic} -Wl,--subsystem,windows:6.01"
  (cd "$ROOT" && go build -ldflags "${LDFLAGS} -extldflags '${EXTLD}'" -o "$DIST/$BIN" .)
else
  (cd "$ROOT" && go build -ldflags "$LDFLAGS" -o "$DIST/$BIN" .)
fi

if [[ "$PLAT" == "windows-x64" ]]; then
  if command -v pwsh >/dev/null 2>&1; then
    pwsh -File "$ROOT/scripts/check-win7-deps.ps1" -Exe "$DIST/$BIN" || true
  elif command -v powershell >/dev/null 2>&1; then
    powershell -File "$ROOT/scripts/check-win7-deps.ps1" -Exe "$DIST/$BIN" || true
  elif command -v objdump >/dev/null 2>&1; then
    echo "[cgo] objdump dependents (manual Win7 check):"
    objdump -p "$DIST/$BIN" 2>/dev/null | grep -i "DLL Name" || true
  fi
fi

echo "copying runtime..."
# macOS 用 ditto，避免 cp 丢 dylib/符号链接（曾出现 jre/lib 缺失 → bridge EOF）
if [[ "$(uname -s)" == "Darwin" ]] && command -v ditto >/dev/null 2>&1; then
  mkdir -p "$DIST/runtime"
  ditto "$RUNTIME_SRC" "$DIST/runtime"
else
  cp -a "$RUNTIME_SRC/." "$DIST/runtime/"
fi
# 不进发行包：外部 mpv 可执行文件、空的 lib/ 及无用目录；页内 libmpv 不进 runtime
rm -rf "$DIST/runtime/mpv" "$DIST/runtime/vlc" "$DIST/runtime/libvlc" "$DIST/runtime/lib" "$DIST/runtime/libmpv"

# bridge 始终重新构建，避免发行包混入旧 ABI。
mkdir -p "$RUNTIME_SRC/bridge" "$DIST/runtime/bridge"
echo "[bridge] building..."
(cd "$ROOT" && ./bridge/build.sh)
if [[ ! -f "$ROOT/bridge/spider-bridge.jar" ]]; then
  echo "ERROR: bridge/spider-bridge.jar 不存在，无法打包 JAR 爬虫支持" >&2
  exit 1
fi
cp -f "$ROOT/bridge/spider-bridge.jar" "$RUNTIME_SRC/bridge/"
cp -f "$ROOT/bridge/spider-bridge.jar" "$DIST/runtime/bridge/"

# updater（若已构建）
if [[ -f "$ROOT/cmd/updater/updater" ]]; then
  cp "$ROOT/cmd/updater/updater" "$DIST/"
elif [[ -f "$ROOT/cmd/updater/updater.exe" ]]; then
  cp "$ROOT/cmd/updater/updater.exe" "$DIST/"
fi

echo "verifying runtime..."
"$ROOT/scripts/verify-runtime.sh" "$DIST/runtime" "$PLAT"

# macOS：再打 .app + DMG（系统显示名 KO影视）
if [[ "$PLAT" == macos-* ]]; then
  "$ROOT/scripts/macos-app.sh" "$PLAT" "$DIST"
fi

cat > "$DIST/README.txt" <<EOF
KO影视 / KOTV 发行包 ($PLAT)

目录:
  $BIN              主程序（内嵌 QuickJS，JS 爬虫无需额外运行时）
  runtime/          捆绑运行时
    jre/            Liberica 21（JAR 爬虫，常驻 bridge 进程）
    python/         CPython 3.14（Python 爬虫）
    chromium/       嗅探/解析（Win x64=Win7 REWORK 最新；Win ARM64=最新 snapshot）
    ffmpeg/         FFmpeg（Windows 为 7.0）
    bridge/         spider-bridge.jar

macOS 另产出:
  dist/KO影视.app
  dist/KO影视-$PLAT.dmg

Windows 运行时（Win7 尽力兼容）：
  JRE = 全平台 Liberica 21；Win amd64 另加 api-ms-win-core-path（Win7 SP1+）
  Python = adang1345/PythonVista embed
  嗅探浏览器 = x64: Win7 REWORK → runtime/chromium/chrome.exe；ARM64: CFT headless-shell 或 Win_Arm64 snapshot
  FFmpeg = Gyan 7.0
  页内 MPV = 原生通道（mpv-2.dll / libmpv 与 fvp 同目录，不进 runtime/）
  页内 FVP = Flutter fvp/libmdk（备选）
  外置播放 = 系统打开（不捆绑外部播放器）
  CGO/QuickJS = MinGW MSVCRT win32-seh + 子系统 Win7(6.01) + static-libgcc（posix 则再静态 winpthread）
               CI 用 scripts/check-win7-deps.ps1 拒绝 UCRT / libgcc_s / libwinpthread

启动:
  ./$BIN
  遥控页: http://127.0.0.1:9978/
  Web 包（引擎+webapp 同端口）见 scripts/package-flutter-web.sh / CI「Flutter Web」

默认播放核心为「页内 MPV」（innie#mpv）；桌面可切「页内 FVP」（innie#fvp）。
外置播放走系统关联打开，发行包不捆绑外部播放器。

环境变量(可选):
 KOTV_RUNTIME=/path/to/runtime 覆盖运行时根目录

开发准备运行时:
  ./scripts/prepare-runtime.sh $PLAT
EOF

echo "done: $DIST"
du -sh "$DIST" || true
echo "runtime components:"
ls -1 "$DIST/runtime" 2>/dev/null || true
