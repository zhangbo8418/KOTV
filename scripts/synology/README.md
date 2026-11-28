# 群晖 DSM 7.2 SPK（CI 专用）

形态与 Web 包相同（`kotv-engine` + `webapp/` + `runtime/`），因 NAS 只能跑服务端 Web。

- **引擎**：DSM Toolkit GCC + sysroot **全静态**（`-trimpath`，`-ldflags="-s -w … -linkmode external -extldflags '-static --sysroot=…'"`）。CGO（QuickJS 等）也走同一工具链，不用宿主 libc / musl Docker。
- **运行时**（Node/Python/JRE/Chromium/ffmpeg）：同一 Toolkit 交叉或本地编；不用 Liberica/CFT 预编译充数。

Web 便携包的 musl 静态引擎仍用仓库根目录 `scripts/build-engine-static-linux.sh`，与群晖路径分离。

仅在 GitHub Actions 构建。

## CI 结构（组件 × 架构）

| Job | 说明 |
|-----|------|
| `synology-piece`（矩阵） | runtime × `{x86_64,armv8}`；`engine`×2（Toolkit 静态）；`webapp`、`bridge` |
| `synology-package` | 下载全部 `syno-*.tar` → `ci-assemble-spks.sh` → 两个 `.spk` |

平台：`geminilake`→x86_64，`rtd1296`→armv8。

```bash
./scripts/synology/ci-build-piece.sh engine geminilake
./scripts/synology/ci-build-piece.sh runtime geminilake node
./scripts/synology/ci-assemble-spks.sh
```

共用逻辑在 `common.sh`（工具链探测、静态引擎校验、artifact 名）。

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
