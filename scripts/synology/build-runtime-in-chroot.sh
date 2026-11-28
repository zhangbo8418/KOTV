#!/usr/bin/env bash
# 在 Synology DSM 7.2 Toolkit 下编译 Node / Python / JRE / Chromium / ffmpeg
# 用法: ./scripts/synology/build-runtime-in-chroot.sh <geminilake|rtd1296>
# 产出: dist/syno-runtime-{x86_64|armv8}/
#
# Node/Python/JRE/ffmpeg：Toolkit GCC + .syno-deps overlay（禁止宿主 /usr）
# Chromium：Clang 仅作编译器；目标 ABI = Toolkit sysroot（缺库/crt/头文件用工具链补）+ headless.gn
# CI：KOTV_SYNO_COMPONENTS=<一个组件>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=common.sh
source "$ROOT/scripts/synology/common.sh"
kotv_syno_load_versions

PLATFORM="${1:?usage: build-runtime-in-chroot.sh <geminilake|rtd1296>}"
read -r ARCH_LABEL _GOARCH TARGET_CPU <<<"$(kotv_syno_plat_meta "$PLATFORM")"
GN_CPU="$TARGET_CPU"
CROSS=0
if kotv_syno_is_cross "$PLATFORM"; then CROSS=1; fi

DSM_VER="${SYNO_DSM_VER}"
ENV_DIR="$(kotv_syno_env_dir "$PLATFORM")"
OUT="$ROOT/dist/syno-runtime-${ARCH_LABEL}"
SRC_CACHE="${KOTV_SYNO_SRC_CACHE:-$ROOT/.syno-src-cache}"
BUILD_ROOT="${KOTV_SYNO_BUILD_ROOT:-$ROOT/.syno-build/${PLATFORM}}"
JOBS_TOTAL="$(kotv_syno_njobs)"

mkdir -p "$OUT" "$SRC_CACHE" "$BUILD_ROOT"
chmod +x "$ROOT/scripts/synology/"*.sh

if [[ ! -d "$ENV_DIR" ]]; then
  echo "==> toolkit missing; deploying..."
  "$ROOT/scripts/synology/deploy-toolkit.sh" "$PLATFORM"
fi
if [[ ! -d "$ENV_DIR" ]]; then
  echo "ERROR: toolkit env not found: $ENV_DIR" >&2
  exit 1
fi

kotv_syno_export_toolchain "$ENV_DIR"
echo "==> platform=$PLATFORM arch=$ARCH_LABEL cross=$CROSS sysroot=$SYSROOT"

download() {
  # 日志一律 stderr：kotv_syno_dep_fetch 等会用 $(download/…) 吃 stdout
  local url="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  if [[ -f "$dest" && -s "$dest" ]]; then
    if [[ "$dest" == *.gz || "$dest" == *.tgz ]] && ! gzip -t "$dest" 2>/dev/null; then
      echo "  corrupt cache, re-download: $(basename "$dest")" >&2
      rm -f "$dest"
    else
      echo "  cache hit: $(basename "$dest")" >&2
      return 0
    fi
  fi
  echo "  download: $url" >&2
  local i partial="${dest}.partial.$$"
  for i in 1 2 3 4 5; do
    rm -f "$partial"
    if curl -fsSL --http1.1 --retry 3 --retry-delay 2 --connect-timeout 30 \
      -o "$partial" "$url" && [[ -s "$partial" ]]; then
      if [[ "$dest" == *.gz || "$dest" == *.tgz ]] && ! gzip -t "$partial" 2>/dev/null; then
        rm -f "$partial"
        sleep $((i * 2))
        continue
      fi
      mv -f "$partial" "$dest"
      return 0
    fi
    sleep $((i * 2))
  done
  rm -f "$partial"
  echo "ERROR: download failed: $url" >&2
  return 1
}

# shellcheck source=toolkit-deps.sh
source "$ROOT/scripts/synology/toolkit-deps.sh"

