#!/usr/bin/env bash
# 按目录整段删掉 APK 里的残留，不留空目录。改过的包重新 zipalign 并签名。
#   tidy-android-apk.sh <apk> <arm64-v8a|armeabi-v7a>
#   tidy-android-apk.sh --check <apk> <abi>
set -euo pipefail
CHECK=0
if [[ "${1:-}" == "--check" ]]; then
  CHECK=1
  shift
fi
APK="${1:-}"
WANT="${2:-}"
if [[ -z "$APK" || ! -f "$APK" || -z "$WANT" ]]; then
  echo "usage: $0 [--check] <apk> <arm64-v8a|armeabi-v7a>" >&2
  exit 1
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

python3 - "$APK" "$WANT" "$WORK/unsigned.apk" "$CHECK" <<'PY'
import re, sys, zipfile
apk, want, out, check_only = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
if want not in ("arm64-v8a", "armeabi-v7a"):
    sys.exit(f"ERROR: unexpected ABI {want}")
others = [a for a in ("arm64-v8a", "armeabi-v7a", "x86", "x86_64") if a != want]
# 整段目录。删掉里面的文件后，目录本身也不再写入。
drop_dirs = [
    "OSGI-INF/",
    "google/",
    "core/",
    "org/bouncycastle/pqc/",
    "assets/flutter_assets/assets/engine/",
    "assets/flutter_assets/packages/wakelock_plus/",
    "META-INF/androidx/",
    "META-INF/com/",
    "META-INF/jsoup/",
]
for abi in others:
    drop_dirs.append(f"lib/{abi}/")
    drop_dirs.append(f"assets/mpv-libs/{abi}/")
    drop_dirs.append(f"assets/chaquopy/bootstrap-native/{abi}/")
drop_res = [
    re.compile(r"^assets/test_.*\.(js|mjs)$"),
    re.compile(r"^XPP3_.*_VERSION$"),
    re.compile(r"^kotlin-tooling-metadata\.json$"),
    re.compile(r"^DebugProbesKt\.bin$"),
    re.compile(r"^r8-version\.properties$"),
    re.compile(r"^META-INF/[^/]*\.version$"),
    re.compile(r"^META-INF/version-control-info\.textproto$"),
    re.compile(r"(^|/)\.gitkeep$"),
]

def drop(name: str) -> bool:
    if not name or name.endswith("/"):
        return True
    if name.startswith("OSGI-INF/") or "/OSGI-INF/" in name:
        return True
    for prefix in drop_dirs:
        if name.startswith(prefix):
            return True
    if name == "assets/libmitv.so" and want != "armeabi-v7a":
        return True
    for rx in drop_res:
        if rx.search(name):
            return True
    if "chaquopy" in name.lower():
        for abi in others:
            if abi == "x86" and "x86_64" in name:
                continue
            if re.search(rf"(^|[-_./]){re.escape(abi)}([.-_/]|$)", name):
                return True
    if not check_only and (
        name == "META-INF/MANIFEST.MF"
        or re.search(r"^META-INF/[^/]*\.(SF|RSA|DSA)$", name)
    ):
        return True
    return False

removed = []
kept = []
with zipfile.ZipFile(apk) as zin:
    infos = zin.infolist()
    if check_only:
        for info in infos:
            if drop(info.filename) or info.file_size == 0:
                removed.append(info.filename)
        if want == "armeabi-v7a" and not any(i.filename == "assets/libmitv.so" for i in infos):
            removed.append("MISSING assets/libmitv.so")
        stub = f"assets/mpv-libs/{want}/libvulkan.so"
        if not any(i.filename == stub for i in infos):
            removed.append(f"MISSING {stub}")
        if removed:
            print("\n".join(removed[:50]), file=sys.stderr)
            if len(removed) > 50:
                print(f"... and {len(removed) - 50} more", file=sys.stderr)
            sys.exit(1)
        dirs = set()
        for info in infos:
            parts = info.filename.split("/")[:-1]
            acc = ""
            for p in parts:
                acc = f"{acc}{p}/"
                dirs.add(acc)
        print(f"ok: {apk} abi={want} files={len(infos)} dirs={len(dirs)}")
        sys.exit(0)
    with zipfile.ZipFile(out, "w", allowZip64=True) as zout:
        for info in infos:
            if drop(info.filename):
                removed.append(info.filename)
                continue
            data = zin.read(info.filename)
            new = zipfile.ZipInfo(filename=info.filename, date_time=info.date_time)
            new.compress_type = info.compress_type
            new.external_attr = info.external_attr
            new.flag_bits = info.flag_bits & ~0x8  # 重写后不使用 data descriptor
            new.create_system = info.create_system
            zout.writestr(new, data)
            kept.append(info.filename)

print(f"removed {len(removed)} entries; kept {len(kept)}", flush=True)
for name in removed:
    if "/" not in name or name.count("/") <= 2:
        print(f"  - {name}", flush=True)
PY

if [[ "$CHECK" == "1" ]]; then
  exit 0
fi

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
ZIPALIGN="$(ls -1 "$SDK"/build-tools/*/zipalign 2>/dev/null | tail -1 || true)"
APKSIGNER="$(ls -1 "$SDK"/build-tools/*/apksigner 2>/dev/null | tail -1 || true)"
if [[ ! -x "$ZIPALIGN" || ! -x "$APKSIGNER" ]]; then
  echo "ERROR: zipalign/apksigner not found under $SDK/build-tools" >&2
  exit 1
fi
KS="${KOTV_STORE_FILE:-$ROOT/flutter/android/app/kotv-ci.jks}"
if [[ "$KS" != /* ]]; then
  KS="$ROOT/flutter/android/app/$KS"
fi
KS_PASS="${KOTV_STORE_PASSWORD:-kotv-ci-store}"
KEY_ALIAS="${KOTV_KEY_ALIAS:-kotv}"
KEY_PASS="${KOTV_KEY_PASSWORD:-$KS_PASS}"
"$ZIPALIGN" -p -f 4 "$WORK/unsigned.apk" "$WORK/aligned.apk"
"$APKSIGNER" sign \
  --ks "$KS" \
  --ks-pass "pass:$KS_PASS" \
  --key-pass "pass:$KEY_PASS" \
  --ks-key-alias "$KEY_ALIAS" \
  "$WORK/aligned.apk"
"$APKSIGNER" verify --verbose "$WORK/aligned.apk" >/dev/null
mv -f "$WORK/aligned.apk" "$APK"
echo "tidied $APK"
python3 - "$APK" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
dirs = set()
for info in z.infolist():
    if info.filename.endswith("/") or info.file_size == 0:
        sys.exit(f"ERROR: empty entry left: {info.filename}")
    parts = info.filename.split("/")[:-1]
    acc = ""
    for p in parts:
        acc = f"{acc}{p}/"
        dirs.add(acc.rstrip("/"))
print("directories:")
for d in sorted(dirs):
    if d.count("/") <= 2:
        print(f"  {d}")
PY
