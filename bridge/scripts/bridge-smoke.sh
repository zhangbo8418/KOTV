#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JAR="$ROOT/spider-bridge.jar"

if [[ ! -f "$JAR" ]]; then
  echo "ERROR: missing $JAR; run ./bridge/build.sh first" >&2
  exit 1
fi

result="$(java -jar "$JAR" --self-check)"
printf '%s\n' "$result"
[[ "$result" == *'"ok":true'* ]]
