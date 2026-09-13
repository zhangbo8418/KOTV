#!/usr/bin/env bash
# 桌面 libdovi（quietvoid/dovi_tool）→ PREFIX，供 libplacebo -Dlibdovi=enabled。
# pkg-config 名：dovi。默认静态库，避免再多带一份 libdovi 动态库。
#
# Win7：仍用当前 stable + 现代 libdovi 编；GetSystemTimePreciseAsFileTime
# 由 scripts/patch-win7-pe-imports.py 在最终 PE 上改写成 GetSystemTimeAsFileTime。
# （钉 Rust 1.77 已不可行：crates.io 会不断解析到 edition2024 的传递依赖。）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${KOTV_MPV_BUILD_DIR:-$ROOT/.build/desktop-mpv}"
PREFIX="${KOTV_DESKTOP_FFMPEG_PREFIX:-$BUILD_DIR/prefix}"
DOVI_REF="${KOTV_LIBDOVI_REF:-libdovi-3.3.2}"
CARGO_C_VER="${KOTV_CARGO_C_VER:-0.10.25}"
STAMP="$PREFIX/.kotv-libdovi-v7-stable-${DOVI_REF}"
WANT_STAMP="${DOVI_REF} rust=stable cargo-c=${CARGO_C_VER} target=gnu"
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

if [[ -f "$STAMP" && "$(cat "$STAMP" 2>/dev/null || true)" == "$WANT_STAMP" ]] \
  && pkg-config --exists dovi 2>/dev/null \
  && { [[ -f "$PREFIX/lib/libdovi.a" ]] || [[ -f "$PREFIX/lib/dovi.lib" ]] || [[ -f "$PREFIX/lib/libdovi.dll.a" ]]; }; then
  echo "ok cached libdovi $(pkg-config --modversion dovi 2>/dev/null || echo present)"
  exit 0
fi

need curl
need tar
need git

ensure_rust() {
  if ! command -v rustc >/dev/null 2>&1 || ! command -v cargo >/dev/null 2>&1; then
    echo "==> install rustup (for libdovi)"
    mkdir -p "$BUILD_DIR"
    local rs="$BUILD_DIR/rustup-init.sh"
    curl --proto '=https' --tlsv1.2 -fsSL -o "$rs" https://sh.rustup.rs
    set +e
    set +o pipefail
    sh "$rs" -y --default-toolchain stable
    set -o pipefail
    set -e
    # shellcheck disable=SC1091
    source "$HOME/.cargo/env" 2>/dev/null || true
    export PATH="$HOME/.cargo/bin:$PATH"
  fi
  need rustc
  need cargo
  rustup default stable >/dev/null 2>&1 || true
}

ensure_cargo_c() {
  local bindir="$BUILD_DIR/cargo-c-v${CARGO_C_VER}"
  mkdir -p "$bindir" "$HOME/.cargo/bin"
  if [[ -x "$bindir/cargo-cinstall" || -x "$bindir/cargo-cinstall.exe" ]]; then
    export PATH="$bindir:$PATH"
    echo "ok cargo-cinstall=$(command -v cargo-cinstall) (cached v${CARGO_C_VER})"
    return 0
  fi
  echo "==> fetch cargo-c v${CARGO_C_VER}"
  local url dest
  if is_windows; then
    url="https://github.com/lu-zero/cargo-c/releases/download/v${CARGO_C_VER}/cargo-c-windows-gnu.zip"
    dest="$BUILD_DIR/cargo-c-v${CARGO_C_VER}-windows-gnu.zip"
    curl -fsSL --retry 5 --retry-delay 2 -o "$dest" "$url"
    need unzip
    unzip -o "$dest" -d "$bindir"
  elif [[ "$(uname -s)" == "Darwin" ]]; then
    url="https://github.com/lu-zero/cargo-c/releases/download/v${CARGO_C_VER}/cargo-c-macos.zip"
    dest="$BUILD_DIR/cargo-c-v${CARGO_C_VER}-macos.zip"
    curl -fsSL --retry 5 --retry-delay 2 -o "$dest" "$url"
    need unzip
    unzip -o "$dest" -d "$bindir"
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
        cargo install cargo-c --locked --version "$CARGO_C_VER" --root "$bindir"
        export PATH="$bindir/bin:$PATH"
        command -v cargo-cinstall >/dev/null || { echo "ERROR: cargo-cinstall missing" >&2; exit 1; }
        echo "ok cargo-cinstall=$(command -v cargo-cinstall)"
        return 0
        ;;
    esac
    dest="$BUILD_DIR/cargo-c-v${CARGO_C_VER}-linux.tgz"
    curl -fsSL --retry 5 --retry-delay 2 -o "$dest" "$url"
    tar -xzf "$dest" -C "$bindir"
  fi
  chmod +x "$bindir"/cargo-c* 2>/dev/null || true
  if [[ ! -x "$bindir/cargo-cinstall" && ! -x "$bindir/cargo-cinstall.exe" ]]; then
    local f
    f="$(find "$bindir" -type f \( -name 'cargo-cinstall' -o -name 'cargo-cinstall.exe' \) 2>/dev/null | head -1 || true)"
    if [[ -n "$f" ]]; then
      ln -sfn "$f" "$bindir/cargo-cinstall"
      ln -sfn "$(dirname "$f")"/cargo-capi "$bindir/cargo-capi" 2>/dev/null || true
      ln -sfn "$(dirname "$f")"/cargo-cbuild "$bindir/cargo-cbuild" 2>/dev/null || true
      if [[ -f "$(dirname "$f")/cargo-cinstall.exe" ]]; then
        cp -f "$(dirname "$f")/cargo-cinstall.exe" "$bindir/cargo-cinstall.exe"
      fi
    fi
  fi
  export PATH="$bindir:$PATH"
  command -v cargo-cinstall >/dev/null || { echo "ERROR: cargo-cinstall missing after extract v${CARGO_C_VER}" >&2; ls -laR "$bindir" >&2; exit 1; }
  echo "ok cargo-cinstall=$(command -v cargo-cinstall) (v${CARGO_C_VER})"
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
  local vv host="" line
  vv="$(rustc -vV 2>/dev/null || true)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      host:*) host="${line#host: }"; host="${host#"${host%%[![:space:]]*}"}"; break ;;
    esac
  done <<< "$vv"
  if [[ -z "$host" ]]; then
    case "$(uname -m)" in
      x86_64|amd64) host="x86_64-unknown-linux-gnu" ;;
      aarch64|arm64) host="aarch64-unknown-linux-gnu" ;;
      *) host="$(uname -m)-unknown-linux-gnu" ;;
    esac
  fi
  printf '%s\n' "$host"
}