stamp_ok() {
  local name ver marker
  name="$1"
  ver="$2"
  marker="$OUT/.kotv-syno-${name}"
  [[ -f "$marker" && "$(cat "$marker" 2>/dev/null || true)" == "$ver" ]]
}

write_stamp() {
  local name ver
  name="$1"
  ver="$2"
  echo "$ver" >"$OUT/.kotv-syno-${name}"
}

comp_jobs() {
  echo "$JOBS_TOTAL"
}

# 交叉编 Python 时宿主解释器 major.minor 必须与目标一致
host_python_matching() {
  local want_mm="$1" p got
  for p in "python${want_mm}" python3; do
    if command -v "$p" >/dev/null 2>&1; then
      got="$("$p" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)"
      if [[ "$got" == "$want_mm" ]]; then
        command -v "$p"
        return 0
      fi
    fi
  done
  echo "ERROR: need host Python ${want_mm} for cross-compile (found none)" >&2
  return 1
}

# ---------- Node ----------
build_node() {
  local ver="${SYNO_NODE_VER}"
  local dest="$OUT/node"
  local jobs
  jobs="$(comp_jobs)"
  if stamp_ok node "$ver" && [[ -x "$dest/node" ]]; then
    echo "[node] skip (cached $ver)"
    return 0
  fi
  echo "[node] build $ver for $ARCH_LABEL (-j$jobs)"
  kotv_syno_ensure_deps node
  local deps
  deps="$(kotv_syno_deps_prefix)"
  kotv_syno_export_deps_env
  local tarball="$SRC_CACHE/node-${ver}.tar.gz"
  download "https://nodejs.org/dist/${ver}/node-${ver}.tar.gz" "$tarball"
  local src="$BUILD_ROOT/node-${ver}"
  rm -rf "$src"
  mkdir -p "$BUILD_ROOT"
  tar -xzf "$tarball" -C "$BUILD_ROOT"
  cd "$src"
  # brotli 始终树内。交叉时 --shared-* 会进 host 链接行（aarch64 .so → host ld 失败），
  # 故交叉用树内 openssl/zlib/cares/nghttp2（仍是 Toolkit GCC+sysroot 编）；原生用 overlay shared。
  local cfg=(
    --prefix=/opt/kotv-node
    --without-npm
    --dest-cpu="${TARGET_CPU}"
    --with-intl=full-icu
  )
  local host_cc host_cxx target_ldflags target_cppflags
  host_cc="${CC_host:-gcc}"
  host_cxx="${CXX_host:-g++}"
  target_ldflags="${LDFLAGS:-}"
  target_cppflags="${CPPFLAGS:-}"
  local host_cflags="-O2 -pipe" host_ldflags="-Wl,-O1"
  if [[ "$CROSS" -eq 1 ]]; then
    cfg+=(--cross-compiling)
    if ! command -v "$host_cc" >/dev/null 2>&1; then
      echo "ERROR: host C compiler required for Node cross-build: $host_cc" >&2
      exit 1
    fi
    echo "[node] cross-compile: CC=$CC CC_host=$host_cc dest-cpu=${TARGET_CPU} (bundled deps; no --shared-*)"
  else
    cfg+=(
      --shared-openssl
      --shared-openssl-includes="$deps/include"
      --shared-openssl-libpath="$deps/lib"
      --shared-zlib
      --shared-zlib-includes="$deps/include"
      --shared-zlib-libpath="$deps/lib"
      --shared-cares
      --shared-cares-includes="$deps/include"
      --shared-cares-libpath="$deps/lib"
      --shared-nghttp2
      --shared-nghttp2-includes="$deps/include"
      --shared-nghttp2-libpath="$deps/lib"
    )
  fi
  # 交叉：清空环境里的目标 LDFLAGS/CPPFLAGS，避免 host 工具吃到 -L.syno-deps
  if [[ "$CROSS" -eq 1 ]]; then
    env -u LIBRARY_PATH \
      CC="$CC" CXX="$CXX" CC_host="$host_cc" CXX_host="$host_cxx" \
      AR_host="${AR_host:-ar}" \
      CFLAGS_host="$host_cflags" CXXFLAGS_host="$host_cflags" \
      LDFLAGS_host="$host_ldflags" \
      PKG_CONFIG_SYSROOT_DIR="" \
      CPPFLAGS="$target_cppflags" LDFLAGS="$target_ldflags" \
      ./configure "${cfg[@]}"
    env -u LIBRARY_PATH \
      make -j"$jobs" \
      CFLAGS_host="$host_cflags" CXXFLAGS_host="$host_cflags" \
      LDFLAGS_host="$host_ldflags"
  else
    CC="$CC" CXX="$CXX" \
      PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-}" \
      PKG_CONFIG_LIBDIR="${PKG_CONFIG_LIBDIR:-}" \
      PKG_CONFIG_SYSROOT_DIR="" \
      CPPFLAGS="$target_cppflags" LDFLAGS="$target_ldflags" \
      ./configure "${cfg[@]}"
    make -j"$jobs"
  fi
  rm -rf "$dest"
  mkdir -p "$dest/lib"
  cp -a "$src/out/Release/node" "$dest/node"
  chmod +x "$dest/node"
  if [[ "$CROSS" -eq 0 ]]; then
    kotv_syno_deps_ship_shared "$dest/lib" ssl crypto z cares nghttp2
  fi
  if [[ -f "$src/LICENSE" ]]; then cp "$src/LICENSE" "$dest/LICENSE"; fi
  write_stamp node "$ver"
  rm -rf "$src"
  echo "[node] ready: $dest/node"
}

