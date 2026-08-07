# KOTV

跨端影视聚合客户端（Flutter / Go），兼容 CatVod 配置生态。

发行包**捆绑 JRE / Python / Chromium / FFmpeg / VLC / MPV**，QuickJS（JS 爬虫）编译进主程序。Windows 捆绑运行时做 **Win7 尽力兼容**（见下）。

## 功能状态

| 模块 | 状态 |
|------|------|
| Flutter UI（海报网格 / 顶栏导航 / 色板） | ✅ |
| CatVod 配置 + JAR / QuickJS / Python 爬虫 | ✅ |
| 二次解析 type=0/1/2/3/4 | ✅ |
| M3U8 过滤 / 直播 / EPG | ✅ |
| DLNA 投屏（DMC 控制 / DMR 接收） | ✅ |
| 局域网 API / 遥控 / 手机同步（历史·收藏） | ✅ |
| 弹幕 / 自更新 | ✅ |
| 旁路播放（捆绑 VLC / MPV）+ 续播 | ✅ |
| 页内嵌入播放（Flutter media_kit MPV / runtime libvlc） | ✅ |
| 单集循环（页内 MPV/VLC） | ✅ |
| Flutter Web 包（引擎同端口放出；不进 PC/安卓/iOS） | ✅ |
| 捆绑运行时 (JRE/Python/Chromium/ffmpeg/VLC/MPV) | ✅ |
| QuickJS 内嵌主程序 (CGO) | ✅ |
| Win7 运行时 + GitHub Actions 打包 | ✅ |
| Widevine / PlayReady 等 DRM 实播 | ❌（检测并提示） |
| ed2k | ❌ |

## 环境要求（开发）

- Go 1.22+（`CGO_ENABLED=1`，QuickJS）
- curl / tar / unzip（下载运行时）
- macOS 捆绑 MPV 时建议已装 Homebrew
- 可选：本机未准备 `runtime/` 时 JAR/Python 爬虫不可用（**不再回落系统 Java/Python**）

## 快速开始（开发）

```bash
go mod tidy
chmod +x bridge/build.sh scripts/*.sh
# Bridge 使用 JDK 21（Gradle ShadowJar，与捆绑 Liberica 一致）；首次构建会自动准备 Gradle wrapper。
./bridge/build.sh
# 下载当前平台捆绑运行时（体积大，耐心等待）
./scripts/prepare-runtime.sh
CGO_ENABLED=1 go run .
```

## 打发行包

本地：

```bash
# 准备运行时 + 编译 + 组装 dist/KOTV-<platform>/
./scripts/package.sh              # 当前平台
./scripts/package.sh macos-arm64  # 指定平台
KOTV_VERSION=1.2.3 ./scripts/package.sh windows-x64
```

GitHub：

