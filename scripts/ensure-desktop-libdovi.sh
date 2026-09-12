#!/usr/bin/env bash
# 桌面 libdovi（quietvoid/dovi_tool）→ PREFIX，供 libplacebo -Dlibdovi=enabled。
# pkg-config 名：dovi。默认静态库，避免再多带一份 libdovi 动态库。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${KOTV_MPV_BUILD_DIR:-$ROOT/.build/desktop-mpv}"
PREFIX="${KOTV_DESKTOP_FFMPEG_PREFIX:-$BUILD_DIR/prefix}"
STAMP="$PREFIX/.kotv-libdovi-v1"
DOVI_REF="${KOTV_LIBDOVI_REF:-libdovi-3.3.2}"
CARGO_C_VER="${KOTV_CARGO_C_VER:-0.10.25}"
JOBS="${KOTV_MPV_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "${NUMBER_OF_PROCESSORS:-4}")}"

need() { command -v "$1" >/dev/null || { echo "need $1" >&2; exit 1; }; }

is_windows() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
  esac
  [[ "${OS:-}" == "Windows_NT" ]]
}

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
if is_windows || [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
  export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
fi

if [[ -f "$STAMP" ]] && pkg-config --exists dovi 2>/dev/null \
  && { [[ -f "$PREFIX/lib/libdovi.a" ]] || [[ -f "$PREFIX/lib/dovi.lib" ]]; }; then
  echo "ok cached libdovi $(pkg-config --modversion dovi 2>/dev/null || echo present)"
  exit 0
fi

need curl
need tar
need git

ensure_rust() {
  if ! command -v rustc >/dev/null 2>&1 || ! command -v cargo >/dev/null 2>&1; then
    echo "==> install rustup (for libdovi)"
    # 勿用 curl|sh：set -o pipefail 下 rustup 关掉 stdin 后 curl 得 SIGPIPE → exit 141。
    mkdir -p "$BUILD_DIR"
    local rs="$BUILD_DIR/rustup-init.sh"
    curl --proto '=https' --tlsv1.2 -fsSL -o "$rs" https://sh.rustup.rs
    sh "$rs" -y --default-toolchain stable
    # shellcheck disable=SC1091
    source "$HOME/.cargo/env" 2>/dev/null || true
    export PATH="$HOME/.cargo/bin:$PATH"
  fi
  need rustc
  need cargo
  rustup default stable >/dev/null 2>&1 || true
}

ensure_cargo_c() {
  if command -v cargo-cinstall >/dev/null 2>&1; then
    return 0
  fi
  mkdir -p "$BUILD_DIR/bin" "$HOME/.cargo/bin"
  export PATH="$BUILD_DIR/bin:$HOME/.cargo/bin:$PATH"
  local url dest
  if is_windows; then
    url="https://github.com/lu-zero/cargo-c/releases/download/v${CARGO_C_VER}/cargo-c-windows-gnu.zip"
    dest="$BUILD_DIR/cargo-c-windows-gnu.zip"
    curl -fL --retry 5 --retry-delay 2 -o "$dest" "$url"
    need unzip
    unzip -o "$dest" -d "$BUILD_DIR/bin"
  elif [[ "$(uname -s)" == "Darwin" ]]; then
    url="https://github.com/lu-zero/cargo-c/releases/download/v${CARGO_C_VER}/cargo-c-macos.zip"
    dest="$BUILD_DIR/cargo-c-macos.zip"
    curl -fL --retry 5 --retry-delay 2 -o "$dest" "$url"
    need unzip
    unzip -o "$dest" -d "$BUILD_DIR/bin"
  else
    local arch
    arch="$(uname -m)"
    case "$arch" in
      x86_64|amd64)
        url="https://github.com/lu-zero/cargo-c/releases/download/v${CARGO_C_VER}/cargo-c-x86_64-unknown-linux-musl.tar.gz"
        ;;
      aarch64|arm64)
        url="https://github.com/lu-zero/cargo-c/releases/download/v${CARGO_C_VER}/cargo-c-aarch64-unknown-linux-musl.tar.gz"
        ;;
      *)
        echo "==> cargo-c: no prebuilt for $arch; cargo install"
        cargo install cargo-c --locked --version "$CARGO_C_VER"
        command -v cargo-cinstall >/dev/null || { echo "ERROR: cargo-cinstall missing" >&2; exit 1; }
        return 0
        ;;
    esac
    dest="$BUILD_DIR/cargo-c-linux.tgz"
    curl -fL --retry 5 --retry-delay 2 -o "$dest" "$url"
    tar -xzf "$dest" -C "$BUILD_DIR/bin"
  fi
  chmod +x "$BUILD_DIR/bin"/cargo-c* 2>/dev/null || true
  export PATH="$BUILD_DIR/bin:$HOME/.cargo/bin:$PATH"
  command -v cargo-cinstall >/dev/null || { echo "ERROR: cargo-cinstall missing after extract" >&2; exit 1; }
}

