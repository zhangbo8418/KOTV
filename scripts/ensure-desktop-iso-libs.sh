#!/usr/bin/env bash
# 桌面 MPV 的 ISO：DVD（libdvdread+libdvdnav）和蓝光（libbluray，内置 UDF 读 .iso）。
# 静态装进 PREFIX，避免 Homebrew / 系统库串架构。
# libdvdread/libdvdnav 7.x 只有 meson，没有 ./configure。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/kotv-win-build-env.sh
source "$ROOT/scripts/kotv-win-build-env.sh"
BUILD_DIR="${KOTV_MPV_BUILD_DIR:-$ROOT/.build/desktop-mpv}"
PREFIX="${KOTV_DESKTOP_FFMPEG_PREFIX:-$BUILD_DIR/prefix}"
STAMP="$PREFIX/.kotv-iso-libs-v6-fongmi-compat"
JOBS="${KOTV_MPV_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "${NUMBER_OF_PROCESSORS:-4}")}"
COMPAT_DIR="$ROOT/scripts/patches/kotv-iso-fongmi-compat"

DVDREAD_VER=7.0.1
DVDREAD_SHA=2e3e04a305c15c3963aa03ae1b9a83c1d239880003fcf3dde986d3943355d407
DVDNAV_VER=7.0.0
DVDNAV_SHA=a2a18f5ad36d133c74bf9106b6445806fa253b09141a46392550394b647b221e
# 与当前 Homebrew 打包常用版本一致（上游 tip 另需本地兼容补丁）。
BLURAY_VER=1.5.0
BLURAY_SHA=f676408e91a5d321abf8b8d4dfdae36205c297dab5c54c3ec519639025f474a2

need curl
need tar
need meson
need ninja


fetch() {
  local url="$1" dest="$2" sha="$3"
  if [[ -f "$dest" ]]; then
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  # GHA 上 downloads.videolan.org 经常连不上；短超时逐个试镜像。
  if ! curl -fL --connect-timeout 20 --max-time 300 --retry 2 --retry-delay 2 \
      -o "$dest.partial" "$url"; then
    rm -f "$dest.partial"
    return 1
  fi
  mv "$dest.partial" "$dest"
  if command -v shasum >/dev/null; then
    echo "$sha  $dest" | shasum -a 256 -c -
  elif command -v sha256sum >/dev/null; then
    echo "$sha  $dest" | sha256sum -c -
  fi
}

# VideoLAN 发布包：优先公共镜像，再回落官方 CDN。
fetch_videolan() {
  local rel="$1" dest="$2" sha="$3"
  local bases=(
    "https://mirrors.ocf.berkeley.edu/videolan-ftp"
    "https://mirror.aarnet.edu.au/pub/videolan"
    "https://download.videolan.org/pub/videolan"
    "https://downloads.videolan.org/pub/videolan"
    "https://ftp.videolan.org/pub/videolan"
  )
  local base url
  if [[ -f "$dest" ]]; then
    return 0
  fi
  for base in "${bases[@]}"; do
    url="$base/$rel"
    echo "==> try $url"
    if fetch "$url" "$dest" "$sha"; then
      echo "ok fetched $rel from $base"
      return 0
    fi
    rm -f "$dest" "$dest.partial"
  done
  echo "ERROR: cannot fetch videolan/$rel from any mirror" >&2
  return 1
}

# Windows：meson 不会跑无扩展名的 bash pkg-config，必须用 .cmd + kotv-pkg-config.py。
MESON_NATIVE=()
ensure_pkg_config() {
  mkdir -p "$PREFIX/lib/pkgconfig"
  if kotv_is_windows_build; then
    local pkg_bin="$BUILD_DIR/bin" pc_win pkg_win
    mkdir -p "$pkg_bin"
    cp -f "$ROOT/scripts/kotv-pkg-config.py" "$pkg_bin/kotv-pkg-config.py"
    cat >"$pkg_bin/pkg-config" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
if command -v python3 >/dev/null 2>&1; then
  exec python3 "$here/kotv-pkg-config.py" "$@"
fi
exec python "$here/kotv-pkg-config.py" "$@"
EOF
    chmod +x "$pkg_bin/pkg-config"
    cat >"$pkg_bin/pkg-config.cmd" <<'EOF'
@echo off
setlocal
set "HERE=%~dp0"
python "%HERE%kotv-pkg-config.py" %*
exit /b %ERRORLEVEL%
EOF
    export PATH="$pkg_bin:$PATH"
    export PKG_CONFIG="$pkg_bin/pkg-config"
    if command -v cygpath >/dev/null 2>&1; then
      export PKG_CONFIG_PATH="$(cygpath -m "$PREFIX/lib/pkgconfig")"
      export PKG_CONFIG_LIBDIR="$(cygpath -m "$PREFIX/lib/pkgconfig")"
      pc_win="$(cygpath -m "$pkg_bin/pkg-config.cmd")"
      pkg_win="$(cygpath -m "$PREFIX/lib/pkgconfig")"
    else
      export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
      export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
      pc_win="$pkg_bin/pkg-config.cmd"
      pkg_win="$PREFIX/lib/pkgconfig"
    fi
    cat >"$BUILD_DIR/meson-native-iso.ini" <<EOF
[binaries]
pkg-config = '$pc_win'
pkgconfig = '$pc_win'

[built-in options]
pkg_config_path = '$pkg_win'
EOF
    MESON_NATIVE=(--native-file "$BUILD_DIR/meson-native-iso.ini")
    echo "ok ISO pkg-config -> $pc_win"
  else
    need pkg-config
    export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
      export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
    fi
  fi
}

