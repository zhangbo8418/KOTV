#!/usr/bin/env bash
# 用 DSM 7.2 Toolkit 编译 kotv-engine（动态链 sysroot glibc，非 musl）。
# 用法: ./scripts/synology/build-engine.sh <braswell|rtd1296> [out-path]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=common.sh
source "$ROOT/scripts/synology/common.sh"
# shellcheck source=../kotv-release-name.sh
source "$ROOT/scripts/kotv-release-name.sh"
kotv_syno_load_versions

PLATFORM="${1:?usage: build-engine.sh <braswell|rtd1296> [out]}"
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
  export CGO_CFLAGS="${CFLAGS}"
  export CGO_CXXFLAGS="${CXXFLAGS}"
  export CGO_LDFLAGS="${LDFLAGS}"
  go build -buildvcs=false -ldflags "-s -w ${VER_LD}" -o "$OUT" ./cmd/engine
)
chmod +x "$OUT"
file "$OUT" || true
# 必须是动态链接到 sysroot/glibc 风格，禁止误用 musl 静态包冒充
if command -v ldd >/dev/null 2>&1; then
  if ! ldd "$OUT" >/dev/null 2>&1; then
    echo "ERROR: engine is statically linked; Synology SPK 需要 Toolkit 动态链引擎" >&2
    exit 1
  fi
  echo "engine dynamic deps:"
  ldd "$OUT" | head -20 || true
fi
ls -lh "$OUT"
echo "$OUT"
