#!/usr/bin/env bash
# 解析 git 仓库 tip / 显式 SHA，供桌面与安卓 MPV/FFmpeg 构建共用。
# 由其它脚本 source；只定义函数，不改动调用方的 set 选项。
# 用法（source 后）：
#   kotv_resolve_git_ref <repo_url> <branch_or_ref> [explicit_sha]
# shellcheck shell=bash

kotv_resolve_git_ref() {
  local repo="${1:?repo}"
  local ref="${2:?ref}"
  local explicit="${3:-}"
  local sha="" out
  if [[ -n "$explicit" ]]; then
    printf '%s\n' "$explicit"
    return 0
  fi
  # 先把 ls-remote 整段收进变量，再 awk。
  # 若管道里 awk 提前 exit，pipefail 下 git 可能 SIGPIPE(141)，赋值失败并被 set -e 静默杀掉。
  # Windows：PATH 上 MinGW 的 git 不可靠，优先 /usr/bin（Git for Windows）。
  local gitbin=git
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
      [[ -x /usr/bin/git ]] && gitbin=/usr/bin/git
      ;;
  esac
  out="$("$gitbin" ls-remote "$repo" "refs/heads/${ref}" 2>/dev/null || true)"
  sha="$(printf '%s\n' "$out" | awk '{print $1; exit}')"
  if [[ -z "$sha" ]]; then
    # 允许传 tag / 完整 ref 名
    out="$("$gitbin" ls-remote "$repo" "$ref" 2>/dev/null || true)"
    sha="$(printf '%s\n' "$out" | awk '{print $1; exit}')"
  fi
  if [[ -z "$sha" ]]; then
    echo "ERROR: cannot resolve $repo $ref (git=$gitbin)" >&2
    return 1
  fi
  printf '%s\n' "$sha"
}

# 检出已 clone 的仓库到指定 commit（浅取）。
# 强制检出：上次构建打的补丁会改动受控文件，不能挡住切换；未跟踪文件（依赖、SDK）保留。
kotv_git_checkout_commit() {
  local dir="${1:?dir}"
  local repo="${2:?repo}"
  local commit="${3:?commit}"
  if [[ ! -d "$dir/.git" ]]; then
    git clone --filter=blob:none --depth 1 "$repo" "$dir"
  fi
  git -C "$dir" fetch --depth 1 origin "$commit" \
    || git -C "$dir" fetch --depth 1 origin "$commit"
  git -C "$dir" checkout -qf "$commit"
  if [[ "$(git -C "$dir" rev-parse HEAD)" != "$commit" ]]; then
    echo "ERROR: $dir HEAD is not $commit after checkout" >&2
    return 1
  fi
}