ensure_pkg_config

iso_fongmi_apis_ok() {
  # 本仓库所用 mpv tip 需要这些符号；VideoLAN 正式包尚未提供，
  # 由 kotv-iso-fongmi-compat 注入静态库与头文件。
  local hdr_dvd="$PREFIX/include/dvdnav/dvdnav.h"
  local hdr_layout="$PREFIX/include/dvdnav/title_layout.h"
  local hdr_bd="$PREFIX/include/libbluray/bluray.h"
  [[ -f "$hdr_dvd" && -f "$hdr_layout" && -f "$hdr_bd" ]] || return 1
  grep -q 'DVDNAV_HAVE_TIME_SEARCH_FLOOR' "$hdr_dvd" || return 1
  grep -q 'dvdnav_time_search_floor' "$hdr_dvd" || return 1
  grep -q 'dvdnav_menu_available' "$hdr_dvd" || return 1
  grep -q 'dvdnav_get_next_block_with_wait' "$hdr_layout" || return 1
  grep -q 'dvdnav_get_active_logical_stream' "$hdr_layout" || return 1
  grep -q 'dvdnav_get_number_of_stream_attributes' "$hdr_layout" || return 1
  grep -q 'bd_get_titles_with_menu_info' "$hdr_bd" || return 1
  grep -q 'bd_seek_time_checked' "$hdr_bd" || return 1
  local a
  for a in "$PREFIX/lib/libdvdnav.a" "$PREFIX/lib/libbluray.a"; do
    [[ -f "$a" ]] || return 1
  done
  if command -v nm >/dev/null 2>&1; then
    nm -g "$PREFIX/lib/libdvdnav.a" 2>/dev/null | grep -q 'dvdnav_time_search_floor' || return 1
    nm -g "$PREFIX/lib/libdvdnav.a" 2>/dev/null | grep -q 'dvdnav_get_next_block_with_wait' || return 1
    nm -g "$PREFIX/lib/libdvdnav.a" 2>/dev/null | grep -q 'dvdnav_get_active_logical_stream' || return 1
    nm -g "$PREFIX/lib/libbluray.a" 2>/dev/null | grep -q 'bd_get_titles_with_menu_info' || return 1
  fi
  return 0
}

if [[ -f "$STAMP" && -f "$PREFIX/lib/pkgconfig/libbluray.pc" && -f "$PREFIX/lib/pkgconfig/dvdnav.pc" && -f "$PREFIX/lib/pkgconfig/dvdread.pc" ]] \
  && iso_fongmi_apis_ok; then
  echo "ok cached ISO libs (libbluray $BLURAY_VER, dvdnav $DVDNAV_VER + mpv tip API compat)"
  exit 0
fi

mkdir -p "$PREFIX" "$BUILD_DIR/src"
src="$BUILD_DIR/src"

extra_cflags=()
if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
  arch="${KOTV_MPV_MACOS_ARCH:-$(uname -m)}"
  extra_cflags=(-Dc_args="-arch $arch" -Dcpp_args="-arch $arch" -Dc_link_args="-arch $arch" -Dcpp_link_args="-arch $arch")
fi

