#!/usr/bin/env bash
# 用 DSM 7.2 Toolkit 编译 kotv-engine（动态链 sysroot glibc，非 musl）。
# 用法: ./scripts/synology/build-engine.sh <geminilake|rtd1296> [out-path]
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

echo "==> Synology engine $PLATFORM ($ARCH_LABEL / GOARCH=$GOARCH) → $OUT"
(cd "$ROOT/internal/spider" && go run gen_qjsinc.go)
(
  cd "$ROOT"
  export CGO_ENABLED=1
  export GOOS=linux
  export GOARCH="$GOARCH"
  # kotv_syno_export_toolchain 已设 CGO_*；此处再钉死，避免宿主头文件污染交叉编
  export CGO_CFLAGS="${CGO_CFLAGS:-$CFLAGS}"
  export CGO_CPPFLAGS="${CGO_CPPFLAGS:---sysroot=${SYSROOT}}"
  export CGO_CXXFLAGS="${CGO_CXXFLAGS:-$CXXFLAGS}"
  export CGO_LDFLAGS="${CGO_LDFLAGS:-$LDFLAGS}"
  go build -buildvcs=false -ldflags "-s -w ${VER_LD}" -o "$OUT" ./cmd/engine
)
chmod +x "$OUT"
file "$OUT" || true
# 必须是动态链 glibc（Toolkit sysroot）。交叉产物上宿主 ldd 会误报「not a dynamic
# executable」，改用 file/readelf（不执行目标二进制）。
_eng_info="$(file -b "$OUT" 2>/dev/null || true)"
case "$_eng_info" in
  *statically\ linked*)
    echo "ERROR: engine is statically linked; Synology SPK 需要 Toolkit 动态链引擎" >&2
    echo "$_eng_info" >&2
    exit 1
    ;;
esac
if [[ "$_eng_info" != *"dynamically linked"* ]]; then
  echo "ERROR: expected dynamically linked engine, got: ${_eng_info:-unknown}" >&2
  exit 1
fi
if [[ "$_eng_info" == *musl* ]]; then
  echo "ERROR: musl-linked engine not allowed for Synology SPK" >&2
  exit 1
fi
if command -v readelf >/dev/null 2>&1; then
  if ! readelf -l "$OUT" 2>/dev/null | grep -q 'INTERP'; then
    echo "ERROR: engine missing INTERP (not a dynamic ELF)" >&2
    exit 1
  fi
  echo "engine dynamic deps (readelf):"
  readelf -d "$OUT" 2>/dev/null | grep -E 'NEEDED|Shared library' | head -20 || true
elif [[ "$GOARCH" == "$(go env GOHOSTARCH 2>/dev/null || true)" ]] \
  && command -v ldd >/dev/null 2>&1; then
  echo "engine dynamic deps:"
  ldd "$OUT" | head -20 || true
fi
unset _eng_info
ls -lh "$OUT"
echo "$OUT"
