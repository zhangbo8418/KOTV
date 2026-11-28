#!/usr/bin/env bash
# 用已 export 的 Toolkit 工具链，在独立 deps 前缀下编译运行时所需库。
# 由 build-runtime-in-chroot.sh source（需已定义 download，且已有
# PLATFORM / CC / CXX / SYSROOT / CFLAGS / LDFLAGS / SRC_CACHE / BUILD_ROOT）。
# shellcheck shell=bash

kotv_syno_deps_prefix() {
  echo "${KOTV_SYNO_DEPS_PREFIX:-${BUILD_ROOT:?}/toolkit-deps}"
}

kotv_syno_deps_host_triple() {
  case "${PLATFORM:?}" in
    geminilake) echo "x86_64-pc-linux-gnu" ;;
    rtd1296)    echo "aarch64-unknown-linux-gnu" ;;
    *)
      echo "ERROR: unknown PLATFORM=$PLATFORM" >&2
      return 1
      ;;
  esac
}

# 把自建 deps 挂到编译搜索路径；清空 PKG_CONFIG_SYSROOT_DIR，
# 避免再套一层 sysroot 导致双重路径（Toolkit 自带的 libffi.pc 即如此）。
kotv_syno_export_deps_pkgconfig() {
  local deps
  deps="$(kotv_syno_deps_prefix)"
  export PKG_CONFIG_SYSROOT_DIR=""
  export PKG_CONFIG_PATH="${deps}/lib/pkgconfig:${deps}/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
  export CPPFLAGS="-I${deps}/include ${CPPFLAGS:-}"
  export LDFLAGS="-L${deps}/lib -L${deps}/lib64 ${LDFLAGS:-}"
}

# 把 deps 里指定 basename 的 .so* 拷进目标 lib（运行时加载）
kotv_syno_deps_ship_shared() {
  local dest_lib="$1"
  shift
  local deps name
  deps="$(kotv_syno_deps_prefix)"
  mkdir -p "$dest_lib"
  for name in "$@"; do
    cp -a "${deps}/lib/lib${name}.so"* "$dest_lib/" 2>/dev/null || true
    cp -a "${deps}/lib64/lib${name}.so"* "$dest_lib/" 2>/dev/null || true
  done
}

# libffi（静态）→ CPython _ctypes；不依赖 Toolkit sysroot 里损坏的 ffi 布局
kotv_syno_ensure_libffi() {
  kotv_syno_load_versions
  local ver="${SYNO_LIBFFI_VER}"
  local deps stamp tarball src host jobs
  deps="$(kotv_syno_deps_prefix)"
  stamp="$deps/.kotv-dep-libffi"
  if [[ -f "$stamp" && "$(cat "$stamp" 2>/dev/null || true)" == "$ver" ]] \
    && [[ -f "$deps/include/ffi.h" ]] \
    && { [[ -f "$deps/lib/libffi.a" ]] || [[ -f "$deps/lib64/libffi.a" ]]; }; then
    echo "[deps] libffi $ver cache hit → $deps"
    return 0
  fi
  jobs="$(kotv_syno_njobs)"
  host="$(kotv_syno_deps_host_triple)"
  tarball="$SRC_CACHE/libffi-${ver}.tar.gz"
  download \
    "https://github.com/libffi/libffi/releases/download/v${ver}/libffi-${ver}.tar.gz" \
    "$tarball"
  src="$BUILD_ROOT/libffi-${ver}"
  rm -rf "$src"
  tar -xzf "$tarball" -C "$BUILD_ROOT"
  mkdir -p "$deps"
  (
    cd "$src"
    ./configure \
      --prefix="$deps" \
      --host="$host" \
      --disable-docs \
      --disable-multi-os-directory \
      --enable-static \
      --disable-shared \
      CC="$CC" CXX="$CXX" \
      CFLAGS="$CFLAGS" CXXFLAGS="$CXXFLAGS" LDFLAGS="$LDFLAGS"
    make -j"$jobs"
    make install
  )
  echo "$ver" >"$stamp"
  echo "[deps] libffi $ver installed → $deps"
}

# alsa-lib → OpenJDK：configure 不允许 --without-alsa，须提供工具链编的前缀
kotv_syno_ensure_alsa() {
  kotv_syno_load_versions
  local ver="${SYNO_ALSA_VER}"
  local deps stamp tarball src host jobs
  deps="$(kotv_syno_deps_prefix)"
  stamp="$deps/.kotv-dep-alsa"
  if [[ -f "$stamp" && "$(cat "$stamp" 2>/dev/null || true)" == "$ver" ]] \
    && [[ -f "$deps/include/alsa/asoundlib.h" ]]; then
    echo "[deps] alsa-lib $ver cache hit → $deps"
    return 0
  fi
  jobs="$(kotv_syno_njobs)"
  host="$(kotv_syno_deps_host_triple)"
  tarball="$SRC_CACHE/alsa-lib-${ver}.tar.bz2"
  download \
    "https://www.alsa-project.org/files/pub/lib/alsa-lib-${ver}.tar.bz2" \
    "$tarball"
  src="$BUILD_ROOT/alsa-lib-${ver}"
  rm -rf "$src"
  tar -xjf "$tarball" -C "$BUILD_ROOT"
  mkdir -p "$deps"
  (
    cd "$src"
    ./configure \
      --prefix="$deps" \
      --host="$host" \
      --disable-python \
      --disable-alisp \
      --with-sysroot="$SYSROOT" \
      CC="$CC" CXX="$CXX" \
      CFLAGS="$CFLAGS" CXXFLAGS="$CXXFLAGS" LDFLAGS="$LDFLAGS"
    make -j"$jobs"
    make install
  )
  echo "$ver" >"$stamp"
  echo "[deps] alsa-lib $ver installed → $deps"
}
