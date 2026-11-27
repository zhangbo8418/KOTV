# 群晖 DSM 7.2 SPK（CI 专用）

仅在 GitHub Actions 构建，不在本机跑 Toolkit / Chromium。

## 流程

1. `deploy-toolkit.sh <braswell|rtd1296>` — 部署官方 `pkgscripts-ng` DSM 7.2 环境  
2. `build-runtime-in-chroot.sh <...>` — 用 Toolkit sysroot 编 Node / Python / OpenJDK JRE / Chromium(headless) / ffmpeg → `dist/syno-runtime-{x86_64|armv8}/`  
3. Web：`package-flutter-web.sh linux-x64|linux-arm64`（musl 静态引擎）  
4. `package-spk.sh <x86_64|armv8>` → `dist/KO影视-{ver}-synology-{arch}.spk`

套件元数据在 `synology/kotv/`。`prepare-runtime.sh synology-*` 只复制 Toolkit 产物，不下 Liberica/CFT。

## 版本钉

见 `versions.env`。
