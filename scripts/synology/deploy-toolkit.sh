#!/usr/bin/env bash
# 部署 Synology DSM 7.2 Toolkit（pkgscripts-ng + EnvDeploy）
# 用法: ./scripts/synology/deploy-toolkit.sh <braswell|rtd1296>
# 缓存目录: $KOTV_TOOLKIT_ROOT（默认仓库 .toolkit/）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=versions.env
source "$ROOT/scripts/synology/versions.env"

PLATFORM="${1:?usage: deploy-toolkit.sh <braswell|rtd1296>}"
case "$PLATFORM" in
  braswell|rtd1296) ;;
  *) echo "unsupported platform: $PLATFORM (want braswell|rtd1296)" >&2; exit 1 ;;
esac

TOOLKIT_ROOT="${KOTV_TOOLKIT_ROOT:-$ROOT/.toolkit}"
PKGSCRIPT="$TOOLKIT_ROOT/pkgscripts-ng"
DSM_VER="${SYNO_DSM_VER}"
mkdir -p "$TOOLKIT_ROOT/toolkit_tarballs" "$TOOLKIT_ROOT/build_env"

if [[ ! -d "$PKGSCRIPT/.git" ]]; then
  echo "==> clone pkgscripts-ng → $PKGSCRIPT"
  rm -rf "$PKGSCRIPT"
  git clone --depth 1 --branch "DSM${DSM_VER}" \
    https://github.com/SynologyOpenSource/pkgscripts-ng.git "$PKGSCRIPT"
else
  echo "==> pkgscripts-ng present; fetch DSM${DSM_VER}"
  git -C "$PKGSCRIPT" fetch --depth 1 origin "DSM${DSM_VER}" || true
  git -C "$PKGSCRIPT" checkout -B "DSM${DSM_VER}" "origin/DSM${DSM_VER}" 2>/dev/null \
    || git -C "$PKGSCRIPT" checkout "DSM${DSM_VER}"
fi

ENV_DIR="$TOOLKIT_ROOT/build_env/ds.${PLATFORM}-${DSM_VER}"
if [[ -d "$ENV_DIR/usr/local" || -d "$ENV_DIR/usr" ]]; then
  if [[ "${KOTV_SYNO_FORCE_DEPLOY:-}" != "1" ]]; then
    echo "==> toolkit env already deployed: $ENV_DIR"
    echo "$ENV_DIR"
    exit 0
  fi
fi

echo "==> EnvDeploy -v ${DSM_VER} -p ${PLATFORM}"
cd "$PKGSCRIPT"
# 若 tarball 已在 toolkit_tarballs，加 -D 避免重复拉 CDN
DEPLOY_FLAGS=(-v "$DSM_VER" -p "$PLATFORM")
if ls "$TOOLKIT_ROOT/toolkit_tarballs"/base_env-"${DSM_VER}"*.txz >/dev/null 2>&1 \
  && ls "$TOOLKIT_ROOT/toolkit_tarballs"/ds."${PLATFORM}"-"${DSM_VER}"*.txz >/dev/null 2>&1; then
  DEPLOY_FLAGS+=(-D)
  echo "==> using cached toolkit_tarballs (-D)"
fi
# EnvDeploy 把环境装到 pkgscripts-ng 同级的 build_env
mkdir -p "$TOOLKIT_ROOT"
# 布局：TOOLKIT_ROOT/{pkgscripts-ng,build_env,toolkit_tarballs}
export TOOLKIT_ROOT
ln -sfn "$TOOLKIT_ROOT/toolkit_tarballs" "$PKGSCRIPT/../toolkit_tarballs" 2>/dev/null || true
./EnvDeploy "${DEPLOY_FLAGS[@]}"

if [[ ! -d "$ENV_DIR" ]]; then
  # 有些版本落在 pkgscripts-ng/../build_env
  ALT="$(cd "$PKGSCRIPT/.." && pwd)/build_env/ds.${PLATFORM}-${DSM_VER}"
  if [[ -d "$ALT" && "$ALT" != "$ENV_DIR" ]]; then
    mkdir -p "$(dirname "$ENV_DIR")"
    ln -sfn "$ALT" "$ENV_DIR"
  fi
fi

if [[ ! -d "$ENV_DIR" ]]; then
  echo "ERROR: EnvDeploy finished but missing $ENV_DIR" >&2
  ls -la "$TOOLKIT_ROOT/build_env" 2>/dev/null || true
  exit 1
fi

echo "==> deployed: $ENV_DIR"
echo "$ENV_DIR"
