# 群晖 DSM 7.2 SPK（CI 专用）

形态与 Web 包相同（`kotv-engine` + `webapp/` + `runtime/`），因 NAS 只能跑服务端 Web。

- **引擎**：musl 全静态（与 Web 包共用 `build-engine-static-linux.sh`：`-trimpath` + `-ldflags="-s -w …"`），不依赖 DSM glibc。
- **运行时**（Node/Python/JRE/Chromium/ffmpeg）：官方 Toolkit GCC/sysroot 交叉或本地编；不用 Liberica/CFT 预编译充数。

仅在 GitHub Actions 构建。

## CI 结构（组件 × 架构）

| Job | 说明 |
|-----|------|
| `synology-piece`（矩阵） | runtime 组件 × `{x86_64,armv8}`；`engine`×2（静态）；`webapp`、`bridge` |
| `synology-package` | 下载全部 `syno-*.tar` → `ci-assemble-spks.sh` → 两个 `.spk` |

平台映射：`geminilake`→x86_64，`rtd1296`→armv8（仅用于选 arch；引擎本身不编 Toolkit）。

```bash
./scripts/synology/ci-build-piece.sh runtime geminilake node
./scripts/synology/ci-build-piece.sh engine rtd1296
./scripts/synology/ci-build-piece.sh webapp
./scripts/synology/ci-build-piece.sh bridge
./scripts/synology/ci-assemble-spks.sh
```

共用逻辑在 `common.sh`。

## 本地一站（慢，仅调试）

```bash
./scripts/synology/build-spk.sh geminilake
./scripts/synology/build-spk.sh all
```

## 环境变量（常用）

| 变量 | 作用 |
|------|------|
| `KOTV_SYNO_JOBS` | make/ninja `-j` |
| `KOTV_SYNO_COMPONENTS` | 限制 runtime 组件（CI piece 设为单个） |
| `KOTV_SYNO_CHROMIUM_TARBALL` | 预打包 chromium src |
| `KOTV_STATIC_GO_IMAGE` | 静态引擎 Docker 镜像（默认 `golang:1.27.4-alpine`） |
