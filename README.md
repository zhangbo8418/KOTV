# KOTV（KO影视）

跨端影视聚合客户端：**Flutter UI + Go 引擎**。引擎加载 CatVod 兼容的站点配置，内置 CMS 解析并支持 JS / Python / JAR 四类爬虫；发行包捆绑 JRE / Python / Chromium / FFmpeg 运行时，QuickJS 通过 CGO 编译进主程序。

> 仓库模块：`github.com/bobo/KOTV`。引擎无 UI，HTTP 端口 `:9978`（API 在 `/api/v1`，嗅探代理在 `/proxy/*`）。

## 功能状态

| 模块 | 状态 |
|------|------|
| Flutter UI（海报网格 / 顶栏导航 / 色板） | ✅ |
| CatVod 配置 + 内置 CMS 解析（type 0/1/4） | ✅ |
| JS 爬虫（QuickJS，CGO 内嵌） | ✅ |
| Python 爬虫（捆绑运行时） | ✅ |
| JAR 爬虫（Java bridge） | ✅ |
| 二次解析 type=0/1/2/3/4 | ✅ |
| M3U8 过滤 / 直播 / EPG | ✅ |
| DLNA 投屏（DMC 控制 / DMR 接收） | ✅ |
| 局域网 API / 遥控 / 手机同步（历史·收藏） | ✅ |
| 弹幕 / 自更新 | ✅ |
| 页内嵌入播放（Flutter media_kit MPV / FVP） | ✅ |
| 旁路播放（外部 VLC / MPV）+ 续播 | ✅ |
| 单集循环（页内 MPV/FVP） | ✅ |
| 浏览器 Web 包（引擎同端口放出） | ✅（见下，由主 CI `build-web` 产出） |
| Windows 7 兼容发行包 | ✅（见下，由主 CI `build-flutter-win7` 产出） |
| Widevine / PlayReady 等 DRM 实播 | ❌（检测并提示） |
| ed2k | ❌ |

## 平台

CI 统一在 **KOTV Build** 工作流里构建：

| 平台 | 产物 | 备注 |
|------|------|------|
| Windows x64 | ZIP + Inno 安装包 | 主力；另出 **Win7 兼容变体** |
| Windows ARM64 | ZIP | Win11+ |
| Linux x64 | ZIP |  |
| macOS arm64 | DMG（KO影视.app） |  |
| macOS x64 | DMG（KO影视.app） | Rosetta / 原生 x64 |
| Android | aarch64 / armv7 APK | 手机/平板 |
| Web | linux-x64 引擎 + `webapp/` ZIP | 引擎同端口放出页面 |

> **iOS**：仓库含 `flutter/ios/` 开发目录，但当前**未纳入 CI 构建**，属于后续嵌入目标（详见架构文档），不计入已发布平台。
> **Android TV / leanback**：当前 Android 构建为手机/平板 APK，无独立 TV 构建。文档/UI 中出现的「TV」指 DLNA 投屏目标设备，非 Android TV 应用。

## 架构总览

```text
Flutter App（桌面 / Android / Web）
   │  HTTP /api/v1 + X-Kotv-Client-Id
   ▼
Go Engine（单进程，:9978）
   ├─ CMS 解析     → 内置（type 0/1/4）
   ├─ JS 爬虫      → QuickJS worker 池（CGO 内嵌）
   ├─ Python 爬虫  → Python 进程池（捆绑 runtime/python）
   └─ JAR 爬虫     → Java bridge（JVM 常驻，HTTP 多路）
       运行时：JRE(Liberica21) · Python(CPython3.14) · Chromium · FFmpeg
```

详细设计（进程模型、ScopeID 多前端隔离、爬虫与 bridge、播放引擎）见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 环境要求（开发）

- Go 1.26.x（`CGO_ENABLED=1`，QuickJS 需 C 工具链；Windows 用 MSVCRT MinGW）
- JDK 21（bridge 用 Gradle ShadowJar，与捆绑 Liberica 一致）
- Flutter 3.44.x（桌面/Android/Web）
- curl / tar / unzip（下载运行时）
- 未准备 `runtime/` 时 JAR/Python 爬虫不可用（**不回落系统 Java/Python**）

## 快速开始（开发）

```bash
go mod tidy
chmod +x bridge/build.sh scripts/*.sh
# 首次构建会自动准备 Gradle wrapper 并产出 spider-bridge.jar
./bridge/build.sh
# 下载当前平台捆绑运行时（体积大，耐心等待）
./scripts/prepare-runtime.sh
CGO_ENABLED=1 go run .
# 另开终端启动 Flutter UI（引擎由 EngineLauncher 托管）
cd flutter && flutter pub get && flutter run -d macos
```

