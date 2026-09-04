#!/usr/bin/env bash
# 将自带 libmpv 打进桌面应用包，供 media_kit 加载；位置与 fvp/mdk 相同（不进 runtime、不单独建 libmpv/ 目录）。
#   Windows：与 kotv.exe / mdk.dll 同目录（整包 DLL + verify-windows-mpv-bundle 闭包）
#   Linux：bundle/lib/ + 非 OS .so 依赖，RUNPATH=$ORIGIN（避免缺库 / 与系统混载）
#   macOS：Contents/Frameworks/ + 非系统 dylib，清掉 Homebrew/Xcode LC_RPATH
# 用法: bundle-app-libmpv.sh <KO影视.app | linux/win install dir>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-}"
if [[ -z "$DEST" ]]; then
  echo "usage: $0 <app-bundle-or-install-dir>" >&2
  exit 1
fi
chmod +x "$ROOT/scripts/fetch-desktop-mpv-libs.sh"
"$ROOT/scripts/fetch-desktop-mpv-libs.sh"

strip_runtime_libmpv() {
  rm -rf "$DEST/libmpv" "$DEST/runtime/libmpv" \
    "$DEST/Contents/Resources/runtime/libmpv" 2>/dev/null || true
}

# macOS：把 libmpv 及其 Homebrew/前缀依赖收进 Frameworks，并改成 @rpath。
# 否则发行包在无 Homebrew 的机器上会 CREATE_FAILED（缺 _pl_* / libplacebo）。
# 还必须删掉 Homebrew/Xcode 的 LC_RPATH：否则 @rpath 会先解析到 Cellar，
# 与 Frameworks 内拷贝混载两套同名 dylib → SIGABRT（本机起播崩溃即此因）。
kotv_macos_is_system_dylib() {
  case "$1" in
    /System/*|/usr/lib/*|/usr/lib/swift/*) return 0 ;;
    @rpath/*|@loader_path/*|@executable_path/*) return 0 ;;
  esac
  return 1
}

# brew 升级后旧 soname 会消失（如 libbluray.3 → libbluray.4）；尽量解析到现装 dylib。
kotv_macos_resolve_dylib_path() {
  local dep="$1"
  [[ -n "$dep" ]] || return 1
  [[ -f "$dep" ]] && { printf '%s\n' "$dep"; return 0; }

  local base="${dep##*/}"
  local pkg=""
  case "$dep" in
    /usr/local/opt/*)
      pkg="${dep#/usr/local/opt/}"
      pkg="${pkg%%/*}"
      ;;
    /opt/homebrew/opt/*)
      pkg="${dep#/opt/homebrew/opt/}"
      pkg="${pkg%%/*}"
      ;;
  esac
  if [[ -n "$pkg" ]] && command -v brew >/dev/null; then
    local brew_lib
    brew_lib="$(brew --prefix "$pkg" 2>/dev/null)/lib"
    if [[ -f "$brew_lib/$base" ]]; then
      printf '%s\n' "$brew_lib/$base"
      return 0
    fi
    if [[ "$base" =~ ^(.+\.)[0-9]+\.dylib$ ]]; then
      local stem="${BASH_REMATCH[1]}"
      local cand
      for cand in "$brew_lib/${stem}"*.dylib; do
        [[ -f "$cand" ]] || continue
        printf '%s\n' "$cand"
        return 0
      done
    fi
  fi
  return 1
}

kotv_macos_list_rpaths() {
  otool -l "$1" 2>/dev/null | awk '
    $1 == "cmd" && $2 == "LC_RPATH" { want = 1; next }
    want && $1 == "cmdsize" { next }
    want && $1 == "path" { print $2; want = 0 }
  '
}

kotv_macos_strip_abs_rpaths() {
  local lib="$1"
  local path has_loader=0
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    case "$path" in
      @loader_path)
        has_loader=1
        ;;
      @executable_path|@rpath)
        ;;
      /*)
        echo "  - rpath $path ($(basename "$lib"))"
        install_name_tool -delete_rpath "$path" "$lib" 2>/dev/null || true
        ;;
    esac
  done < <(kotv_macos_list_rpaths "$lib")
  if [[ "$has_loader" != 1 ]]; then
    install_name_tool -add_rpath "@loader_path" "$lib" 2>/dev/null || true
  fi
}

kotv_macos_bundle_dylib_deps() {
  local fw="$1"
  local root_lib="$2"
  local -a queue=()
  local lib dep base dest_lib old_id f resolved r seen_blob=$'\n'
  [[ -f "$root_lib" ]] || return 1
  command -v otool >/dev/null || return 1
  command -v install_name_tool >/dev/null || return 1

  install_name_tool -id "@rpath/$(basename "$root_lib")" "$root_lib" 2>/dev/null || true
  kotv_macos_strip_abs_rpaths "$root_lib"
  queue+=("$root_lib")
  seen_blob="${seen_blob}${root_lib}"$'\n'

  while ((${#queue[@]} > 0)); do
    lib="${queue[0]}"
    queue=("${queue[@]:1}")
    while IFS= read -r dep; do
      [[ -n "$dep" ]] || continue
      base="$(basename "$dep")"
      # @rpath 已在 Frameworks：改写后仍要继续走依赖（否则 curl→ssl 闭包断）
      if [[ "$dep" == @rpath/* || "$dep" == @loader_path/* || "$dep" == @executable_path/* ]]; then
        if [[ -f "$fw/$base" ]]; then
          install_name_tool -change "$dep" "@rpath/$base" "$lib" 2>/dev/null || true
          if [[ "$seen_blob" != *$'\n'"$fw/$base"$'\n'* ]]; then
            seen_blob="${seen_blob}${fw}/${base}"$'\n'
            queue+=("$fw/$base")
          fi
        fi
        continue
      fi
      kotv_macos_is_system_dylib "$dep" && continue
      resolved="$dep"
      if [[ ! -f "$resolved" ]]; then
        if r="$(kotv_macos_resolve_dylib_path "$dep" 2>/dev/null)" && [[ -f "$r" ]]; then
          resolved="$r"
          base="$(basename "$resolved")"
        elif [[ -f "$fw/$base" ]]; then
          install_name_tool -change "$dep" "@rpath/$base" "$lib" 2>/dev/null || true
          if [[ "$seen_blob" != *$'\n'"$fw/$base"$'\n'* ]]; then
            seen_blob="${seen_blob}${fw}/${base}"$'\n'
            queue+=("$fw/$base")
          fi
          continue
        else
          echo "WARN: missing dylib dep: $dep (from $(basename "$lib"))" >&2
          continue
        fi
      fi
      dest_lib="$fw/$base"
      if [[ ! -f "$dest_lib" ]]; then
        cp -f "$resolved" "$dest_lib"
        chmod u+w "$dest_lib" 2>/dev/null || true
        install_name_tool -id "@rpath/$base" "$dest_lib" 2>/dev/null || true
        kotv_macos_strip_abs_rpaths "$dest_lib"
        queue+=("$dest_lib")
        seen_blob="${seen_blob}${dest_lib}"$'\n'
        echo "  + Frameworks/$base"
      elif [[ "$seen_blob" != *$'\n'"$dest_lib"$'\n'* ]]; then
        seen_blob="${seen_blob}${dest_lib}"$'\n'
        queue+=("$dest_lib")
      fi
      install_name_tool -change "$dep" "@rpath/$base" "$lib" 2>/dev/null || true
      old_id="$(otool -D "$dest_lib" 2>/dev/null | tail -1 | tr -d '[:space:]' || true)"
      if [[ -n "$old_id" && "$old_id" != "@rpath/$base" ]]; then
        install_name_tool -change "$old_id" "@rpath/$base" "$lib" 2>/dev/null || true
      fi
    done < <(otool -L "$lib" 2>/dev/null | awk 'NR>1 {print $1}')
  done

  # 已存在的拷贝也清掉 Homebrew/Xcode rpath，并把残留绝对依赖改成 @rpath
  for f in "$fw"/libmpv.dylib "$fw"/lib*.dylib; do
    [[ -f "$f" ]] || continue
    chmod u+w "$f" 2>/dev/null || true
    kotv_macos_strip_abs_rpaths "$f"
    while IFS= read -r dep; do
      [[ -n "$dep" ]] || continue
      kotv_macos_is_system_dylib "$dep" && continue
      [[ -f "$dep" ]] || continue
      base="$(basename "$dep")"
      [[ -f "$fw/$base" ]] || continue
      install_name_tool -change "$dep" "@rpath/$base" "$f" 2>/dev/null || true
    done < <(otool -L "$f" 2>/dev/null | awk 'NR>1 {print $1}')
  done
}

kotv_macos_copy_prefix_libplacebo() {
  local fw="$1"
  local prefix="${KOTV_MPV_PREFIX:-$ROOT/.build/desktop-mpv/prefix}"
  local f base resolved
  shopt -s nullglob
  for f in "$prefix/lib"/libplacebo*.dylib; do
    [[ -e "$f" ]] || continue
    # 跟随 symlink，避免把指向 Cellar 的链接原样拷进 Frameworks。
    resolved="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$f" 2>/dev/null || echo "$f")"
    [[ -f "$resolved" ]] || continue
    base="$(basename "$f")"
    cp -f "$resolved" "$fw/$base"
    chmod u+w "$fw/$base" 2>/dev/null || true
    install_name_tool -id "@rpath/$base" "$fw/$base" 2>/dev/null || true
    kotv_macos_strip_abs_rpaths "$fw/$base"
    echo "  + Frameworks/$base (prefix)"
    # 收齐其非系统依赖并改成 @rpath（防御仍链到 Homebrew 的旧拷贝）。
    kotv_macos_bundle_dylib_deps "$fw" "$fw/$base"
  done
  shopt -u nullglob
}

kotv_macos_verify_libmpv_self_contained() {
  local fw lib="$1"
  local bad=0
  local dep path f
  fw="$(dirname "$lib")"
  if strings "$lib" 2>/dev/null | grep -q 'AVFFrameReceiver'; then
    echo "ERROR: libmpv still contains AVFFrameReceiver (rebuild with -Dlibavdevice=disabled)" >&2
    bad=1
  fi
  if strings "$lib" 2>/dev/null | grep -q 'libavdevice license'; then
    echo "ERROR: libmpv still embeds libavdevice (conflicts with mdk libffmpeg in-process)" >&2
    bad=1
  fi
  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    case "$dep" in
      /usr/local/*|/opt/homebrew/*|/Users/*)
        echo "ERROR: libmpv still links absolute path: $dep" >&2
        bad=1
        ;;
    esac
  done < <(otool -L "$lib" 2>/dev/null | awk 'NR>1 {print $1}')
  for f in "$fw"/libmpv.dylib "$fw"/lib*.dylib; do
    [[ -f "$f" ]] || continue
    while IFS= read -r path; do
      case "$path" in
        /usr/local/*|/opt/homebrew/*|/Users/*|/Applications/Xcode.app/*)
          echo "ERROR: $(basename "$f") still has absolute rpath: $path" >&2
          bad=1
          ;;
      esac
    done < <(kotv_macos_list_rpaths "$f")
    while IFS= read -r dep; do
      case "$dep" in
        /usr/local/*|/opt/homebrew/*|/Users/*)
          echo "ERROR: $(basename "$f") still links absolute path: $dep" >&2
          bad=1
          ;;
      esac
    done < <(otool -L "$f" 2>/dev/null | awk 'NR>1 {print $1}')
  done
  [[ "$bad" == 0 ]] || return 1
  # 无 Homebrew 路径时也应能 dlopen（依赖已在同目录 @rpath）
  if command -v python3 >/dev/null; then
    (cd "$(dirname "$lib")" && python3 - <<PY
import ctypes, os, sys
os.chdir(r"""$(dirname "$lib")""")
# 阻断 fallback 到 /usr/local，确认只靠 Frameworks
os.environ["DYLD_FALLBACK_LIBRARY_PATH"] = "/usr/lib"
os.environ.pop("DYLD_LIBRARY_PATH", None)
try:
    ctypes.CDLL(r"""$lib""")
except OSError as e:
    print("ERROR: dlopen Frameworks/libmpv.dylib failed:", e, file=sys.stderr)
    sys.exit(1)
print("ok dlopen Frameworks/libmpv.dylib")
PY
)
  fi
}

# mdk/fvp 自带 /usr/local/lib、/opt/homebrew/lib rpath 时，会优先加载 Cellar FFmpeg，
# 与 libmpv 内嵌 FFmpeg 的同名 ObjC 类（AVFFrameReceiver）冲突 → talloc canary SIGABRT。
kotv_macos_strip_homebrew_rpaths_tree() {
  local fw="$1"
  local f path
  [[ -d "$fw" ]] || return 0
  while IFS= read -r -d '' f; do
    chmod u+w "$f" 2>/dev/null || true
    while IFS= read -r path; do
      case "$path" in
        /usr/local/*|/opt/homebrew/*|/Users/*)
          echo "  - rpath $path ($(basename "$f"))"
          install_name_tool -delete_rpath "$path" "$f" 2>/dev/null || true
          ;;
      esac
    done < <(kotv_macos_list_rpaths "$f")
  done < <(find "$fw" \( -name '*.dylib' -o -name 'mdk' -o -name 'fvp' \) -type f -print0 2>/dev/null)
}

# install_name_tool / cp 会清掉 dylib 签名；macOS 15+ dlopen 未签名库 → Code Signature Invalid (SIGKILL)。
kotv_macos_adhoc_sign_app() {
  local app="$1"
  local fw="$app/Contents/Frameworks"
  local f
  command -v codesign >/dev/null || {
    echo "WARN: codesign missing; bundled dylibs may fail dlopen on macOS 15+" >&2
    return 0
  }
  [[ -d "$fw" ]] || return 0
  echo "==> ad-hoc sign bundled Frameworks (libmpv + deps)"
  while IFS= read -r -d '' f; do
    codesign --force --sign - "$f" 2>/dev/null || true
  done < <(find "$fw" -name '*.dylib' -type f -print0 2>/dev/null)
  while IFS= read -r -d '' f; do
    codesign --force --sign - "$f" 2>/dev/null || true
  done < <(find "$fw" -name '*.framework' -type d -print0 2>/dev/null)
  codesign --force --deep --sign - "$app" 2>/dev/null || true
  if ! codesign -vv "$fw/libmpv.dylib" >/dev/null 2>&1; then
    echo "ERROR: libmpv.dylib still unsigned after codesign" >&2
    return 1
  fi
}

# Linux：只拷 libmpv.so.2 会在干净机器上缺 libplacebo/ffmpeg/libass；
# 或与系统同名 .so 混载（类 macOS Homebrew rpath 问题）。收齐依赖并设 $ORIGIN。
kotv_linux_is_os_so() {
  local base
  base="$(basename "$1")"
  case "$base" in
    ld-linux*.so*|libc.so*|libm.so*|libdl.so*|libpthread.so*|librt.so*|libresolv.so*| \
    libgcc_s.so*|libstdc++.so*|libgomp.so*) return 0 ;;
    libX*.so*|libxcb*.so*|libwayland*.so*|libxkbcommon*.so*|libEGL.so*|libGL.so*|libGLESv*| \
    libGLdispatch*|libGLX*|libOpenGL*|libvulkan.so*|libdrm.so*|libgbm.so*|libasound.so*| \
    libpulse*.so*|libpipewire*.so*|libjack.so*|libva*.so*|libvdpau.so*|libSDL2*.so*| \
    libcaca.so*|libsixel.so*|libudev.so*|libffi.so*|libbsd.so*|libmd.so*|libdbus*.so*| \
    libsystemd.so*|libselinux.so*|libcap.so*|libz.so*|liblzma.so*|libbz2.so*|liblz4.so*| \
    libgpg-error.so*|libgcrypt.so*|libnss*.so*|libnspr*.so*|libpcre*.so*) return 0 ;;
  esac
  return 1
}

kotv_linux_set_origin_rpath() {
  local so="$1"
  if command -v patchelf >/dev/null 2>&1; then
    patchelf --set-rpath '$ORIGIN' "$so" 2>/dev/null || true
  fi
}

kotv_linux_resolve_soname() {
  local soname="$1"
  local dir
  for dir in \
    "${KOTV_MPV_PREFIX:-$ROOT/.build/desktop-mpv/prefix}/lib" \
    "/usr/local/lib" \
    "/usr/lib/x86_64-linux-gnu" \
    "/lib/x86_64-linux-gnu"; do
    [[ -f "$dir/$soname" ]] && { printf '%s\n' "$dir/$soname"; return 0; }
  done
  return 1
}

kotv_linux_bundle_so_deps() {
  local libdir="$1"
  local root_so="$2"
  local -a queue=()
  local so line path base dest soname
  [[ -f "$root_so" ]] || return 1
  kotv_linux_set_origin_rpath "$root_so"
  queue+=("$root_so")

  while ((${#queue[@]} > 0)); do
    so="${queue[0]}"
    queue=("${queue[@]:1}")
    if ! command -v ldd >/dev/null 2>&1; then
      echo "WARN: ldd missing; cannot harvest linux libmpv deps" >&2
      return 0
    fi
    while IFS= read -r line; do
      # "libfoo.so.1 => /path/libfoo.so.1 (0x...)" or "libfoo.so.1 => not found"
      soname="$(printf '%s\n' "$line" | awk '{print $1}')"
      path="$(printf '%s\n' "$line" | awk '/=>/{print $3}')"
      if [[ -z "$path" || "$path" == "not" ]]; then
        path="$(kotv_linux_resolve_soname "$soname" || true)"
        [[ -n "$path" ]] || continue
      fi
      [[ -f "$path" ]] || continue
      kotv_linux_is_os_so "$path" && continue
      base="$(basename "$path")"
      dest="$libdir/$base"
      if [[ ! -f "$dest" ]]; then
        cp -f "$path" "$dest"
        chmod u+w "$dest" 2>/dev/null || true
        kotv_linux_set_origin_rpath "$dest"
        queue+=("$dest")
        echo "  + lib/$base"
      fi
    done < <(ldd "$so" 2>/dev/null || true)
  done
}

kotv_linux_verify_libmpv_self_contained() {
  local libdir="$1"
  local so="$libdir/libmpv.so.2"
  local bad=0 line path
  [[ -f "$so" ]] || return 1
  # 至少要有 placebo / ass（发行包硬依赖）
  if ! find "$libdir" -maxdepth 1 -name 'libplacebo.so*' | grep -q .; then
    echo "ERROR: missing libplacebo next to libmpv (linux bundle incomplete)" >&2
    bad=1
  fi
  if ! find "$libdir" -maxdepth 1 -name 'libass.so*' | grep -q .; then
    echo "ERROR: missing libass next to libmpv (linux bundle incomplete)" >&2
    bad=1
  fi
  if command -v ldd >/dev/null 2>&1; then
    while IFS= read -r line; do
      if printf '%s\n' "$line" | grep -q 'not found'; then
        echo "ERROR: unresolved dep: $line" >&2
        bad=1
      fi
    done < <(ldd "$so" 2>/dev/null || true)
  fi
  [[ "$bad" == 0 ]] || return 1
}

case "$(uname -s)" in
  Darwin)
    MPV="$ROOT/flutter/assets/mpv-libs/macos/libmpv.dylib"
    [[ -f "$MPV" ]] || { echo "ERROR: missing $MPV (fetch-desktop-mpv-libs failed)" >&2; exit 1; }
    FW="$DEST/Contents/Frameworks"
    mkdir -p "$FW"
    cp -f "$MPV" "$FW/libmpv.dylib"
    chmod u+w "$FW/libmpv.dylib" 2>/dev/null || true
    echo "==> bundle macOS libmpv + dylib deps into Frameworks"
    kotv_macos_bundle_dylib_deps "$FW" "$FW/libmpv.dylib"
    kotv_macos_copy_prefix_libplacebo "$FW"
    # Vulkan loader + MoltenVK ICD + curl/OpenSSL/ng*（与 libmpv 同目录 @rpath）
    ASSET_MAC="$ROOT/flutter/assets/mpv-libs/macos"
    for f in libvulkan.1.dylib libvulkan.dylib libMoltenVK.dylib \
             libcurl.4.dylib libcurl.dylib \
             libssl.3.dylib libcrypto.3.dylib \
             libnghttp2.dylib libnghttp3.dylib libngtcp2.dylib; do
      [[ -f "$ASSET_MAC/$f" ]] || continue
      cp -f "$ASSET_MAC/$f" "$FW/$f"
      chmod u+w "$FW/$f" 2>/dev/null || true
      install_name_tool -id "@rpath/$f" "$FW/$f" 2>/dev/null || true
      kotv_macos_strip_abs_rpaths "$FW/$f"
      echo "  + Frameworks/$f (asset)"
    done
    # 再扫一遍 assets 里其余 network dylib（版本化 soname）
    shopt -s nullglob
    for f in "$ASSET_MAC"/libcurl*.dylib "$ASSET_MAC"/libssl*.dylib "$ASSET_MAC"/libcrypto*.dylib \
             "$ASSET_MAC"/libnghttp*.dylib "$ASSET_MAC"/libngtcp2*.dylib; do
      base="$(basename "$f")"
      [[ -f "$FW/$base" ]] && continue
      cp -f "$f" "$FW/$base"
      chmod u+w "$FW/$base" 2>/dev/null || true
      install_name_tool -id "@rpath/$base" "$FW/$base" 2>/dev/null || true
      kotv_macos_strip_abs_rpaths "$FW/$base"
      echo "  + Frameworks/$base (network)"
    done
    shopt -u nullglob
    # 再次收依赖：把 Frameworks 内拷贝的绝对路径改成 @rpath
    kotv_macos_bundle_dylib_deps "$FW" "$FW/libmpv.dylib"
    if [[ -f "$ASSET_MAC/vulkan/icd.d/MoltenVK_icd.json" ]]; then
      mkdir -p "$DEST/Contents/Resources/vulkan/icd.d"
      # ICD 里 library_path 用绝对 @rpath 旁的文件名；运行时由 VK_ICD_FILENAMES 指向此 json
      cat >"$DEST/Contents/Resources/vulkan/icd.d/MoltenVK_icd.json" <<EOF
{
  "file_format_version": "1.0.0",
  "ICD": {
    "library_path": "$FW/libMoltenVK.dylib",
    "api_version": "1.3.0"
  }
}
EOF
      echo "  + Resources/vulkan/icd.d/MoltenVK_icd.json"
    fi
    echo "==> strip Homebrew rpaths from Frameworks (mdk/fvp/libmpv)"
    kotv_macos_strip_homebrew_rpaths_tree "$FW"
    kotv_macos_verify_libmpv_self_contained "$FW/libmpv.dylib"
    if [[ "${KOTV_MACOS_NO_FVP:-0}" == "1" ]]; then
      rm -rf "$FW/fvp.framework" "$FW/mdk.framework" 2>/dev/null || true
      echo "  - removed fvp/mdk.framework (MPV-only macOS)"
    fi
    kotv_macos_adhoc_sign_app "$DEST"
    strip_runtime_libmpv
    echo "bundled macOS Frameworks/libmpv.dylib (+ deps)"
    ;;
  Linux)
    MPV="$ROOT/flutter/assets/mpv-libs/linux/libmpv.so.2"
    [[ -f "$MPV" ]] || { echo "ERROR: missing $MPV" >&2; exit 1; }
    mkdir -p "$DEST/lib"
    cp -f "$MPV" "$DEST/lib/libmpv.so.2"
    chmod u+w "$DEST/lib/libmpv.so.2" 2>/dev/null || true
    echo "==> bundle linux libmpv + .so deps into lib/ (\$ORIGIN)"
    kotv_linux_bundle_so_deps "$DEST/lib" "$DEST/lib/libmpv.so.2"
    kotv_linux_verify_libmpv_self_contained "$DEST/lib"
    strip_runtime_libmpv
    echo "bundled linux lib/libmpv.so.2 (+ deps)"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    SRC="$ROOT/flutter/assets/mpv-libs/windows"
    [[ -f "$SRC/mpv-2.dll" || -f "$SRC/libmpv-2.dll" ]] || {
      echo "ERROR: missing windows libmpv dll" >&2
      exit 1
    }
    mkdir -p "$DEST"
    # 与 mdk.dll 同目录；闭包由 verify-windows-mpv-bundle 门禁。
    # libmpv 单独以 libmpv-2.dll 安装（覆盖 media_kit_libs 预编译），勿再留 mpv-2.dll。
    if [[ -d "$SRC" ]]; then
      while IFS= read -r -d '' f; do
        base="$(basename "$f")"
        case "$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')" in
          mpv-2.dll|libmpv-2.dll) continue ;;
        esac
        cp -f "$f" "$DEST/$base"
      done < <(find "$SRC" -maxdepth 1 -type f \( -iname '*.dll' -o -iname '*.pdb' \) -print0)
    fi
    if [[ -f "$SRC/mpv-2.dll" ]]; then
      cp -f "$SRC/mpv-2.dll" "$DEST/libmpv-2.dll"
    elif [[ -f "$SRC/libmpv-2.dll" ]]; then
      cp -f "$SRC/libmpv-2.dll" "$DEST/libmpv-2.dll"
    fi
    rm -f "$DEST/mpv-2.dll"
    strip_runtime_libmpv
    [[ -f "$DEST/libmpv-2.dll" ]] || {
      echo "ERROR: libmpv-2.dll not next to exe" >&2
      exit 1
    }
    staged="$(find "$SRC" -maxdepth 1 -type f -iname '*.dll' | wc -l | tr -d ' ')"
    echo "bundled windows libmpv-2.dll next to exe (assets dlls=$staged)"
    find "$SRC" -maxdepth 1 -type f -iname '*.dll' -printf '  asset %f\n' 2>/dev/null \
      || find "$SRC" -maxdepth 1 -type f -iname '*.dll' | sed 's|.*/||;s|^|  asset |'
    ;;
  *)
    echo "skip bundle-app-libmpv on $(uname -s)" >&2
    ;;
esac
