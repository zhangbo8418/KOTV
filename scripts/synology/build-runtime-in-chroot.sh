#!/usr/bin/env bash
# 在 Synology DSM 7.2 Toolkit sysroot 下编译 Node / Python / JRE / Chromium(headless)
# 用法: ./scripts/synology/build-runtime-in-chroot.sh <geminilake|rtd1296>
# 产出: dist/syno-runtime-{x86_64|armv8}/
#
# Node/Python/OpenJDK：Toolkit GCC + sysroot
# Chromium：主机 Clang + Toolkit sysroot（现代 Chromium 不支持 GCC）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=common.sh
source "$ROOT/scripts/synology/common.sh"
kotv_syno_load_versions

PLATFORM="${1:?usage: build-runtime-in-chroot.sh <geminilake|rtd1296>}"
read -r ARCH_LABEL _GOARCH TARGET_CPU <<<"$(kotv_syno_plat_meta "$PLATFORM")"
GN_CPU="$TARGET_CPU"

DSM_VER="${SYNO_DSM_VER}"
ENV_DIR="$(kotv_syno_env_dir "$PLATFORM")"
OUT="$ROOT/dist/syno-runtime-${ARCH_LABEL}"
SRC_CACHE="${KOTV_SYNO_SRC_CACHE:-$ROOT/.syno-src-cache}"
BUILD_ROOT="${KOTV_SYNO_BUILD_ROOT:-$ROOT/.syno-build/${PLATFORM}}"
JOBS="${KOTV_SYNO_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

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
echo "==> platform=$PLATFORM arch=$ARCH_LABEL sysroot=$SYSROOT"

download() {
  local url="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  if [[ -f "$dest" && -s "$dest" ]]; then
    echo "  cache hit: $(basename "$dest")"
    return 0
  fi
  echo "  download: $url"
  local i partial="${dest}.partial.$$"
  for i in 1 2 3 4 5; do
    rm -f "$partial"
    if curl -fL --http1.1 --retry 3 --retry-delay 2 --connect-timeout 30 \
      -o "$partial" "$url" && [[ -s "$partial" ]]; then
      mv -f "$partial" "$dest"
      return 0
    fi
    sleep $((i * 2))
  done
  rm -f "$partial"
  echo "ERROR: download failed: $url" >&2
  return 1
}