build_meson_lib() {
  local name="$1" tar="$2"
  shift 2
  rm -rf "$BUILD_DIR/$name" "$BUILD_DIR/${name}-build"
  mkdir -p "$BUILD_DIR/$name"
  tar -xf "$tar" -C "$BUILD_DIR/$name" --strip-components=1
  # macOS bash 3.2 + set -u：空数组 "${arr[@]}" 会报 unbound variable
  local -a setup_args=(
    "$BUILD_DIR/${name}-build" "$BUILD_DIR/$name"
    --prefix="$PREFIX"
    --libdir=lib
    --buildtype=release
    -Ddefault_library=static
    --pkg-config-path="$PREFIX/lib/pkgconfig"
  )
  if ((${#MESON_NATIVE[@]})); then
    setup_args+=("${MESON_NATIVE[@]}")
  fi
  if ((${#extra_cflags[@]})); then
    setup_args+=("${extra_cflags[@]}")
  fi
  setup_args+=("$@")
  meson setup "${setup_args[@]}"
  meson compile -C "$BUILD_DIR/${name}-build" -j "$JOBS"
  meson install -C "$BUILD_DIR/${name}-build"
}

echo "==> ISO libs -> $PREFIX"
fetch_videolan "libdvdread/${DVDREAD_VER}/libdvdread-${DVDREAD_VER}.tar.xz" \
  "$src/libdvdread-${DVDREAD_VER}.tar.xz" "$DVDREAD_SHA"
fetch_videolan "libdvdnav/${DVDNAV_VER}/libdvdnav-${DVDNAV_VER}.tar.xz" \
  "$src/libdvdnav-${DVDNAV_VER}.tar.xz" "$DVDNAV_SHA"
fetch_videolan "libbluray/${BLURAY_VER}/libbluray-${BLURAY_VER}.tar.xz" \
  "$src/libbluray-${BLURAY_VER}.tar.xz" "$BLURAY_SHA"

dvdread_opts=(-Denable_docs=false -Dlibdvdcss=disabled)
if kotv_is_windows_build; then
  dvdread_opts+=(-Ddlfcn=builtin)
fi
build_meson_lib dvdread "$src/libdvdread-${DVDREAD_VER}.tar.xz" "${dvdread_opts[@]}"
# dvdnav 依赖已装好的 dvdread.pc（Windows 必须走上面的 .cmd pkg-config）。
if ! { [[ -n "${PKG_CONFIG:-}" ]] && "$PKG_CONFIG" --exists dvdread; } \
  && ! pkg-config --exists dvdread 2>/dev/null; then
  echo "ERROR: dvdread.pc not visible after install" >&2
  ls -la "$PREFIX/lib/pkgconfig" >&2 || true
  exit 1
fi
build_meson_lib dvdnav "$src/libdvdnav-${DVDNAV_VER}.tar.xz" -Denable_docs=false -Denable_examples=false

# MinGW libbluray 硬找 -lssp；部分 runner 的 toolchain 没有 libssp.a。
# required:false 即可：有就链，没有也能编过（与功能无关）。
if kotv_is_windows_build; then
  rm -rf "$BUILD_DIR/libbluray" "$BUILD_DIR/libbluray-build"
  mkdir -p "$BUILD_DIR/libbluray"
  tar -xf "$src/libbluray-${BLURAY_VER}.tar.xz" -C "$BUILD_DIR/libbluray" --strip-components=1
  python3 - "$BUILD_DIR/libbluray/meson.build" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text(encoding="utf-8")
old = "extra_dependencies += cc.find_library('ssp')"
new = "extra_dependencies += cc.find_library('ssp', required: false)"
if old not in t:
    raise SystemExit("libbluray ssp line changed; update patch")
p.write_text(t.replace(old, new, 1), encoding="utf-8")
print("ok patched libbluray ssp -> required: false")
PY
  bluray_setup=(
    "$BUILD_DIR/libbluray-build" "$BUILD_DIR/libbluray"
    --prefix="$PREFIX"
    --libdir=lib
    --buildtype=release
    -Ddefault_library=static
    --pkg-config-path="$PREFIX/lib/pkgconfig"
    -Denable_tools=false
    -Dbdj_jar=disabled
    -Dfontconfig=disabled
    -Dfreetype=disabled
    -Dlibxml2=disabled
  )
  if ((${#MESON_NATIVE[@]})); then
    bluray_setup+=("${MESON_NATIVE[@]}")
  fi
  meson setup "${bluray_setup[@]}"
  meson compile -C "$BUILD_DIR/libbluray-build" -j "$JOBS"
  meson install -C "$BUILD_DIR/libbluray-build"
else
  build_meson_lib libbluray "$src/libbluray-${BLURAY_VER}.tar.xz" \
    -Denable_tools=false \
    -Dbdj_jar=disabled \
    -Dfontconfig=disabled \
    -Dfreetype=disabled \
    -Dlibxml2=disabled
fi

pc() {
  if [[ -n "${PKG_CONFIG:-}" && -x "${PKG_CONFIG:-}" ]]; then
    "$PKG_CONFIG" "$@"
  else
    pkg-config "$@"
  fi
}

# 所用 mpv tip 调用了 VideoLAN 尚未发布的 API；往静态前缀库/头文件嫁接薄封装以保留 DVD/蓝光。
install_fongmi_iso_compat() {
  local cc="${CC:-cc}"
  local cflags=()
  local arch
  [[ -f "$COMPAT_DIR/dvdnav_fongmi_compat.c" && -f "$COMPAT_DIR/bluray_fongmi_compat.c" \
    && -f "$COMPAT_DIR/title_layout.h" ]] \
    || { echo "ERROR: missing $COMPAT_DIR sources" >&2; exit 1; }
  if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
    arch="${KOTV_MPV_MACOS_ARCH:-$(uname -m)}"
    cflags+=(-arch "$arch")
  fi
  mkdir -p "$BUILD_DIR/iso-fongmi-compat" "$PREFIX/include/dvdnav"
  cp -f "$COMPAT_DIR/title_layout.h" "$PREFIX/include/dvdnav/title_layout.h"
  "$cc" "${cflags[@]}" -O2 -fPIC -I"$PREFIX/include" -c \
    "$COMPAT_DIR/dvdnav_fongmi_compat.c" -o "$BUILD_DIR/iso-fongmi-compat/dvdnav_fongmi_compat.o"
  "$cc" "${cflags[@]}" -O2 -fPIC -I"$PREFIX/include" -c \
    "$COMPAT_DIR/bluray_fongmi_compat.c" -o "$BUILD_DIR/iso-fongmi-compat/bluray_fongmi_compat.o"
  need ar
  ar rcs "$PREFIX/lib/libdvdnav.a" "$BUILD_DIR/iso-fongmi-compat/dvdnav_fongmi_compat.o"
  ar rcs "$PREFIX/lib/libbluray.a" "$BUILD_DIR/iso-fongmi-compat/bluray_fongmi_compat.o"

  python3 - "$PREFIX/include/dvdnav/dvdnav.h" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text(encoding="utf-8")
marker = "KOTV_FONGMI_DVDNAV_COMPAT"
if marker in t:
    print("ok dvdnav.h already has mpv tip compat decls")
    raise SystemExit(0)
block = f"""
/* {marker}: symbols required by our mpv tip before VideoLAN ships them. */
#ifndef DVDNAV_HAVE_TIME_SEARCH_FLOOR
#define DVDNAV_HAVE_TIME_SEARCH_FLOOR 1
#endif
DVDNAV_API dvdnav_status_t dvdnav_menu_available(dvdnav_t *self, DVDMenuID_t menu);
DVDNAV_API dvdnav_status_t dvdnav_time_search_floor(dvdnav_t *self, uint64_t time);
"""
# Insert before the common trailing include guard / end of public API.
needle = "#ifdef __cplusplus\n}\n#endif"
if needle in t:
    t = t.replace(needle, block + "\n" + needle, 1)
else:
    t = t.rstrip() + "\n" + block
p.write_text(t, encoding="utf-8")
print("ok patched dvdnav.h for mpv tip APIs")
PY

  python3 - "$PREFIX/include/libbluray/bluray.h" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text(encoding="utf-8")
marker = "KOTV_FONGMI_BLURAY_COMPAT"
if marker in t:
    print("ok bluray.h already has mpv tip compat decls")
    raise SystemExit(0)
block = f"""
/* {marker}: symbols required by our mpv tip before VideoLAN ships them. */
BD_PUBLIC int bd_seek_time_checked(BLURAY *bd, uint64_t tick);
BD_PUBLIC uint32_t bd_get_titles_with_menu_info(BLURAY *bd, uint8_t flags,
                                                 uint32_t min_title_length,
                                                 int *has_interactive_graphics);
"""
needle = "#ifdef __cplusplus\n}\n#endif"
if needle in t:
    t = t.replace(needle, block + "\n" + needle, 1)
else:
    t = t.rstrip() + "\n" + block
p.write_text(t, encoding="utf-8")
print("ok patched bluray.h for mpv tip APIs")
PY
}

install_fongmi_iso_compat
iso_fongmi_apis_ok || { echo "ERROR: mpv tip ISO API compat missing after install" >&2; exit 1; }

pc --exists dvdread
pc --exists dvdnav
pc --exists libbluray
echo "iso-libs ${DVDREAD_VER}/${DVDNAV_VER}/${BLURAY_VER} + mpv-tip-compat" >"$STAMP"
echo "ok ISO libs: dvdread $(pc --modversion dvdread) dvdnav $(pc --modversion dvdnav) libbluray $(pc --modversion libbluray) (mpv tip API compat)"
