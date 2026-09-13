#!/usr/bin/env bash
# 桌面 libdovi（quietvoid/dovi_tool）→ PREFIX，供 libplacebo -Dlibdovi=enabled。
# pkg-config 名：dovi。默认静态库，避免再多带一份 libdovi 动态库。
#
# Win7（KOTV_MPV_WIN7=1 / KOTV_WIN7=1）：钉 Rust 1.77.x + libdovi-3.3.0 + 上游 Cargo.lock。
# 1.78+ Windows std 硬链 GetSystemTimePreciseAsFileTime（Win8+）。
# 禁止删 lock / generate-lockfile（否则会解析到 clap_builder edition2024）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${KOTV_MPV_BUILD_DIR:-$ROOT/.build/desktop-mpv}"
PREFIX="${KOTV_DESKTOP_FFMPEG_PREFIX:-$BUILD_DIR/prefix}"
DOVI_REF="${KOTV_LIBDOVI_REF:-libdovi-3.3.2}"
CARGO_C_VER="${KOTV_CARGO_C_VER:-0.10.25}"
# 最后一版「默认 Windows target 仍能在 Win7 跑」的 Rust（1.78 起抬高）。
WIN7_RUST_VER="${KOTV_LIBDOVI_WIN7_RUST:-1.77.2}"
# 3.3.2 要求 rustc 1.85；Win7 钉 1.77 时用 3.3.0（MSRV 1.62）。
WIN7_DOVI_REF="${KOTV_LIBDOVI_WIN7_REF:-libdovi-3.3.0}"
# 新 cargo-c 会给 rustc 传 --check-cfg；1.77 stable 不认。
WIN7_CARGO_C_VER="${KOTV_LIBDOVI_WIN7_CARGO_C:-0.9.32}"
JOBS="${KOTV_MPV_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "${NUMBER_OF_PROCESSORS:-4}")}"

need() { command -v "$1" >/dev/null || { echo "need $1" >&2; exit 1; }; }

is_windows() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
  esac
  [[ "${OS:-}" == "Windows_NT" ]]
}

is_win7_build() {
  [[ "${KOTV_MPV_WIN7:-${KOTV_WIN7:-0}}" == "1" ]]
}

# stamp 带工具链标签，避免 Win7 / 普通 Windows 共用 PREFIX 缓存串味。
if is_windows && is_win7_build; then
  RUST_PIN="$WIN7_RUST_VER"
  DOVI_REF="${KOTV_LIBDOVI_REF:-$WIN7_DOVI_REF}"
  CARGO_C_VER="$WIN7_CARGO_C_VER"
  STAMP_TAG="win7-rust${WIN7_RUST_VER}-${DOVI_REF}-cargoc${CARGO_C_VER}-locked"
else
  RUST_PIN="stable"
  STAMP_TAG="stable-${DOVI_REF}"
fi
STAMP="$PREFIX/.kotv-libdovi-v8-${STAMP_TAG}"
WANT_STAMP="${DOVI_REF} rust=${RUST_PIN} cargo-c=${CARGO_C_VER} locked=1 target=gnu"

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
if is_windows || [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
  export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
fi

if [[ -f "$STAMP" && "$(cat "$STAMP" 2>/dev/null || true)" == "$WANT_STAMP" ]] \
  && pkg-config --exists dovi 2>/dev/null \
  && { [[ -f "$PREFIX/lib/libdovi.a" ]] || [[ -f "$PREFIX/lib/dovi.lib" ]] || [[ -f "$PREFIX/lib/libdovi.dll.a" ]]; }; then
  echo "ok cached libdovi $(pkg-config --modversion dovi 2>/dev/null || echo present) ($STAMP_TAG)"
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
  # 勿把全局 default 钉成 1.77（同机其它步骤可能要 stable）；用 RUSTUP_TOOLCHAIN。
  rustup default stable >/dev/null 2>&1 || true
}

