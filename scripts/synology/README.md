# 群晖 DSM 7.2 SPK（CI 专用）

形态与 Web 包相同（`kotv-engine` + `webapp/` + `runtime/`），因 NAS 只能跑服务端 Web。
**引擎与运行时均由官方 Toolkit 编译**（动态链 DSM sysroot），不用 musl 静态引擎、不用 Liberica/CFT 预编译充数。

仅在 GitHub Actions 构建。

## CI 结构（组件 × 架构）

每个 runner 只编一块，全部成功后再合并：

| Job | 说明 |
|-----|------|
| `synology-piece`（矩阵） | `node/python/jre/chromium/ffmpeg` × `{x86_64,armv8}`；另加 `engine`×2、`webapp`、`bridge` |
| `synology-package` | 下载全部 `syno-*.tar` → `ci-assemble-spks.sh` → 两个 `.spk` |

平台：`geminilake`→x86_64，`rtd1296`→armv8。

脚本入口：

```bash
./scripts/synology/ci-build-piece.sh runtime geminilake node
./scripts/synology/ci-build-piece.sh engine rtd1296
./scripts/synology/ci-build-piece.sh webapp
./scripts/synology/ci-build-piece.sh bridge
./scripts/synology/ci-assemble-spks.sh   # 合并 dist/syno-pieces/*.tar
```

共用逻辑在 `common.sh`。

## 本地一站（慢，仅调试）

```bash
./scripts/synology/build-spk.sh geminilake   # 单架构
./scripts/synology/build-spk.sh all          # 两架构
```

## 环境变量（常用）

| 变量 | 作用 |
|------|------|
| `KOTV_SYNO_JOBS` | make/ninja `-j`（默认 `nproc`） |
| `KOTV_SYNO_COMPONENTS` | 限制 runtime 组件（CI piece 会设为单个） |
| `KOTV_SYNO_CHROMIUM_TARBALL` | 预打包 chromium src，跳过 fetch |