rust_target() {
  if is_windows; then
    echo "x86_64-pc-windows-gnu"
    return
  fi
  if [[ "$(uname -s)" == "Darwin" ]]; then
    local arch="${KOTV_MPV_MACOS_ARCH:-$(uname -m)}"
    case "$arch" in
      arm64|aarch64) echo "aarch64-apple-darwin" ;;
      x86_64) echo "x86_64-apple-darwin" ;;
      *) echo "${arch}-apple-darwin" ;;
    esac
    return
  fi
  # 本机 triple
  rustc -vV | awk '/^host:/{print $2; exit}'
}

ensure_rust
ensure_cargo_c

TARGET="$(rust_target)"
echo "==> build libdovi $DOVI_REF (target=$TARGET → $PREFIX)"
rustup target add "$TARGET" >/dev/null 2>&1 || true

if is_windows; then
  # MinGW：cc/crates 必须走同一套 gcc，否则 asm/链接炸。
  export CC_x86_64_pc_windows_gnu="${CC:-x86_64-w64-mingw32-gcc}"
  export CXX_x86_64_pc_windows_gnu="${CXX:-x86_64-w64-mingw32-g++}"
  export AR_x86_64_pc_windows_gnu="${AR:-x86_64-w64-mingw32-ar}"
  export CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER="${CC:-x86_64-w64-mingw32-gcc}"
  if ! command -v "${CC:-gcc}" >/dev/null 2>&1 && command -v gcc >/dev/null 2>&1; then
    export CC_x86_64_pc_windows_gnu=gcc
    export CXX_x86_64_pc_windows_gnu=g++
    export AR_x86_64_pc_windows_gnu=ar
    export CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER=gcc
  fi
elif [[ "$(uname -s)" == "Darwin" ]]; then
  local_arch="$(uname -m)"
  want_arch="${KOTV_MPV_MACOS_ARCH:-$local_arch}"
  if [[ "$want_arch" == "x86_64" && "$local_arch" == "arm64" ]]; then
    export CFLAGS="${CFLAGS:-} -arch x86_64"
    export CXXFLAGS="${CXXFLAGS:-} -arch x86_64"
    export CARGO_TARGET_X86_64_APPLE_DARWIN_RUSTFLAGS="-C link-arg=-arch -C link-arg=x86_64"
  elif [[ "$want_arch" == "arm64" || "$want_arch" == "aarch64" ]]; then
    export CFLAGS="${CFLAGS:-} -arch arm64"
    export CXXFLAGS="${CXXFLAGS:-} -arch arm64"
  fi
fi

mkdir -p "$BUILD_DIR" "$PREFIX/lib/pkgconfig" "$PREFIX/include"
cd "$BUILD_DIR"
if [[ ! -d dovi_tool/.git ]]; then
  rm -rf dovi_tool
  git clone --depth 1 --branch "$DOVI_REF" https://github.com/quietvoid/dovi_tool.git dovi_tool
else
  git -C dovi_tool fetch --depth 1 origin "refs/tags/${DOVI_REF}:refs/tags/${DOVI_REF}" 2>/dev/null || true
  git -C dovi_tool checkout -q "$DOVI_REF" 2>/dev/null \
    || git -C dovi_tool checkout -q "tags/$DOVI_REF"
fi

# 静态库：桌面 libplacebo/mpv 直接吃进产物，少一份运行时 DLL/so。
(
  cd dovi_tool/dolby_vision
  cargo cinstall --release \
    --prefix="$PREFIX" \
    --libdir="$PREFIX/lib" \
    --library-type staticlib \
    --target "$TARGET" \
    -j "$JOBS"
)

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
pkg-config --exists dovi || {
  echo "ERROR: dovi.pc not visible after cargo cinstall" >&2
  find "$PREFIX" -name 'dovi.pc' 2>/dev/null || true
  ls -la "$PREFIX/lib" 2>/dev/null | head -40 || true
  exit 1
}
# 有的 cargo-c 版本装成 libdovi.a / libdovi.dll.a；接受任一。
if [[ ! -f "$PREFIX/lib/libdovi.a" && ! -f "$PREFIX/lib/dovi.lib" && ! -f "$PREFIX/lib/libdovi.dll.a" ]]; then
  echo "ERROR: libdovi static library missing under $PREFIX/lib" >&2
  ls -la "$PREFIX/lib"/libdovi* "$PREFIX/lib"/dovi* 2>/dev/null || true
  exit 1
fi

printf '%s\n' "$DOVI_REF" >"$STAMP"
echo "ok libdovi $(pkg-config --modversion dovi) (static, $DOVI_REF)"
