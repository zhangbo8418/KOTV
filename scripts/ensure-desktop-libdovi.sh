#!/usr/bin/env bash
# 桌面 libdovi（quietvoid/dovi_tool）→ PREFIX，供 libplacebo -Dlibdovi=enabled。
# pkg-config 名：dovi。默认静态库，避免再多带一份 libdovi 动态库。
#
# Win7（KOTV_MPV_WIN7=1 / KOTV_WIN7=1）：钉 Rust 1.77.x。
# 1.78+ 的 Windows std 硬链 GetSystemTimePreciseAsFileTime（Win8+），静链进 mpv 后 Win7 无法启动。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${KOTV_MPV_BUILD_DIR:-$ROOT/.build/desktop-mpv}"
PREFIX="${KOTV_DESKTOP_FFMPEG_PREFIX:-$BUILD_DIR/prefix}"
DOVI_REF="${KOTV_LIBDOVI_REF:-libdovi-3.3.2}"
CARGO_C_VER="${KOTV_CARGO_C_VER:-0.10.25}"
# 最后一版「默认 Windows target 仍能在 Win7 跑」的 Rust（1.78 起抬高）。
WIN7_RUST_VER="${KOTV_LIBDOVI_WIN7_RUST:-1.77.2}"
# 3.3.2 要求 rustc 1.85；Win7 钉 1.77 时用 3.3.0（MSRV 1.62）+ 锁住依赖，避免解析到 1.79+ 的 crates。
WIN7_DOVI_REF="${KOTV_LIBDOVI_WIN7_REF:-libdovi-3.3.0}"
# 新 cargo-c 会给 rustc 传 --check-cfg；1.77 stable 不认，必须配同期旧 cargo-c。
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
  STAMP_TAG="win7-rust${WIN7_RUST_VER}-${DOVI_REF}-cargoc${CARGO_C_VER}"
else
  RUST_PIN="stable"
  STAMP_TAG="stable-${DOVI_REF}"
fi
STAMP="$PREFIX/.kotv-libdovi-v6-${STAMP_TAG}"
WANT_STAMP="${DOVI_REF} rust=${RUST_PIN} cargo-c=${CARGO_C_VER} nodev=1 target=gnu"

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
    # 勿用 curl|sh：set -o pipefail 下 rustup 关掉 stdin 后 curl 得 SIGPIPE → exit 141。
    # rustup-init 自身偶发以 141 退出但已装好；以 rustc 是否可用为准。
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
  # 预编译包有时解压到子目录
  if [[ ! -x "$bindir/cargo-cinstall" && ! -x "$bindir/cargo-cinstall.exe" ]]; then
    local f
    f="$(find "$bindir" -type f \( -name 'cargo-cinstall' -o -name 'cargo-cinstall.exe' \) 2>/dev/null | head -1 || true)"
    if [[ -n "$f" ]]; then
      ln -sfn "$f" "$bindir/cargo-cinstall"
      ln -sfn "$(dirname "$f")"/cargo-capi "$bindir/cargo-capi" 2>/dev/null || true
      ln -sfn "$(dirname "$f")"/cargo-cbuild "$bindir/cargo-cbuild" 2>/dev/null || true
      # Windows: also link .exe names if present
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
  # 勿对 rustc 做管道：pipefail 下下游提前关 fd → rustc SIGPIPE → exit 141。
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
  # 从 PATH 去掉 Git usr/bin，避免再 shadow MinGW/MSVC link。
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
  # 优先 MinGW gcc
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

# stamp 升级或工具链切换时清掉旧库，避免 cargo-c 认为已安装而跳过。
rm -f "$PREFIX/lib/libdovi.a" "$PREFIX/lib/libdovi.dll.a" "$PREFIX/lib/dovi.lib" \
  "$PREFIX/lib/pkgconfig/dovi.pc" 2>/dev/null || true

# Win7：去掉 bench/dev-deps（criterion→clap edition2024，Cargo 1.77 解析不了），
# 再按上游 3.3.0 lock 钉死直接依赖。
if is_windows && is_win7_build; then
  echo "==> Win7: pin dolby_vision deps for rustc ${WIN7_RUST_VER}"
  python3 - "$BUILD_DIR/dovi_tool/dolby_vision/Cargo.toml" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
