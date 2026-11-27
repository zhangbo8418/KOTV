#!/usr/bin/env bash
# 部署 Synology DSM 7.2 Toolkit（pkgscripts-ng + EnvDeploy）
# 用法: ./scripts/synology/deploy-toolkit.sh <geminilake|rtd1296>
# 缓存目录: $KOTV_TOOLKIT_ROOT（默认仓库 .toolkit/）
#
# GitHub Actions 等无特权环境解 base_env 会因 mknod 失败；此时在 privileged
# Docker 内跑 EnvDeploy（与官方/社区用法一致）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=common.sh
source "$ROOT/scripts/synology/common.sh"
kotv_syno_load_versions

PLATFORM="${1:?usage: deploy-toolkit.sh <geminilake|rtd1296>}"
kotv_syno_plat_meta "$PLATFORM" >/dev/null

TOOLKIT_ROOT="$(kotv_syno_toolkit_root)"
PKGSCRIPT="$TOOLKIT_ROOT/pkgscripts-ng"
DSM_VER="${SYNO_DSM_VER}"
ENV_DIR="$(kotv_syno_env_dir "$PLATFORM")"
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

if [[ "${KOTV_SYNO_FORCE_DEPLOY:-}" != "1" ]] \
  && [[ -d "$ENV_DIR/usr/local" ]] \
  && find "$ENV_DIR/usr/local" -type f -name '*-gcc' 2>/dev/null | head -1 | grep -q .; then
  echo "==> toolkit env already deployed: $ENV_DIR"
  echo "$ENV_DIR"
  exit 0
fi
# 半成品（例如宿主机 mknod 失败留下的目录）清掉重来
if [[ -d "$ENV_DIR" && "${KOTV_SYNO_FORCE_DEPLOY:-}" == "1" ]]; then
  echo "==> force redeploy: remove $ENV_DIR"
  rm -rf "$ENV_DIR"
elif [[ -d "$ENV_DIR" ]] && ! find "$ENV_DIR/usr/local" -type f -name '*-gcc' 2>/dev/null | head -1 | grep -q .; then
  echo "==> incomplete toolkit env; remove and redeploy"
  rm -rf "$ENV_DIR"
fi

DEPLOY_FLAGS=(-v "$DSM_VER" -p "$PLATFORM")
if ls "$TOOLKIT_ROOT/toolkit_tarballs"/base_env-"${DSM_VER}"*.txz >/dev/null 2>&1 \
  && ls "$TOOLKIT_ROOT/toolkit_tarballs"/ds."${PLATFORM}"-"${DSM_VER}"*.txz >/dev/null 2>&1; then
  DEPLOY_FLAGS+=(-D)
  echo "==> using cached toolkit_tarballs (-D)"
fi

# 布局：TOOLKIT_ROOT/{pkgscripts-ng,build_env,toolkit_tarballs}
mkdir -p "$TOOLKIT_ROOT"
ln -sfn "$TOOLKIT_ROOT/toolkit_tarballs" "$PKGSCRIPT/../toolkit_tarballs" 2>/dev/null || true

use_docker_deploy() {
  # Actions / 显式要求：privileged 容器才能 mknod / mount proc
  if [[ "${KOTV_SYNO_DOCKER_DEPLOY:-}" == "1" ]]; then
    return 0
  fi
  if [[ -n "${GITHUB_ACTIONS:-}" ]] && command -v docker >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

run_envdeploy_host() {
  echo "==> EnvDeploy on host: -v ${DSM_VER} -p ${PLATFORM}"
  (
    cd "$PKGSCRIPT"
    export TOOLKIT_ROOT
    ./EnvDeploy "${DEPLOY_FLAGS[@]}"
  )
}

run_envdeploy_docker() {
  local img="${KOTV_SYNO_DEPLOY_IMAGE:-ubuntu:22.04}"
  local flags_str
  flags_str="$(printf '%q ' "${DEPLOY_FLAGS[@]}")"
  echo "==> EnvDeploy in privileged Docker ($img): -v ${DSM_VER} -p ${PLATFORM}"
  # shellcheck disable=SC2086
  docker run --rm --privileged \
    -v "$TOOLKIT_ROOT:/toolkit" \
    -w /toolkit/pkgscripts-ng \
    -e TOOLKIT_ROOT=/toolkit \
    "$img" \
    bash -lc "
      set -euo pipefail
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq python3 python3-pip git xz-utils ca-certificates >/dev/null
      ./EnvDeploy ${flags_str}
    "
}

if use_docker_deploy; then
  run_envdeploy_docker
else
  if ! run_envdeploy_host; then
    echo "WARN: host EnvDeploy failed; retry in privileged Docker" >&2
    if ! command -v docker >/dev/null 2>&1; then
      echo "ERROR: EnvDeploy failed and docker unavailable" >&2
      exit 1
    fi
    # 清半成品再进容器
    rm -rf "$ENV_DIR"
    run_envdeploy_docker
  fi
fi

if [[ ! -d "$ENV_DIR" ]]; then
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