1. 打 semver tag（如 `v0.1.0`）并 push，或在 Actions 里手动跑 **KOTV Build**
2. Workflow 会构建 Windows x64 / Windows ARM64 / Linux / macOS arm64 / macOS x86_64，上传 ZIP（及 Windows 安装包），并写 Release + `version.json`
3. Windows 任务使用 **MSVCRT MinGW**，并用 **[go-legacy-win7](https://github.com/thongtech/go-legacy-win7)** 构建主程序；x64 发行包捆绑 **PythonVista / Chromium（Win7 REWORK 最新） / FFmpeg 7.0**，ARM64（Win11+）用最新 Chromium snapshot。Windows 另打 Inno Setup 安装包（桌面/卸载显示「KO影视」）；ZIP 仍供更新器使用，也可手动解压

## Windows 7 兼容说明

| 组件 | 策略 |
|------|------|
| **JRE 21** | 全平台捆绑 **BellSoft Liberica 21**；Windows amd64 另注入 [`api-ms-win-core-path`](https://github.com/adang1345/api-ms-win-core-path)（Win7 SP1+ 尽力兼容，Liberica 文档含 Win7） |
| Python | [adang1345/PythonVista](https://github.com/adang1345/PythonVista) embed **3.14** |
| Chromium | **x64**：解包 [Chromium-for-windows-7-REWORK](https://github.com/e3kskoy7wqk/Chromium-for-windows-7-REWORK) **最新** `mini_installer_x64.exe` → 展平到 `runtime/chromium/`；**ARM64**：最新 snapshot（展平，无 `chrome-win` 子目录） |
| FFmpeg | Gyan **7.0** full build |
| QuickJS（JS 爬虫） | CGO 编进主程序；Windows 用 **MSVCRT MinGW** + `_WIN32_WINNT=0x0601` + `static-libgcc`，CI 跑 `check-win7-deps.ps1` |

> Windows 主程序使用 [go-legacy-win7](https://github.com/thongtech/go-legacy-win7) 构建，以补回官方 Go 1.21+ 之后移除的 Win7/8/8.1 支持。捆绑 **Java / 爬虫 / 嗅探** 运行时同样按 Win7 准备；若目标机缺少旧版系统更新，PythonVista 仍可能要求先安装 KB2533623 或其后继更新 [KB3063858](https://github.com/adang1345/PythonVista)。

目录结构：

```
dist/KOTV-macos-arm64/
  KOTV                  # 含内嵌 QuickJS
  runtime/
    jre/                # Liberica 21 → JAR 爬虫
    python/             # CPython 3.14 → Python 爬虫
    chromium/           # Win=chrome.exe（REWORK/snapshot 展平）；其它=CFT headless-shell 等
    ffmpeg/
    libvlc/             # libvlc + plugins（页内 VLC；Flutter kotv_vlc）
    bridge/spider-bridge.jar
  README.txt
```

| 组件 | 用途 | 来源 |
|------|------|------|
| JRE 21 | JAR 爬虫 (spider-bridge) | BellSoft Liberica |
| Python 3.14 | Python 爬虫 | PBS / Win7 embed (PythonVista) |
| Chromium | 网页嗅探 / 解析 | **macOS / Linux x64**：CFT Stable 最新；**Win x64**：Win7 REWORK 最新；**Win ARM64**：最新 snapshot；Linux ARM64 回落系统 Chrome |
| FFmpeg | 媒体处理 | osxexperts / Gyan / BtbN |
| libvlc | **页内嵌入（VLC）** | VideoLAN 官方包提取 lib + plugins |
| QuickJS | JS 爬虫 | 编译进 KOTV（无需单独目录） |

运行时查找顺序：可执行文件旁 `runtime/` → 环境变量 `KOTV_RUNTIME` → 开发态仓库 `runtime/`。

**Java / Python 仅使用捆绑路径**，不会读取 `JAVA_HOME` 或系统 PATH。JAR 爬虫通过捆绑 JRE 启动常驻 `spider-bridge --serve` 进程（JVM 只初始化一次，崩溃可自动拉起），不嵌入主进程。

**播放**：桌面页内 MPV 由 Flutter **media_kit 自带 libmpv**（不进 `runtime/`）。页内 VLC 使用 `runtime/libvlc`。也可选外部 VLC/MPV。

## 浏览器 Web 包

与 PC / Android / iOS **客户端包分离**：Web 包 = 引擎 + `webapp/`，**同端口**（默认 `:9978`）由引擎直接放出页面。浏览器固定使用本站后端；开启远端鉴权时打开页即登录（无「远端登录 / 改引擎地址」）。

```bash
./scripts/package-flutter-web.sh          # → dist/…-web-….zip
./kotv-engine                             # 旁路需有 webapp/
# 浏览器
open http://127.0.0.1:9978/               # Web 客户端
open http://127.0.0.1:9978/remote/        # 遥控
```

也可只解压 `*-web-static.zip` 到已有引擎目录下的 `webapp/`。普通引擎/桌面包不含 `webapp` 时，`/` 仍是遥控页。

## 数据目录

| 平台 | 路径 |
|------|------|
| macOS | `~/Library/Caches/KOTV/` |
| Linux | `~/.cache/KOTV/` |
| Windows | `%AppData%/KOTV/cache/` |
