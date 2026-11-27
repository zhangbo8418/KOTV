# 群晖 DSM 7.2 SPK（CI 专用）

形态与 Web 包相同（`kotv-engine` + `webapp/` + `runtime/`），因 NAS 只能跑服务端 Web。
**引擎与运行时均由官方 Toolkit 编译**（动态链 DSM sysroot），不用 musl 静态引擎、不用 Liberica/CFT 预编译充数。

仅在 GitHub Actions 构建。

## 一站入口

```bash
./scripts/synology/build-spk.sh braswell   # → synology-x86_64.spk
./scripts/synology/build-spk.sh rtd1296    # → synology-armv8.spk
```

内部顺序：`deploy-toolkit` → `build-flutter-webapp` → `build-engine`（Toolkit）→ `build-runtime-in-chroot`（Node/Python/JRE/Chromium）→ `package-spk`。

共用逻辑在 `common.sh`。Chromium 默认解析 CFT Stable 最新版（`versions.env`）。
