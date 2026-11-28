# 群晖 DSM 7.2 SPK（CI 专用）

形态与 Web 包相同（`kotv-engine` + `webapp/` + `runtime/`），因 NAS 只能跑服务端 Web。

- **引擎**：DSM Toolkit GCC + sysroot **全静态**（`-trimpath`，`-ldflags="-s -w … -linkmode external -extldflags '-static --sysroot=…'"`）。CGO 走同一工具链，不用宿主 libc。
- **运行时**（Node / Python / JRE / Chromium / ffmpeg）：同一 Toolkit 交叉或本地编。
- **deps**（`toolkit-deps.sh`）：按上游文档一次备齐外部库，全部用 Toolkit 编进 `.syno-deps/<platform>/`，**不用宿主 `/usr`**。sysroot 仅作工具链环境（含已有 X11 头文件时）。

| 组件 | 外部依赖策略 |
|------|----------------|
| Node | 上游把 openssl/zlib/icu 等编进二进制，无 overlay |
| Python | CPython optional modules：zlib/bzip2/xz/zstd/libffi/openssl/sqlite/ncurses/readline/libuuid |
| JRE | OpenJDK 必选：alsa、cups、fontconfig（+expat/freetype）、X11（优先 sysroot，否则自编） |
| Chromium | 官方 `build/args/headless.gn` + third_party；宿主 Clang 仅作编译器 |
| ffmpeg | zlib + openssl（Toolkit 自编） |

Web 便携包的 musl 静态引擎仍用仓库根目录 `scripts/build-engine-static-linux.sh`，与群晖路径分离。

仅在 GitHub Actions 构建。

## CI 结构（组件 × 架构）

| Job | 说明 |
|-----|------|
| `synology-piece`（矩阵） | runtime × `{x86_64,armv8}`；`engine`×2；`webapp`、`bridge` |
| `synology-package` | 下载全部 `syno-*.tar` → `ci-assemble-spks.sh` → 两个 `.spk` |

平台：`geminilake`→x86_64，`rtd1296`→armv8。Python 钉 `3.14.x`（交叉编时宿主 build-python 的 major.minor 须一致）。

```bash
./scripts/synology/ci-build-piece.sh engine geminilake
./scripts/synology/ci-build-piece.sh runtime geminilake node
./scripts/synology/ci-assemble-spks.sh
```

共用：`common.sh`（工具链 / 引擎校验）、`toolkit-deps.sh`（`kotv_syno_ensure_deps <profile>`）。

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
| `KOTV_SYNO_DEPS_PREFIX` | Toolkit 自编 deps 安装前缀（默认 `.syno-deps/<platform>`） |
| `KOTV_SYNO_CHROMIUM_TARBALL` | 预打包 chromium src |