stamp_ok() {
  # 勿写 local a="$1" b="$OUT/$a"：set -u 下同句展开会 unbound
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

# ---------- Node ----------
build_node() {
  local ver="${SYNO_NODE_VER}"
  local dest="$OUT/node"
  if stamp_ok node "$ver" && [[ -x "$dest/node" ]]; then
    echo "[node] skip (cached $ver)"
    return 0
  fi
  echo "[node] build $ver for $ARCH_LABEL"
  local tarball="$SRC_CACHE/node-${ver}.tar.gz"
  download "https://nodejs.org/dist/${ver}/node-${ver}.tar.gz" "$tarball"
  local src="$BUILD_ROOT/node-${ver}"
  rm -rf "$src"
  mkdir -p "$BUILD_ROOT"
  tar -xzf "$tarball" -C "$BUILD_ROOT"
  cd "$src"
  # Node：强制 Toolkit GCC；armv8 在 x86 runner 上交叉编译
  local cfg=(
    --prefix=/opt/kotv-node
    --without-npm
    --dest-cpu="${TARGET_CPU}"
  )
  if [[ "$PLATFORM" == "rtd1296" ]]; then
    cfg+=(--cross-compiling)
  fi
  CC="$CC" CXX="$CXX" ./configure "${cfg[@]}"
  make -j"$JOBS"
  rm -rf "$dest"
  mkdir -p "$dest"
  # 只取 node 二进制
  cp -a "$src/out/Release/node" "$dest/node" 2>/dev/null || cp -a "$src/out/Release/node" "$dest/node"
  chmod +x "$dest/node"
  if [[ -f "$src/LICENSE" ]]; then cp "$src/LICENSE" "$dest/LICENSE"; fi
  write_stamp node "$ver"
  # 释盘
  rm -rf "$src"
  echo "[node] ready: $dest/node"
}

# ---------- Python ----------
build_python() {
  local ver="${SYNO_PYTHON_VER}"
  local dest="$OUT/python"
  if stamp_ok python "$ver" && [[ -x "$dest/bin/python3" || -x "$dest/bin/python" ]]; then
    echo "[python] skip (cached $ver)"
    return 0
  fi
  echo "[python] build $ver for $ARCH_LABEL"
  local tarball="$SRC_CACHE/Python-${ver}.tgz"
  download "https://www.python.org/ftp/python/${ver}/Python-${ver}.tgz" "$tarball"
  local src="$BUILD_ROOT/Python-${ver}"
  rm -rf "$src"
  tar -xzf "$tarball" -C "$BUILD_ROOT"
  cd "$src"
  local py_cfg=(
    --prefix=/opt/kotv-python
    --enable-shared
    --with-ensurepip=install
    --disable-test-modules
  )
  if [[ "$PLATFORM" == "rtd1296" ]]; then
    # 交叉：不能在 host 跑解释器；ensurepip 延后
    py_cfg=(
      --prefix=/opt/kotv-python
      --enable-shared
      --with-ensurepip=no
      --disable-test-modules
      --host=aarch64-unknown-linux-gnu
      --build=x86_64-pc-linux-gnu
    )
  fi
  CC="$CC" CXX="$CXX" \
    ac_cv_file__dev_ptmx=yes ac_cv_file__dev_ptc=no \
    ./configure "${py_cfg[@]}"
  make -j"$JOBS"
  make DESTDIR="$BUILD_ROOT/python-dest" install
  rm -rf "$dest"
  mkdir -p "$dest"
  cp -a "$BUILD_ROOT/python-dest/opt/kotv-python/." "$dest/"
  # 安装 spider 依赖（若交叉编无法跑 pip，则在可执行时再装；同架构 host 可直接 pip）
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
  if stamp_ok jre "$ver" && [[ -x "$dest/bin/java" && -f "$dest/lib/server/libjvm.so" ]]; then
    echo "[jre] skip (cached $ver)"
    return 0
  fi
  echo "[jre] build OpenJDK ${ver} JRE for $ARCH_LABEL"
  # 使用宿主机 boot JDK + Toolkit 工具链交叉/本地编
  if ! command -v java >/dev/null 2>&1; then
    echo "ERROR: host java (boot JDK) required to build OpenJDK" >&2
    exit 1
  fi
  local tag="jdk-${ver}+35"
  # 固定源码包：Eclipse Temurin / OpenJDK 构建源
  local src_url="https://github.com/openjdk/jdk${ver}u/archive/refs/heads/master.tar.gz"
  # 更可复现：用 jdk21u-dev 某次 snapshot 太飘；改官方 source bundle 若可得
  local tarball="$SRC_CACHE/openjdk-${ver}-src.tar.gz"
  if [[ ! -f "$tarball" ]]; then
    # fallback：clone shallow
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
  else
    local src="$BUILD_ROOT/jdk${ver}-src"
    rm -rf "$src"
    mkdir -p "$src"
    tar -xzf "$tarball" -C "$src" --strip-components=1
  fi
  cd "$src"
  local boot="${JAVA_HOME:-}"
  if [[ -z "$boot" || ! -x "$boot/bin/java" ]]; then
    local javac_bin
    javac_bin="$(command -v javac || command -v java)"
    boot="$(cd "$(dirname "$javac_bin")/.." && pwd)"
  fi
  local jdk_cfg=(
    --with-boot-jdk="$boot"
    --with-jvm-variants=server
    --with-toolchain-type=gcc
    --disable-warnings-as-errors
    --with-native-debug-symbols=none
    --with-debug-level=release
    --with-extra-cflags="$CFLAGS"
    --with-extra-cxxflags="$CXXFLAGS"
    --with-extra-ldflags="$LDFLAGS"
  )
  if [[ "$PLATFORM" == "rtd1296" ]]; then
    jdk_cfg+=(--openjdk-target=aarch64-unknown-linux-gnu)
  fi
  bash configure "${jdk_cfg[@]}" CC="$CC" CXX="$CXX" || {
    echo "ERROR: OpenJDK configure failed" >&2
    exit 1
  }
  make images JOBS="$JOBS" || make product-images JOBS="$JOBS"
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
  mkdir -p "$dest"
  # 若是完整 jdk，用 jlink 缩成 JRE
  if [[ -x "$jre_src/bin/jlink" ]]; then
    "$jre_src/bin/jlink" \
      --add-modules ALL-MODULE-PATH \
      --strip-debug \
      --no-man-pages \
      --no-header-files \
      --compress=2 \
      --output "$dest"
  else
    cp -a "$jre_src/." "$dest/"
  fi
  write_stamp jre "$ver"
  # 释盘：保留 git cache，删 build
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
  # 回落：chromium src 远端主分支 tip
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
  echo "[chromium] build headless_shell $tag for $ARCH_LABEL (Clang + Toolkit sysroot)"

  if ! command -v clang >/dev/null 2>&1; then
    echo "[chromium] installing clang on host..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq clang lld ninja-build pkg-config
  fi
  command -v ninja >/dev/null 2>&1 || sudo apt-get install -y -qq ninja-build

  local depot="$SRC_CACHE/depot_tools"
  if [[ ! -d "$depot/.git" ]]; then
    git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$depot"
  fi
  export PATH="$depot:$PATH"

  local chrome_src="$BUILD_ROOT/chromium/src"
  mkdir -p "$BUILD_ROOT/chromium"
  cd "$BUILD_ROOT/chromium"
  if [[ ! -f "$chrome_src/.gclient" && ! -d "$chrome_src" ]]; then
    echo "[chromium] fetch (this is large; disk must suffice)"
    # 用精简 fetch：只要 headless 相关
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
    # 首次：gclient sync 可能极慢；允许 KOTV_SYNO_CHROMIUM_TARBALL 指向预打包 src
    if [[ -n "${KOTV_SYNO_CHROMIUM_TARBALL:-}" && -f "${KOTV_SYNO_CHROMIUM_TARBALL}" ]]; then
      echo "[chromium] extract KOTV_SYNO_CHROMIUM_TARBALL"
      mkdir -p src
      tar -xf "$KOTV_SYNO_CHROMIUM_TARBALL" -C src --strip-components=1
    else
      fetch --nohooks --no-history chromium || {
        # fetch 失败时尝试手动 clone：版本 tag 或 commit
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
      (cd src && gclient sync --nohooks --no-history -D -j"$JOBS" || true)
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
    (cd "$chrome_src" && gclient sync --nohooks --no-history -D -j"$JOBS" || true)
  fi

  cd "$chrome_src"
  # 释盘：去掉不必要的大目录
  rm -rf third_party/llvm-build 2>/dev/null || true

  local out_dir="out/HeadlessSyno"
  local args=(
    "is_debug=false"
    "is_component_build=false"
    "is_official_build=true"
    "symbol_level=0"
    "blink_symbol_level=0"
    "chrome_pgo_phase=0"
    "enable_nacl=false"
    "enable_remoting=false"
    "enable_media_remoting=false"
    "enable_print_preview=false"
    "rtc_include_tests=false"
    "v8_enable_i18n_support=false"
    'target_os="linux"'
    "target_cpu=\"${GN_CPU}\""
    "use_sysroot=true"
    "target_sysroot=\"${SYSROOT}\""
    "use_custom_libcxx=true"
    "is_clang=true"
  )
  # 生成
  if [[ ! -f tools/gn/bin/gn ]] && ! command -v gn >/dev/null 2>&1; then
    # chromium 自带 gn
    if [[ -x "$depot/gn" ]]; then
      :
    fi
  fi
  gn gen "$out_dir" --args="${args[*]}"
  ninja -C "$out_dir" headless_shell chrome-headless-shell || ninja -C "$out_dir" headless_shell

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
  # 同名入口，兼容探测
  ln -sfn chrome-headless-shell "$dest/chrome"
  # 拷必要 .so / pak（同目录）
  find "$(dirname "$bin")" -maxdepth 1 -type f \( -name '*.pak' -o -name '*.bin' -o -name '*.dat' -o -name '*.so' -o -name 'icudtl.dat' -o -name 'v8_context_snapshot.bin' -o -name 'lib*.so*' \) \
    -exec cp -a {} "$dest/" \; 2>/dev/null || true
  write_stamp chromium "$tag"

  # 释盘：删 out 中间物，保留 src 供 cache
  rm -rf "$out_dir"
  echo "[chromium] ready: $dest/chrome-headless-shell"
}

# ---------- ffmpeg（可选，便于嗅探/转码旁路） ----------
build_ffmpeg() {
  local ver="6.1.1"
  local dest="$OUT/ffmpeg"
  if stamp_ok ffmpeg "$ver" && [[ -x "$dest/ffmpeg" ]]; then
    echo "[ffmpeg] skip (cached $ver)"
    return 0
  fi
  echo "[ffmpeg] build $ver"
  local tarball="$SRC_CACHE/ffmpeg-${ver}.tar.xz"
  download "https://ffmpeg.org/releases/ffmpeg-${ver}.tar.xz" "$tarball"
  local src="$BUILD_ROOT/ffmpeg-${ver}"
  rm -rf "$src"
  tar -xJf "$tarball" -C "$BUILD_ROOT"
  cd "$src"
  ./configure \
    --prefix=/opt/kotv-ffmpeg \
    --enable-gpl \
    --enable-shared \
    --disable-doc \
    --disable-debug \
    --cc="$CC" \
    --cxx="$CXX" \
    --extra-cflags="$CFLAGS" \
    --extra-ldflags="$LDFLAGS"
  make -j"$JOBS"
  make DESTDIR="$BUILD_ROOT/ffmpeg-dest" install
  rm -rf "$dest"
  mkdir -p "$dest"
  cp -a "$BUILD_ROOT/ffmpeg-dest/opt/kotv-ffmpeg/bin/ffmpeg" "$dest/ffmpeg"
  chmod +x "$dest/ffmpeg"
  # 共享库
  mkdir -p "$dest/lib"
  cp -a "$BUILD_ROOT/ffmpeg-dest/opt/kotv-ffmpeg/lib/"*.so* "$dest/lib/" 2>/dev/null || true
  write_stamp ffmpeg "$ver"
  rm -rf "$src" "$BUILD_ROOT/ffmpeg-dest"
  echo "[ffmpeg] ready: $dest/ffmpeg"
}

echo "======== syno runtime build: $PLATFORM → $OUT ========"
COMPONENTS="${KOTV_SYNO_COMPONENTS:-node python jre chromium ffmpeg}"
for c in $COMPONENTS; do
  case "$c" in
    node) build_node ;;
    python) build_python ;;
    jre) build_jre ;;
    chromium) build_chromium ;;
    ffmpeg) build_ffmpeg ;;
    *) echo "unknown component: $c" >&2; exit 1 ;;
  esac
done

cat >"$OUT/.kotv-runtime" <<EOF
platform=synology-${ARCH_LABEL}
toolkit_platform=${PLATFORM}
dsm=${DSM_VER}
prepared=$(date -u +%Y-%m-%dT%H:%M:%SZ)
sysroot=${SYSROOT}
cc=${CC}
EOF

echo "======== done: $OUT ========"
du -sh "$OUT"/* 2>/dev/null || ls -la "$OUT"
