#!/usr/bin/env bash
# 群晖 SPK 引擎：用 DSM Toolkit GCC + sysroot 做 CGO 全静态链接（依赖也走工具链，不用宿主/musl）。
# 用法: ./scripts/synology/build-engine.sh <geminilake|rtd1296> [out-path]
#
# go: -trimpath -ldflags="-s -w … -linkmode external -extldflags '-static …'"
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=common.sh
source "$ROOT/scripts/synology/common.sh"
# shellcheck source=../kotv-release-name.sh
source "$ROOT/scripts/kotv-release-name.sh"
kotv_syno_load_versions

PLATFORM="${1:?usage: build-engine.sh <geminilake|rtd1296> [out]}"
read -r ARCH_LABEL GOARCH _TARGET <<<"$(kotv_syno_plat_meta "$PLATFORM")"
OUT="${2:-$ROOT/dist/syno-engine-${ARCH_LABEL}/kotv-engine}"
ENV_DIR="$(kotv_syno_env_dir "$PLATFORM")"

if [[ ! -d "$ENV_DIR" ]]; then
  "$ROOT/scripts/synology/deploy-toolkit.sh" "$PLATFORM"
fi
kotv_syno_export_toolchain "$ENV_DIR"

VERSION="$(kotv_release_version "$ROOT/flutter/pubspec.yaml")"
VER_LD="$(kotv_engine_version_ldflags "$VERSION")"
mkdir -p "$(dirname "$OUT")"

# 静态链：extld 必须是 Toolkit 的 gcc，并带同一 sysroot（勿混宿主 libc）
EXTLD_STATIC="-static --sysroot=${SYSROOT}"
# libstdc++/libgcc 也尽量静态，避免运行时再找 DSM 上没有的 .so
if [[ -x "$CXX" ]]; then
  EXTLD_STATIC="${EXTLD_STATIC} -static-libstdc++ -static-libgcc"
fi

echo "==> Synology Toolkit static engine $PLATFORM ($ARCH_LABEL / GOARCH=$GOARCH)"
echo "    CC=$CC SYSROOT=$SYSROOT → $OUT"
(cd "$ROOT/internal/spider" && go run gen_qjsinc.go)
(
  cd "$ROOT"
  export CGO_ENABLED=1
  export GOOS=linux
  export GOARCH="$GOARCH"
  export CC
  export CXX
  export AR
  export CGO_CFLAGS="--sysroot=${SYSROOT} -O2 -pipe"
  export CGO_CPPFLAGS="--sysroot=${SYSROOT}"
  export CGO_CXXFLAGS="--sysroot=${SYSROOT} -O2 -pipe"
  export CGO_LDFLAGS="--sysroot=${SYSROOT} -static -static-libstdc++ -static-libgcc"
  go build -trimpath -buildvcs=false \
    -ldflags "-s -w ${VER_LD} -linkmode external -extldflags '${EXTLD_STATIC}'" \
    -o "$OUT" ./cmd/engine
)
chmod +x "$OUT"
file "$OUT" || true
kotv_syno_assert_static_engine "$OUT"
ls -lh "$OUT"
echo "$OUT"