ensure_cargo_c() {
  # 按版本装到独立目录，Win7 的 0.9.32 不能被 PATH 上残留的 0.10.x 抢走。
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
        echo "==> cargo-c: no prebuilt for $arch; cargo install v${CARGO_C_VER}"
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
        ln -sfn "$(dirname "$f")/cargo-cinstall.exe" "$bindir/cargo-cinstall.exe" 2>/dev/null || \
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

# Win7：独立 crate + 仓库内钉死的 Cargo.toml/Cargo.lock（禁止 generate-lockfile）。
prepare_win7_dolby_vision() {
  local src="$BUILD_DIR/dovi_tool"
  local dst="$BUILD_DIR/libdovi-win7-crate"
  local overlay="$ROOT/scripts/win7/libdovi"
  [[ -d "$src/dolby_vision" ]] || { echo "ERROR: missing $src/dolby_vision" >&2; exit 1; }
  [[ -f "$overlay/Cargo.toml" && -f "$overlay/Cargo.lock" ]] || {
    echo "ERROR: missing Win7 libdovi overlay at $overlay/{Cargo.toml,Cargo.lock}" >&2
    exit 1
  }

  echo "==> Win7: isolate dolby_vision + apply locked overlay (no generate-lockfile)"
  rm -rf "$dst"
  mkdir -p "$dst"
  # 只要源码；清单与锁一律用仓库钉死版本。
  cp -a "$src/dolby_vision/." "$dst/"
  cp -f "$overlay/Cargo.toml" "$dst/Cargo.toml"
  cp -f "$overlay/Cargo.lock" "$dst/Cargo.lock"
  if grep -qE 'clap_builder|edition2024' "$dst/Cargo.lock"; then
    echo "ERROR: overlay Cargo.lock contains clap/edition2024" >&2
    exit 1
  fi
  echo "ok Win7 crate at $dst (overlay lock $(wc -c <"$dst/Cargo.lock" | tr -d ' ') bytes)"
}

ensure_rust
ensure_cargo_c

TARGET="$(rust_target)"
echo "==> build libdovi $DOVI_REF (target=$TARGET rust=$RUST_PIN → $PREFIX)"

if is_windows; then
  # MinGW：host/build-script 也必须走 gnu，否则默认 MSVC host 会找 link.exe，
  # 却命中 Git 的 /usr/bin/link（Unix link）而炸。
  if is_win7_build; then
    local_tc="${WIN7_RUST_VER}-x86_64-pc-windows-gnu"
    echo "==> Win7 libdovi: rustup toolchain $local_tc (avoid GetSystemTimePreciseAsFileTime)"
    rustup toolchain install "$local_tc" >/dev/null
    rustup target add x86_64-pc-windows-gnu --toolchain "$local_tc" >/dev/null 2>&1 || true
    export RUSTUP_TOOLCHAIN="$local_tc"
  else
    rustup toolchain install stable-x86_64-pc-windows-gnu >/dev/null 2>&1 || true
    export RUSTUP_TOOLCHAIN=stable-x86_64-pc-windows-gnu
  fi
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
  rustup target add "$TARGET" >/dev/null 2>&1 || true
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
else
  rustup target add "$TARGET" >/dev/null 2>&1 || true
fi

echo "ok rustc=$(rustc --version 2>/dev/null || true) toolchain=${RUSTUP_TOOLCHAIN:-default}"

mkdir -p "$BUILD_DIR" "$PREFIX/lib/pkgconfig" "$PREFIX/include"
cd "$BUILD_DIR"
# Win7 换 tag/工具链时 shallow 仓库可能不含目标 tag，直接重建。
if is_windows && is_win7_build && { [[ ! -f "$STAMP" ]] || [[ "$(cat "$STAMP" 2>/dev/null || true)" != "$WANT_STAMP" ]]; }; then
  rm -rf dovi_tool
fi
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

CRATE_DIR="$BUILD_DIR/dovi_tool/dolby_vision"
if is_windows && is_win7_build; then
  prepare_win7_dolby_vision
  CRATE_DIR="$BUILD_DIR/libdovi-win7-crate"
fi

# 静态库：桌面 libplacebo/mpv 直接吃进产物，少一份运行时 DLL/so。
(
  cd "$CRATE_DIR"
  if is_windows && is_win7_build; then
    # 必须 --locked：禁止回退到重新解析（会拉到 edition2024）。
    [[ -f Cargo.lock ]] || { echo "ERROR: missing $CRATE_DIR/Cargo.lock" >&2; exit 1; }
    cargo cinstall --release \
      --prefix="$PREFIX" \
      --libdir="$PREFIX/lib" \
      --library-type staticlib \
      --target="$TARGET" \
      --locked \
      -j "$JOBS"
  else
    cargo cinstall --release \
      --prefix="$PREFIX" \
      --libdir="$PREFIX/lib" \
      --library-type staticlib \
      --target="$TARGET" \
      -j "$JOBS"
  fi
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

# Win7：静态库若硬链（undefined）Win8+ 导入，说明钉错了工具链。
# 仅匹配 nm 的 U/u 未定义符号；.rdata 里 GetProcAddress 用的名字字符串不算失败。
if is_windows && is_win7_build; then
  lib=""
  for cand in "$PREFIX/lib/libdovi.a" "$PREFIX/lib/libdovi.dll.a"; do
    [[ -f "$cand" ]] && lib="$cand" && break
  done
  if [[ -n "$lib" ]] && command -v nm >/dev/null 2>&1; then
    undef="$(nm "$lib" 2>/dev/null || true)"
    if printf '%s\n' "$undef" | grep -E '^[0-9a-fA-F[:space:]]*[Uu][[:space:]]+GetSystemTimePreciseAsFileTime([[:space:]]|$)' >/dev/null; then
      echo "ERROR: $lib hard-imports GetSystemTimePreciseAsFileTime (Rust $RUST_PIN too new?)" >&2
      rustc --version >&2 || true
      printf '%s\n' "$undef" | grep -E 'GetSystemTimePreciseAsFileTime' | head -20 >&2 || true
      exit 1
    fi
    if printf '%s\n' "$undef" | grep -E '^[0-9a-fA-F[:space:]]*[Uu][[:space:]]+GetHostNameW([[:space:]]|$)' >/dev/null; then
      echo "ERROR: $lib hard-imports GetHostNameW (Win8+); unexpected with Rust $RUST_PIN" >&2
      printf '%s\n' "$undef" | grep -E 'GetHostNameW' | head -20 >&2 || true
      exit 1
    fi
    echo "ok libdovi nm: no hard Win8+ imports (strings may still appear for GetProcAddress)"
  fi
fi

printf '%s\n' "$WANT_STAMP" >"$STAMP"
echo "ok libdovi $(pkg-config --modversion dovi) (static, $DOVI_REF, rust=$RUST_PIN)"
