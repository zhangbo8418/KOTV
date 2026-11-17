#!/usr/bin/env python3
"""Soft-patch webhtv build_mpv_native.sh mpv shallow-fetch / describe die."""
from __future__ import annotations

import re
import sys
from pathlib import Path


def patch(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    if "embedding lock version $MPV_VERSION" in text and "shallow.lock" in text:
        print("ok webhtv mpv shallow fetch already softened")
        return
    pat = re.compile(
        r'  if \[ "\$\(git -C "\$deps/mpv" describe --abbrev=9 --tags --match "\$MPV_DESCRIBE_TAG" HEAD 2>/dev/null \|\| true\)" != "v\$MPV_VERSION" \]; then\n'
        r".*?"
        r'\n  \[ "\$\(git -C "\$deps/mpv" describe --abbrev=9 --tags --match "\$MPV_DESCRIBE_TAG" HEAD\)" = "v\$MPV_VERSION" \] \|\| die "MPV describe version mismatch"',
        re.M | re.S,
    )
    new = """  if [ "$(git -C "$deps/mpv" describe --abbrev=9 --tags --match "$MPV_DESCRIBE_TAG" HEAD 2>/dev/null || true)" != "v$MPV_VERSION" ]; then
    # deepen 加重试，避免 CI shallow.lock 竞态；仍失败则靠下方 MPV_VERSION 文件。
    _ok=0
    for _try in 1 2 3 4 5 6; do
      rm -f "$deps/mpv/.git/shallow.lock" || true
      if git -C "$deps/mpv" fetch --depth=1 "$MPV_TAG_REPO" \\
          "refs/tags/$MPV_DESCRIBE_TAG:refs/tags/$MPV_DESCRIBE_TAG" \\
        && git -C "$deps/mpv" fetch --depth="$MPV_HISTORY_DEPTH" origin "$MPV_COMMIT" \\
        && [ "$(git -C "$deps/mpv" describe --abbrev=9 --tags --match "$MPV_DESCRIBE_TAG" HEAD 2>/dev/null || true)" = "v$MPV_VERSION" ]; then
        _ok=1
        break
      fi
      sleep "$_try"
    done
    if [ "$_ok" != "1" ]; then
      log "MPV git-describe still mismatched after retries; embedding lock version $MPV_VERSION"
      git -C "$deps/mpv" fetch --unshallow origin 2>/dev/null || true
      git -C "$deps/mpv" fetch --no-tags "$MPV_TAG_REPO" \\
        "refs/tags/$MPV_DESCRIBE_TAG:refs/tags/$MPV_DESCRIBE_TAG" 2>/dev/null || true
    fi
  fi"""
    text2, n = pat.subn(new, text, count=1)
    if n != 1:
        raise SystemExit("ERROR: webhtv mpv shallow-fetch block changed; update KOTV patch")
    path.write_text(text2, encoding="utf-8")
    print("ok patched webhtv mpv shallow fetch + soft describe")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} <build_mpv_native.sh>")
    patch(Path(sys.argv[1]))


if __name__ == "__main__":
    main()
