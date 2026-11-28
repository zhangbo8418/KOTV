# 群晖 DSM 7.2 SPK（CI 专用）

形态与 Web 包相同（`kotv-engine` + `webapp/` + `runtime/`），因 NAS 只能跑服务端 Web。
**引擎与运行时均由官方 Toolkit 编译**（动态链 DSM sysroot），不用 musl 静态引擎、不用 Liberica/CFT 预编译充数。

仅在 GitHub Actions 构建。

## 一站入口

```bash
./scripts/synology/build-spk.sh geminilake   # → synology-x86_64.spk
./scripts/synology/build-spk.sh rtd1296      # → synology-armv8.spk
```

流程：

1. `deploy-toolkit`
2. **并行**：`build-flutter-webapp` / `build-engine`（Toolkit）/ `build-runtime-in-chroot` / `bridge/build.sh`
3. runtime 内 **再并行**：Node / Python / JRE / Chromium / ffmpeg（均分 `-j`；`KOTV_SYNO_RUNTIME_SERIAL=1` 可串行）
4. `package-spk`

共用逻辑在 `common.sh`（平台映射、工具链、并行调度、动态引擎校验）。Chromium 默认解析 CFT Stable 最新版（`versions.env`）。

## 环境变量（常用）

| 变量 | 作用 |
|------|------|
| `KOTV_SYNO_JOBS` | 总并行度（默认 `nproc`） |
| `KOTV_SYNO_COMPONENTS` | runtime 组件列表，默认 `node python jre chromium ffmpeg` |
| `KOTV_SYNO_RUNTIME_SERIAL=1` | runtime 组件改串行 |
| `KOTV_SYNO_CHROMIUM_TARBALL` | 预打包 chromium src，跳过 fetch |