# ---------- Python ----------
build_python() {
  local ver="${SYNO_PYTHON_VER}"
  local dest="$OUT/python"
  local jobs ensurepip=install build_py=""
  jobs="$(comp_jobs)"
  if stamp_ok python "$ver" && [[ -x "$dest/bin/python3" || -x "$dest/bin/python" ]]; then
    echo "[python] skip (cached $ver)"
    return 0
  fi
  echo "[python] build $ver for $ARCH_LABEL (-j$jobs)"
  kotv_syno_ensure_deps python
  local deps; deps="$(kotv_syno_deps_prefix)"
  kotv_syno_export_deps_env

  local tarball="$SRC_CACHE/Python-${ver}.tgz"
  download "https://www.python.org/ftp/python/${ver}/Python-${ver}.tgz" "$tarball"
  local src="$BUILD_ROOT/Python-${ver}"
  rm -rf "$src"
  tar -xzf "$tarball" -C "$BUILD_ROOT"
  cd "$src"

  local py_cfg=(
    --prefix=/opt/kotv-python
    --enable-shared
    --disable-test-modules
    --with-system-ffi
    --with-openssl="$deps"
  )
  if [[ "$CROSS" -eq 1 ]]; then
    ensurepip=no
    build_py="$(host_python_matching "${ver%.*}")"
    py_cfg+=(
      --host=aarch64-unknown-linux-gnu
      --build=x86_64-pc-linux-gnu
      --with-build-python="$build_py"
    )
    echo "[python] cross-compile --with-build-python=$build_py"
  fi
  py_cfg+=(--with-ensurepip="$ensurepip")

  # 交叉：跳过 getaddrinfo；用 export（数组展开加引号不会被当成 VAR=value）
  export ac_cv_file__dev_ptmx=yes
  export ac_cv_file__dev_ptc=no
  if [[ "$CROSS" -eq 1 ]]; then
    export ac_cv_func_getaddrinfo=yes
    export ac_cv_buggy_getaddrinfo=no
  fi
  CC="$CC" CXX="$CXX" ./configure "${py_cfg[@]}"
  make -j"$jobs"
  make DESTDIR="$BUILD_ROOT/python-dest" install
  rm -rf "$dest"
  mkdir -p "$dest"
  cp -a "$BUILD_ROOT/python-dest/opt/kotv-python/." "$dest/"
  mkdir -p "$dest/lib"
  # 静态库不会被拷；openssl/zlib/sqlite/ncurses 等 shared 才进包
  kotv_syno_deps_ship_shared "$dest/lib" ssl crypto z bz2 sqlite3 ncursesw
  if [[ -x "$dest/bin/python3" ]]; then
    if "$dest/bin/python3" -c 'import sys; print(sys.version)' >/dev/null 2>&1; then
      "$dest/bin/python3" -m pip install --upgrade pip wheel || true
      "$dest/bin/python3" -m pip install -r "$ROOT/scripts/python-requirements.txt" || true
    else
      echo "[python] built binary not runnable on host (cross); ship stdlib only"
    fi
  fi
  write_stamp python "$ver"
  rm -rf "$src" "$BUILD_ROOT/python-dest"
  echo "[python] ready: $dest"
}