引擎启动后默认监听 `http://127.0.0.1:9978`，Flutter 通过 `/api/v1` 通信；浏览器访问 `http://127.0.0.1:9978/remote/` 即遥控页。

## 打发行包

本地：

```bash
./scripts/package.sh              # 当前平台
./scripts/package.sh macos-arm64  # 指定平台
KOTV_VERSION=1.2.3 ./scripts/package.sh windows-x64
```

GitHub：打 semver tag（如 `v0.1.0`）并 push，或在 Actions 手动运行 **KOTV Build**。该工作流构建上述全部平台（含 `build-web`、`build-flutter-win7`），上传产物并写 Release + `version.json`。

Windows x64 任务使用 **MSVCRT MinGW** 与 [go-legacy-win7](https://github.com/thongtech/go-legacy-win7) 构建主程序，以补回官方 Go 1.21+ 移除的 Win7/8/8.1 支持；Win7 变体捆绑 PythonVista / Chromium（Win7 REWORK）/ FFmpeg 7.0。Windows 另打 Inno Setup 安装包（桌面/卸载显示「KO影视」）。

发行包结构（`dist/KOTV-<platform>/`）：

```
KOTV                  # 主程序（含内嵌 QuickJS；Windows 为 KOTV.exe）
runtime/
  jre/                # Liberica 21 → JAR 爬虫
  python/             # CPython 3.14 → Python 爬虫（Windows x64 用 PythonVista embed）
  chromium/           # 网页嗅探/解析（Win x64=Win7 REWORK；其它=CFT headless-shell 等）
  ffmpeg/
  bridge/spider-bridge.jar
README.txt
```

| 组件 | 用途 | 来源 |
|------|------|------|
| JRE 21 | JAR 爬虫 (spider-bridge) | BellSoft Liberica |
| Python 3.14 | Python 爬虫 | CPython standalone / Windows 用 PythonVista embed |
| Chromium | 网页嗅探 / 解析 | macOS/Linux x64：CFT Stable；Win x64：Win7 REWORK；Win ARM64：最新 snapshot；Linux ARM64 回落系统 Chrome |
| FFmpeg | 媒体处理 | osxexperts / Gyan / BtbN |
| QuickJS | JS 爬虫 | 编译进主程序（无需单独目录） |

运行时查找顺序：可执行文件旁 `runtime/` → 环境变量 `KOTV_RUNTIME` → 开发态仓库 `runtime/`。

**Java / Python 仅使用捆绑路径**，不读 `JAVA_HOME` 或系统 PATH。JAR 爬虫通过捆绑 JRE 启动常驻 `spider-bridge --serve` 进程（JVM 只初始化一次，崩溃可自动拉起），不嵌入主进程。

**播放**：桌面页内 MPV 由 Flutter **media_kit 自带 libmpv**（不进 `runtime/`），亦可选手动 FVP（libmdk）；外部 VLC/MPV 使用系统安装。

## 浏览器 Web 包

Web 包与主客户端包分离：引擎 + `webapp/`，**同端口**（默认 `:9978`）由引擎直接放出页面；浏览器固定使用本站后端，打开页即登录（无「远端登录 / 改引擎地址」）。普通引擎/桌面包不含 `webapp` 时，`/` 仍是遥控页。

```bash
./scripts/package-flutter-web.sh          # → dist/…-web-….zip
./kotv-engine                             # 旁路需有 webapp/
open http://127.0.0.1:9978/               # Web 客户端
open http://127.0.0.1:9978/remote/        # 遥控
```

也可只解压 `*-web-static.zip` 到已有引擎目录下的 `webapp/`。

## iOS（开发中，尚未发布）

仓库含 `flutter/ios/` 开发目录，引擎可经 gomobile / 静态链嵌入 iOS App；但**当前 iOS 尚未完全实现，未纳入 CI 构建，也不在已发布平台内**。

**设计上 iOS 只负责 UI 与播放链路**：受 iOS 沙盒与 App Store 限制，端侧无法动态加载 JAR / Python / JS 爬虫运行时——既没有可用的 JVM / Python，也不能像 Android 那样动态加载 DEX（ART）。因此本地抓取不可行，内容解析统一由远端 Go 引擎完成（共用同一套 `/api/v1`）。待嵌入与远端联调就绪后再开放。

## 数据目录

| 平台 | 路径 |
|------|------|
| macOS | `~/Library/Caches/KOTV/` |
| Linux | `~/.cache/KOTV/` |
| Windows | `%AppData%/KOTV/` |
