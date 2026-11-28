# 群晖 DSM 7.2 SPK（CI 专用）

形态与 Web 包相同（`kotv-engine` + `webapp/` + `runtime/`），因 NAS 只能跑服务端 Web。

## 工具链与依赖闭包

| 组件 | 目标链接 | 依赖闭包（configure 前一次编齐） |
|------|----------|----------------------------------|
| **engine** | Toolkit GCC+sysroot **全静态** | 无外部 .so |
| **Node** | Toolkit + `.syno-deps` | zlib、brotli、c-ares、nghttp2、openssl（`--shared-*`）；ICU 用树内 full-icu |
| **Python** | Toolkit + `.syno-deps` | CPython optional：zlib/bzip2/xz/zstd(static)/libffi/openssl/sqlite/ncurses/readline/libuuid |
| **JRE** | Toolkit + `.syno-deps` | OpenJDK 必选：alsa、cups、fontconfig(+expat/freetype)、X11 栈（始终自编） |
| **ffmpeg** | Toolkit + `.syno-deps` | zlib、openssl（`--enable-openssl --enable-version3`） |
| **Chromium** | Clang + **Toolkit sysroot ABI** | 可写 Toolkit sysroot 副本；Toolkit 编 libdrm/xkbcommon，并提供 `dri.pc`；`headless.gn` + `use_system_minigbm=false` |

目标链接 **禁止宿主 `/usr`**。宿主只允许构建工具：Clang、meson/ninja、boot JDK、交叉 build-python、Node 的 `CC_host`。

共用：`common.sh`、`toolkit-deps.sh`（`kotv_syno_ensure_deps <profile>`）。

Web 便携包 musl 静态引擎仍用仓库根目录 `scripts/build-engine-static-linux.sh`，与群晖路径分离。

仅在 GitHub Actions 构建。

## CI 结构（组件 × 架构）

| Job | 说明 |
|-----|------|
| `synology-piece`（矩阵） | runtime × `{x86_64,armv8}`；`engine`×2；`webapp`、`bridge` |
| `synology-package` | 下载全部 `syno-*.tar` → `ci-assemble-spks.sh` → 两个 `.spk` |

平台：`geminilake`→x86_64，`rtd1296`→armv8。

```bash
./scripts/synology/ci-build-piece.sh engine geminilake
./scripts/synology/ci-build-piece.sh runtime geminilake node
./scripts/synology/ci-assemble-spks.sh
```

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
| `KOTV_SYNO_DEPS_PREFIX` | Toolkit 自编 deps 前缀（默认 `.syno-deps/<platform>`） |
| `KOTV_SYNO_CHROMIUM_TARBALL` | 预打包 chromium src |
