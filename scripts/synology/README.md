# 群晖 DSM 7.2 SPK（CI 专用）

形态与 Web 包相同（`kotv-engine` + `webapp/` + `runtime/`），因 NAS 只能跑服务端 Web。

## 工具链与依赖闭包

| 组件 | 目标链接 | 依赖闭包（configure 前一次编齐） |
|------|----------|----------------------------------|
| **engine** | Toolkit GCC+sysroot **全静态** | 无外部 .so |
| **Node** | Toolkit + `.syno-deps` | 原生：zlib/c-ares/nghttp2/openssl `--shared-*`；交叉：树内 deps（避免 host 链目标 .so）；brotli/ICU 树内 |
| **Python** | Toolkit + `.syno-deps` | CPython optional：zlib/bzip2/xz/zstd(static+PIC)/libffi/openssl/sqlite/ncurses/readline/libuuid |
| **JRE** | Toolkit + `.syno-deps` | OpenJDK 必选：alsa、cups、fontconfig(+expat/freetype)、X11 栈（含 libXfixes；交叉 `--disable-malloc0returnsnull`） |
| **ffmpeg** | Toolkit + `.syno-deps` | zlib、openssl≥3（`--enable-openssl --enable-version3`；pkg-config 不走 `--static`） |
| **Chromium** | Clang + **Toolkit sysroot ABI** | `headless.gn`（关 gtk/alsa/…）；清单补齐：GCC `crtbeginS`/`libgcc`、`dri.pc`（`use_sysroot` 强制）、arm `HWCAP2_*`；不编系统 libdrm/xkbcommon；只编 `headless_shell` |

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