# ---------- OpenJDK JRE ----------
build_jre() {
  local ver="${SYNO_JDK_FEATURE}"
  local dest="$OUT/jre"
  local jobs
  jobs="$(comp_jobs)"
  if stamp_ok jre "$ver" && [[ -x "$dest/bin/java" && -f "$dest/lib/server/libjvm.so" ]]; then
    echo "[jre] skip (cached $ver)"
    return 0
  fi
  echo "[jre] build OpenJDK ${ver} JRE for $ARCH_LABEL (-j$jobs)"
  if ! command -v java >/dev/null 2>&1; then
    echo "ERROR: host java (boot JDK) required to build OpenJDK" >&2
    exit 1
  fi
  kotv_syno_ensure_deps jre
  local deps x11
  deps="$(kotv_syno_deps_prefix)"
  kotv_syno_export_deps_env
  x11="${KOTV_SYNO_X11_PREFIX:-$deps}"

  local gitdir="$SRC_CACHE/jdk${ver}u"
  if [[ ! -d "$gitdir/.git" ]]; then
    git clone --depth 1 --branch "jdk${ver}u" \
      "https://github.com/openjdk/jdk${ver}u.git" "$gitdir" \
      || git clone --depth 1 "https://github.com/openjdk/jdk${ver}u.git" "$gitdir"
  fi
  local src="$BUILD_ROOT/jdk${ver}u"
  rm -rf "$src"
  mkdir -p "$BUILD_ROOT"
  cp -a "$gitdir" "$src"
  cd "$src"
  local boot="${JAVA_HOME:-}"
  if [[ -z "$boot" || ! -x "$boot/bin/java" ]]; then
    local javac_bin
    javac_bin="$(command -v javac || command -v java)"
    boot="$(cd "$(dirname "$javac_bin")/.." && pwd)"
  fi
  # building.md：alsa/cups/fontconfig/X11 不可 --without-*；图像库 bundled。
  local jdk_cfg=(
    --with-boot-jdk="$boot"
    --with-sysroot="$SYSROOT"
    --with-jvm-variants=server
    --with-toolchain-type=gcc
    --disable-warnings-as-errors
    --with-native-debug-symbols=none
    --with-debug-level=release
    --enable-headless-only
    --with-alsa="$deps"
    --with-cups="$deps"
    --with-fontconfig="$deps"
    --with-x="$x11"
    --with-freetype=bundled
    --with-libjpeg=bundled
    --with-giflib=bundled
    --with-libpng=bundled
    --with-extra-cflags="$CFLAGS -I${deps}/include"
    --with-extra-cxxflags="$CXXFLAGS -I${deps}/include"
    --with-extra-ldflags="$LDFLAGS -L${deps}/lib -L${deps}/lib64"
  )
  if [[ "$CROSS" -eq 1 ]]; then
    jdk_cfg+=(--openjdk-target=aarch64-unknown-linux-gnu)
  fi
  bash configure "${jdk_cfg[@]}" CC="$CC" CXX="$CXX" || {
    echo "ERROR: OpenJDK configure failed" >&2
    exit 1
  }
  make images JOBS="$jobs" || make product-images JOBS="$jobs"
  local jre_src
  jre_src="$(find "$src/build" -type d -path '*/images/jdk' | head -1 || true)"
  if [[ -z "$jre_src" ]]; then
    jre_src="$(find "$src/build" -type d -path '*/images/jre' | head -1 || true)"
  fi
  if [[ -z "$jre_src" ]]; then
    echo "ERROR: OpenJDK images not found" >&2
    find "$src/build" -maxdepth 4 -type d 2>/dev/null | head -50 || true
    exit 1
  fi
  rm -rf "$dest"
  # 交叉：目标 jlink 是 aarch64，宿主不能执行 → 直接拷 images/jdk
  # 原生：jlink 要求 --output 目录尚不存在（勿先 mkdir）
  if [[ "$CROSS" -eq 0 && -x "$jre_src/bin/jlink" ]]; then
    "$jre_src/bin/jlink" \
      --add-modules ALL-MODULE-PATH \
      --strip-debug \
      --no-man-pages \
      --no-header-files \
      --compress=2 \
      --output "$dest"
  else
    mkdir -p "$dest"
    cp -a "$jre_src/." "$dest/"
    if [[ "$CROSS" -eq 1 ]]; then
      echo "[jre] cross: shipped images/jdk (host cannot run target jlink)"
    fi
  fi
  kotv_syno_deps_ship_shared "$dest/lib" asound
  write_stamp jre "$ver"
  rm -rf "$src"
  echo "[jre] ready: $dest"
}