t = p.read_text(encoding="utf-8")
# 去掉会拉进 clap_builder(edition2024) 的开发依赖与 bench。
t = re.sub(r"(?ms)^\[dev-dependencies\]\s*.*?(?=^\[|\Z)", "", t)
t = re.sub(r"(?ms)^\[\[bench\]\]\s*.*?(?=^\[|\Z)", "", t)
# 与 quietvoid/dovi_tool@libdovi-3.3.0 Cargo.lock 对齐
pins = {
    "bitvec_helpers": "=3.1.3",
    "anyhow": "=1.0.81",
    "bitvec": "=1.0.1",
    "crc": "=3.0.1",
}
for name, ver in pins.items():
    t2, n = re.subn(
        rf'(?m)^({re.escape(name)}\s*=\s*\{{\s*version\s*=\s*")[^"]+(")',
        rf"\g<1>{ver}\2",
        t,
        count=1,
    )
    if n:
        t = t2
        continue
    t2, n = re.subn(
        rf'(?m)^({re.escape(name)}\s*=\s*")[^"]+(")',
        rf"\g<1>{ver}\2",
        t,
        count=1,
    )
    if n != 1:
        raise SystemExit(f"ERROR: cannot pin {name} in {p}")
    t = t2
if re.search(r"(?m)^bitstream-io\s*=", t) is None:
    t = t.replace(
        "[dependencies]\n",
        '[dependencies]\nbitstream-io = "=2.2.0"\n',
        1,
    )
else:
    t, _ = re.subn(
        r'(?m)^(bitstream-io\s*=\s*")[^"]+(")',
        r"\g<1>=2.2.0\2",
        t,
        count=1,
    )
p.write_text(t, encoding="utf-8")
print(f"ok pinned {p} (dev-deps stripped)")
PY
  rm -f "$BUILD_DIR/dovi_tool/dolby_vision/Cargo.lock"
  (
    cd "$BUILD_DIR/dovi_tool/dolby_vision"
    cargo generate-lockfile
    for spec in \
      bitvec_helpers:3.1.3 \
      bitstream-io:2.2.0 \
      crc:3.0.1 \
      anyhow:1.0.81 \
      bitvec:1.0.1; do
      name="${spec%%:*}"
      ver="${spec##*:}"
      cargo update -p "$name" --precise "$ver"
    done
  )
fi

# 静态库：桌面 libplacebo/mpv 直接吃进产物，少一份运行时 DLL/so。
(
  cd dovi_tool/dolby_vision
  locked=()
  if [[ -f Cargo.lock ]]; then
    locked=(--locked)
  fi
  # cargo-c 可能不认 --locked；失败则去掉再试。
  if ! cargo cinstall --release \
    --prefix="$PREFIX" \
    --libdir="$PREFIX/lib" \
    --library-type staticlib \
    --target "$TARGET" \
    "${locked[@]}" \
    -j "$JOBS"; then
    if ((${#locked[@]})); then
      echo "WARN: cargo cinstall --locked failed; retry without --locked" >&2
      cargo cinstall --release \
        --prefix="$PREFIX" \
        --libdir="$PREFIX/lib" \
        --library-type staticlib \
        --target "$TARGET" \
        -j "$JOBS"
    else
      exit 1
    fi
  fi
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

# Win7：静态库对象里若仍出现该导入名，说明钉错了工具链。
if is_windows && is_win7_build; then
  lib=""
  for cand in "$PREFIX/lib/libdovi.a" "$PREFIX/lib/libdovi.dll.a"; do
    [[ -f "$cand" ]] && lib="$cand" && break
  done
  if [[ -n "$lib" ]] && command -v nm >/dev/null 2>&1; then
    if nm "$lib" 2>/dev/null | grep -qF 'GetSystemTimePreciseAsFileTime'; then
      echo "ERROR: $lib still references GetSystemTimePreciseAsFileTime (Rust $RUST_PIN too new?)" >&2
      rustc --version >&2 || true
      exit 1
    fi
  fi
fi

printf '%s\n' "$WANT_STAMP" >"$STAMP"
echo "ok libdovi $(pkg-config --modversion dovi) (static, $DOVI_REF, rust=$RUST_PIN)"
