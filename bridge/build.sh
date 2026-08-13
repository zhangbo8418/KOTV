#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

require_java_17() {
  local version
  version="$(java -version 2>&1 | awk -F '[\".]' '/version/ { print $2; exit }')"
  if [[ -z "$version" || "$version" -lt 17 ]]; then
    echo "ERROR: bridge requires JDK 17 or newer (found: ${version:-missing})" >&2
    exit 1
  fi
}

bootstrap_wrapper() {
  local gradle_version="8.10.2"
  local cache="${GRADLE_BOOTSTRAP_DIR:-$ROOT/.gradle-bootstrap}"
  local zip="$cache/gradle-${gradle_version}-bin.zip"
  local home="$cache/gradle-${gradle_version}"
  mkdir -p "$cache"
  if [[ ! -x "$home/bin/gradle" ]]; then
    if [[ -f "$zip" ]] && ! unzip -tqq "$zip" >/dev/null 2>&1; then
      rm -f "$zip"
    fi
    if [[ ! -f "$zip" ]]; then
      echo "[bridge] downloading Gradle ${gradle_version}..."
      curl --fail --location --retry 3 \
        "https://services.gradle.org/distributions/gradle-${gradle_version}-bin.zip" -o "$zip"
    fi
    unzip -q -o "$zip" -d "$cache"
  fi
  "$home/bin/gradle" --no-daemon wrapper --gradle-version "$gradle_version" --distribution-type bin
}

require_java_17
export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:-} -Dfile.encoding=UTF-8"
export GRADLE_OPTS="${GRADLE_OPTS:-} -Dfile.encoding=UTF-8"

if [[ ! -x ./gradlew || ! -f ./gradle/wrapper/gradle-wrapper.jar ]]; then
  bootstrap_wrapper
fi

./gradlew --no-daemon shadowJar
cp -f build/libs/spider-bridge.jar spider-bridge.jar
echo "Built $ROOT/spider-bridge.jar"