ensure_rust
ensure_cargo_c

TARGET="$(rust_target)"
echo "==> build libdovi $DOVI_REF (target=$TARGET rust=stable → $PREFIX)"
rustup target add "$TARGET" >/dev/null 2>&1 || true

if is_windows; then
  rustup toolchain install stable-x86_64-pc-windows-gnu >/dev/null 2>&1 || true
  export RUSTUP_TOOLCHAIN=stable-x86_64-pc-windows-gnu
  cleaned=""
  old_ifs="$IFS"
  IFS=':'
  # shellcheck disable=SC2086
  for part in $PATH; do
    case "$part" in
      *Git*/usr/bin*|*git*/usr/bin*) continue ;;
    esac
    if [[ -z "$cleaned" ]]; then cleaned="$part"; else cleaned="$cleaned:$part"; fi
  done
  IFS="$old_ifs"
  export PATH="$cleaned"
  if command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
    export CC=x86_64-w64-mingw32-gcc
    export CXX=x86_64-w64-mingw32-g++
    export AR=x86_64-w64-mingw32-ar
  elif command -v gcc >/dev/null 2>&1; then
    export CC=gcc
    export CXX=g++
    export AR=ar
  fi
  export CC_x86_64_pc_windows_gnu="${CC}"
  export CXX_x86_64_pc_windows_gnu="${CXX}"
  export AR_x86_64_pc_windows_gnu="${AR}"
  export CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER="${CC}"
  export CARGO_BUILD_TARGET=x86_64-pc-windows-gnu
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

echo "ok rustc=$(rustc --version 2>/dev/null || true) toolchain=${RUSTUP_TOOLCHAIN:-default}"

mkdir -p "$BUILD_DIR" "$PREFIX/lib/pkgconfig" "$PREFIX/include"
cd "$BUILD_DIR"
if [[ ! -d dovi_tool/.git ]]; then
  rm -rf dovi_tool
  git clone --depth 1 --branch "$DOVI_REF" https://github.com/quietvoid/dovi_tool.git dovi_tool
else
  git -C dovi_tool fetch --depth 1 origin "refs/tags/${DOVI_REF}:refs/tags/${DOVI_REF}" 2>/dev/null || true
  git -C dovi_tool checkout -q "$DOVI_REF" 2>/dev/null \
    || git -C dovi_tool checkout -q "tags/$DOVI_REF"
  git -C dovi_tool reset --hard -q HEAD 2>/dev/null || true
fi

rm -f "$PREFIX/lib/libdovi.a" "$PREFIX/lib/libdovi.dll.a" "$PREFIX/lib/dovi.lib" \
  "$PREFIX/lib/pkgconfig/dovi.pc" 2>/dev/null || true

(
  cd dovi_tool/dolby_vision
  cargo cinstall --release \
    --prefix="$PREFIX" \
    --libdir="$PREFIX/lib" \
    --library-type staticlib \
    --target="$TARGET" \
    -j "$JOBS"
)

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
pkg-config --exists dovi || {
  echo "ERROR: dovi.pc not visible after cargo cinstall" >&2
  find "$PREFIX" -name 'dovi.pc' 2>/dev/null || true
  ls -la "$PREFIX/lib" 2>/dev/null | head -40 || true
  exit 1
}
if [[ ! -f "$PREFIX/lib/libdovi.a" && ! -f "$PREFIX/lib/dovi.lib" && ! -f "$PREFIX/lib/libdovi.dll.a" ]]; then
  echo "ERROR: libdovi static library missing under $PREFIX/lib" >&2
  ls -la "$PREFIX/lib"/libdovi* "$PREFIX/lib"/dovi* 2>/dev/null || true
  exit 1
fi

printf '%s\n' "$WANT_STAMP" >"$STAMP"
echo "ok libdovi $(pkg-config --modversion dovi) (static, $DOVI_REF, rust=stable)"