# 解析最新 Chromium 修订：CFT Stable 版本号 → 对应 git tag；失败则用 src.git HEAD。
resolve_latest_chromium_ref() {
  local meta="$SRC_CACHE/chrome-for-testing-latest.json"
  local ver=""
  mkdir -p "$SRC_CACHE"
  if curl -fsSL --http1.1 --connect-timeout 30 \
    "https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json" \
    -o "$meta"; then
    ver="$(python3 - "$meta" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get("channels", {}).get("Stable", {}).get("version", "") or "")
PY
)"
  fi
  if [[ -n "$ver" ]]; then
    echo "$ver"
    return 0
  fi
  ver="$(git ls-remote --heads https://chromium.googlesource.com/chromium/src.git main \
    | awk '{print $1; exit}')"
  if [[ -n "$ver" ]]; then
    echo "$ver"
    return 0
  fi
  echo "ERROR: cannot resolve latest Chromium version" >&2
  return 1
}

# ---------- Chromium headless_shell ----------
build_chromium() {
  local tag="${SYNO_CHROMIUM_TAG:-latest}"
  local commit="${SYNO_CHROMIUM_COMMIT:-}"
  local dest="$OUT/chromium"
  local jobs
  jobs="$(comp_jobs)"

  if [[ -n "$commit" ]]; then
    tag="$commit"
  elif [[ "$tag" == "latest" || -z "$tag" ]]; then
    tag="$(resolve_latest_chromium_ref)"
    echo "[chromium] resolved latest → $tag"
  fi

  if stamp_ok chromium "$tag" && [[ -x "$dest/chrome-headless-shell" || -x "$dest/chrome" ]]; then
    echo "[chromium] skip (cached $tag)"
    return 0
  fi
  echo "[chromium] build headless_shell $tag for $ARCH_LABEL (Clang + Toolkit sysroot ABI, -j$jobs)"

  if ! command -v clang >/dev/null 2>&1; then
    echo "[chromium] installing clang on host (compiler only)..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq clang lld ninja-build pkg-config
  fi
  command -v ninja >/dev/null 2>&1 || sudo apt-get install -y -qq ninja-build

  # configure 前：Toolkit sysroot + 清单补齐（GCC crt/libgcc、dri.pc、compat.h）并验收
  kotv_syno_ensure_deps chromium
  local chrome_sysroot gcc_libdir compat_h
  chrome_sysroot="$(kotv_syno_chromium_sysroot)"
  gcc_libdir="${KOTV_SYNO_CHROMIUM_GCC_LIBDIR:-}"
  compat_h="${KOTV_SYNO_CHROMIUM_COMPAT_H:-}"
  if [[ -z "$gcc_libdir" && -f "$chrome_sysroot/.kotv-gcc-libdir" ]]; then
    gcc_libdir="$(cat "$chrome_sysroot/.kotv-gcc-libdir")"
  fi
  if [[ -z "$compat_h" && -f "$chrome_sysroot/.kotv-chromium-compat-h" ]]; then
    compat_h="$(cat "$chrome_sysroot/.kotv-chromium-compat-h")"
  fi
  [[ -n "$compat_h" ]] || compat_h="$chrome_sysroot/usr/include/kotv-chromium-compat.h"
  kotv_syno_chromium_verify_sysroot "$chrome_sysroot" || exit 1

  local depot="$SRC_CACHE/depot_tools"
  if [[ ! -d "$depot/.git" ]]; then
    git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$depot"
  fi
  export PATH="$depot:$PATH"

  local chrome_src="$BUILD_ROOT/chromium/src"
  mkdir -p "$BUILD_ROOT/chromium"
  cd "$BUILD_ROOT/chromium"
  if [[ ! -f "$chrome_src/.gclient" && ! -d "$chrome_src" ]]; then
    echo "[chromium] fetch (large; disk must suffice)"
    cat > .gclient <<EOF
solutions = [
  {
    "name": "src",
    "url": "https://chromium.googlesource.com/chromium/src.git@${tag}",
    "managed": False,
    "custom_deps": {},
    "custom_vars": {},
  },
]
EOF
    if [[ -n "${KOTV_SYNO_CHROMIUM_TARBALL:-}" && -f "${KOTV_SYNO_CHROMIUM_TARBALL}" ]]; then
      echo "[chromium] extract KOTV_SYNO_CHROMIUM_TARBALL"
      mkdir -p src
      tar -xf "$KOTV_SYNO_CHROMIUM_TARBALL" -C src --strip-components=1
    else
      fetch --nohooks --no-history chromium || {
        if [[ "$tag" =~ ^[0-9a-f]{40}$ ]]; then
          git clone --depth 1 https://chromium.googlesource.com/chromium/src.git src
          git -C src fetch --depth 1 origin "$tag" && git -C src checkout "$tag"
        else
          git clone --depth 1 --branch "$tag" \
            https://chromium.googlesource.com/chromium/src.git src \
            || {
              git clone --depth 1 https://chromium.googlesource.com/chromium/src.git src
              git -C src fetch --tags --depth 1 origin "refs/tags/${tag}:refs/tags/${tag}" 2>/dev/null || true
              git -C src checkout "$tag" 2>/dev/null || true
            }
        fi
      }
      (cd src && gclient sync --nohooks --no-history -D -j"$jobs" || true)
      (cd src && gclient runhooks || true)
    fi
  elif [[ -d "$chrome_src/.git" ]]; then
    echo "[chromium] existing src → checkout $tag"
    git -C "$chrome_src" fetch --depth 1 origin "$tag" 2>/dev/null \
      || git -C "$chrome_src" fetch --tags --depth 1 origin "refs/tags/${tag}:refs/tags/${tag}" 2>/dev/null \
      || true
    git -C "$chrome_src" checkout "$tag" 2>/dev/null \
      || git -C "$chrome_src" checkout FETCH_HEAD 2>/dev/null \
      || true
    (cd "$chrome_src" && gclient sync --nohooks --no-history -D -j"$jobs" || true)
    (cd "$chrome_src" && gclient runhooks || true)
  fi

  cd "$chrome_src"

  if [[ ! -f build/args/headless.gn ]]; then
    echo "ERROR: missing build/args/headless.gn in Chromium tree" >&2
    exit 1
  fi
  local clang_base="/usr"
  if [[ -x third_party/llvm-build/Release+Asserts/bin/clang ]]; then
    clang_base="$(cd third_party/llvm-build/Release+Asserts && pwd)"
    echo "[chromium] bundled clang → $clang_base"
  fi
  local out_dir="out/HeadlessSyno"
  mkdir -p "$out_dir"
  # target_sysroot = Toolkit 副本；-B/-L 找 crt/libgcc；-include compat 补 HWCAP2/PR_MTE
  local extra_ld="-L${chrome_sysroot}/usr/lib -L${chrome_sysroot}/lib"
  if [[ -n "$gcc_libdir" ]]; then
    extra_ld+=" -B${gcc_libdir} -L${gcc_libdir}"
  fi
  local extra_c="-include ${compat_h}"
  cat >"$out_dir/args.gn" <<EOF
import("//build/args/headless.gn")
is_debug = false
is_component_build = false
is_official_build = true
symbol_level = 0
blink_symbol_level = 0
chrome_pgo_phase = 0
enable_nacl = false
enable_remoting = false
rtc_include_tests = false
v8_enable_i18n_support = false
target_os = "linux"
target_cpu = "${GN_CPU}"
use_sysroot = true
target_sysroot = "${chrome_sysroot}"
use_custom_libcxx = true
is_clang = true
clang_base_path = "${clang_base}"
clang_use_chrome_plugins = false
# headless 不碰系统输入/GBM；libdrm 走 third_party；vaapi 因无 x11/wayland 本为 false
use_xkbcommon = false
use_system_minigbm = false
ozone_platform_x11 = false
ozone_platform_wayland = false
ozone_platform_drm = false
extra_cflags = "${extra_c}"
extra_cxxflags = "${extra_c}"
extra_ldflags = "${extra_ld}"
EOF
  gn gen "$out_dir"
  # 只编 headless_shell（chrome-headless-shell 不是稳定 ninja 目标名）
  ninja -C "$out_dir" -j"$jobs" headless_shell

  rm -rf "$dest"
  mkdir -p "$dest"
  local bin
  bin="$(find "$out_dir" -maxdepth 2 -type f \( -name 'chrome-headless-shell' -o -name 'headless_shell' \) | head -1 || true)"
  if [[ -z "$bin" ]]; then
    echo "ERROR: headless_shell binary not found in $out_dir" >&2
    ls -la "$out_dir" | head -40 || true
    exit 1
  fi
  cp -a "$bin" "$dest/chrome-headless-shell"
  chmod +x "$dest/chrome-headless-shell"
  ln -sfn chrome-headless-shell "$dest/chrome"
  find "$(dirname "$bin")" -maxdepth 1 -type f \( -name '*.pak' -o -name '*.bin' -o -name '*.dat' -o -name '*.so' -o -name 'icudtl.dat' -o -name 'v8_context_snapshot.bin' -o -name 'lib*.so*' \) \
    -exec cp -a {} "$dest/" \; 2>/dev/null || true
  write_stamp chromium "$tag"
  rm -rf "$out_dir"
  echo "[chromium] ready: $dest/chrome-headless-shell"
}

