#!/usr/bin/env bash
# macOS 全功能包：含 FVP/mdk + 内置 MPV（同进程两套 FFmpeg，点播 MPV 可能不稳定）。
# 仅当你需要 FVP 播放器且接受 MPV 与 FVP 二选一时使用；稳定 MPV 请用 package-flutter-macos.sh。
set -euo pipefail
export KOTV_MACOS_NO_FVP=0
exec "$(cd "$(dirname "$0")" && pwd)/package-flutter-macos.sh" "$@"
