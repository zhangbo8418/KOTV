#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JAR="$ROOT/spider-bridge.jar"
REPO="$(cd "$ROOT/.." && pwd)"

if [[ ! -f "$JAR" ]]; then
  echo "ERROR: missing $JAR; run ./bridge/build.sh first" >&2
  exit 1
fi

# 优先用捆绑 JRE（与发行包一致，通常是 21）；避免本机 java 17 跑不动 class 65。
JAVA_BIN="java"
if [[ -x "$REPO/runtime/jre/bin/java" ]]; then
  JAVA_BIN="$REPO/runtime/jre/bin/java"
elif [[ -x "$REPO/runtime/jre/bin/java.exe" ]]; then
  JAVA_BIN="$REPO/runtime/jre/bin/java.exe"
fi

result="$("$JAVA_BIN" -jar "$JAR" --self-check)"
printf '%s\n' "$result"
[[ "$result" == *'"ok":true'* ]]