# ---------- ffmpeg ----------
build_ffmpeg() {
  local ver="${SYNO_FFMPEG_VER}"
  local dest="$OUT/ffmpeg"
  local jobs
  jobs="$(comp_jobs)"
  if stamp_ok ffmpeg "$ver" && [[ -x "$dest/ffmpeg" ]]; then
    echo "[ffmpeg] skip (cached $ver)"
    return 0
  fi
  echo "[ffmpeg] build $ver for $ARCH_LABEL (-j$jobs)"
  kotv_syno_ensure_deps ffmpeg
  kotv_syno_export_deps_env
  local deps
  deps="$(kotv_syno_deps_prefix)"
  local tarball="$SRC_CACHE/ffmpeg-${ver}.tar.xz"
  download "https://ffmpeg.org/releases/ffmpeg-${ver}.tar.xz" "$tarball"
  local src="$BUILD_ROOT/ffmpeg-${ver}"
  rm -rf "$src"
  tar -xJf "$tarball" -C "$BUILD_ROOT"
  cd "$src"
  # OpenSSL ≥3 + GPL 需要 --enable-version3；严禁扫到 Toolkit sysroot 的 OpenSSL 1.1
  # 勿 --pkg-config-flags=--static；PKG_CONFIG_* 只看见 deps
  export PKG_CONFIG_SYSROOT_DIR=""
  export PKG_CONFIG_LIBDIR="${deps}/lib/pkgconfig:${deps}/lib64/pkgconfig"
  export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
  export OPENSSL_CFLAGS="-I${deps}/include"
  export OPENSSL_LIBS="-L${deps}/lib -lssl -lcrypto"
  # 探针：编译单元必须看到 OPENSSL_VERSION_MAJOR>=3
  if ! printf '%s\n' '#include <openssl/opensslv.h>' 'int x[OPENSSL_VERSION_MAJOR >= 3 ? 1 : -1];' \
    | $CC -I"${deps}/include" -c -x c - -o /tmp/kotv-ossl-probe.o 2>/dev/null; then
    echo "ERROR: deps OpenSSL headers are not ≥3.0 under -I${deps}/include" >&2
    ls -la "${deps}/include/openssl" 2>/dev/null | head || true
    exit 1
  fi
  rm -f /tmp/kotv-ossl-probe.o
  # CFLAGS 去掉可能带进的旧 -I；只保留 sysroot + deps
  local ff_cflags="--sysroot=${SYSROOT} -O2 -pipe -I${deps}/include"
  local ff_cfg=(
    --prefix=/opt/kotv-ffmpeg
    --enable-gpl
    --enable-version3
    --enable-shared
    --enable-openssl
    --disable-doc
    --disable-debug
    --cc="$CC"
    --cxx="$CXX"
    --extra-cflags="$ff_cflags"
    --extra-ldflags="-L${deps}/lib -L${deps}/lib64 --sysroot=${SYSROOT} -Wl,-O1"
  )
  # Toolkit 交叉/CI 环境常无 nasm；禁用 x86asm 仍可出 ffmpeg 二进制
  if ! command -v nasm >/dev/null 2>&1 && ! command -v yasm >/dev/null 2>&1; then
    ff_cfg+=(--disable-x86asm)
  fi
  if [[ "$CROSS" -eq 1 ]]; then
    ff_cfg+=(
      --enable-cross-compile
      --arch=aarch64
      --target-os=linux
      --cross-prefix="$(dirname "$CC")/$(basename "$CC" | sed 's/gcc$//')"
    )
  fi
  ./configure "${ff_cfg[@]}"
  make -j"$jobs"
  make DESTDIR="$BUILD_ROOT/ffmpeg-dest" install
  rm -rf "$dest"
  mkdir -p "$dest"
  cp -a "$BUILD_ROOT/ffmpeg-dest/opt/kotv-ffmpeg/bin/ffmpeg" "$dest/ffmpeg"
  chmod +x "$dest/ffmpeg"
  mkdir -p "$dest/lib"
  cp -a "$BUILD_ROOT/ffmpeg-dest/opt/kotv-ffmpeg/lib/"*.so* "$dest/lib/" 2>/dev/null || true
  kotv_syno_deps_ship_shared "$dest/lib" ssl crypto z
  write_stamp ffmpeg "$ver"
  rm -rf "$src" "$BUILD_ROOT/ffmpeg-dest"
  echo "[ffmpeg] ready: $dest/ffmpeg"
}

run_component() {
  case "$1" in
    node) build_node ;;
    python) build_python ;;
    jre) build_jre ;;
    chromium) build_chromium ;;
    ffmpeg) build_ffmpeg ;;
    *) echo "unknown component: $1" >&2; return 1 ;;
  esac
}

echo "======== syno runtime build: $PLATFORM → $OUT ========"
COMPONENTS="${KOTV_SYNO_COMPONENTS:-$(kotv_syno_runtime_components)}"
echo "==> components: ${COMPONENTS} (-j${JOBS_TOTAL})"
# shellcheck disable=SC2086
for c in $COMPONENTS; do
  run_component "$c"
done

cat >"$OUT/.kotv-runtime" <<EOF
platform=synology-${ARCH_LABEL}
toolkit_platform=${PLATFORM}
dsm=${DSM_VER}
prepared=$(date -u +%Y-%m-%dT%H:%M:%SZ)
sysroot=${SYSROOT}
cc=${CC}
components=${COMPONENTS}
EOF

echo "======== done: $OUT ========"
du -sh "$OUT"/* 2>/dev/null || ls -la "$OUT"
