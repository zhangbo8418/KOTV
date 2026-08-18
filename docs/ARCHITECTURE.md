# KOTV 架构

## 总览

**Flutter UI + Go 引擎核**（`cmd/engine`）。引擎是单进程 HTTP 服务，对前端提供 `/api/v1` 与嗅探代理 `/proxy/*`；可独立部署到服务器供多前端并发，也可由桌面/Android 的 Flutter 在本地拉起。

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

四大二进制（`cmd/`）：

| 二进制 | 作用 |
|--------|------|
| `engine` | 主引擎：HTTP 服务 + 爬虫 + 嗅探，无 UI |
| `updater` | ZIP 自更新：`-path` 目标目录 + `-file` 更新包，覆盖解压 |
| `try_spiders` | 开发调试：本地试跑某站爬虫，验证配置 |
| `diagflow` | 诊断：打印引擎/爬虫/网络运行态，便于排错 |

## 进程与 HTTP 模型

引擎只跑**一个 Go 进程**（`cmd/engine`）。关键事实：

- 端口 `:9978`，路由分两块：`/api/v1/*`（Flutter/前端后端，见下）与 `/proxy/*`（爬虫嗅探代理）。
- 存在 `webapp/` 时，`/` 放出 Flutter Web 页面、遥控挪到 `/remote/`；无 `webapp` 时 `/` 即遥控页（`internal/server/webapp.go` 按目录探测）。
- 优雅停机：`SIGINT`/`SIGTERM` 或 `/api/v1/shutdown` 触发 `app.Shutdown()`。

`/api/v1` 主要端点（来自 `internal/server/apiv1.go`）：

| 端点 | 说明 |
|------|------|
| `health` | 存活探测 |
| `auth/status` `auth/login` `auth/register` `auth/me` `auth/password` | 远端鉴权 |
| `admin/users` `admin/settings` | 管理员：用户与全局设置 |
| `session/ping` `session/leave` | 前端会话保活 / 离开（只杀该用户运行时） |
| `config` `home` `category` `detail` `detail/expand` | 站点配置与内容浏览 |
| `search` `play` `sites` `repos` | 搜索 / 播放解析 / 站点列表 / 配置仓库 |
| `live` `player` `media` | 直播 / 播放器态 / 媒体态 |
| `remote/poll` `ui/poll` `ui/reply` | 遥控队列 / UI 长轮询 |
| `cancel` `shutdown` | 取消当前调用 / 关引擎 |
| `net` `tools` `settings` `bt/progress` | 代理配置 / 工具 / 设置 / 磁力进度 |

### 多前端 / ScopeID 隔离

一个引擎服务多个前端（本机 + 远端租户），用 **ScopeID** 隔离：

| 概念 | 取值 |
|------|------|
| 远端租户 | `u:<userId>` |
| 本机（含本机登录/admin） | `c:<clientId>` |

隔离规则：

- **共享**：多仓/单仓列表与脚本磁盘缓存、用户设置全局代理（`settings.Proxy`）、遥控 push/弹幕偏广播。
- **按 Scope 独立**：当前选中的源 / 首页 / 直播、媒体态（播放进度/标题）、遥控队列（control/search）。
- **运行时**：本机共享一套 JVM/Py/JS；远端每用户独立一套。Go 引擎始终只有一个；远端隔离的是爬虫运行时，不是多套引擎。
- **取消/卡死**：`cancelPending` / 换源 → 硬杀所属 JVM/Py/JS（独立进程，互不影响）；单次调用自带超时（JAR 120s / JS·Py 45s）。
- **鉴权**：`settings.remoteAuth` 开启后，非本机连接需登录；本机免登录即全功能。Web 包固定同源后端，打开页即登录。

## 爬虫

`internal/spider` 按站点 `api` 字段分发（`Get(key, api, ext, jar)`）：

| 类型 | 判定 | 实现 |
|------|------|------|
| CMS（内置） | 非 `.py`/`.js`/`csp_` | 引擎内置解析（type 0/1/4） |
| JS | `api` 含 `.js` | 内嵌 **QuickJS**（CGO），worker 池，同站可并行 |
| Python | `api` 含 `.py` | 捆绑 `runtime/python` 进程池，同站可并行 |
| JAR | `api` 前缀 `csp_` | **Java bridge**（JVM），桌面 HTTP 多路、可并发、按 client 软取消 |

- `getClientId()` 返回当前 ScopeID，`postMsg` 据此路由回正确前端。
- 换源时 `ResetScriptSpiders()` 销毁 JS/Python 爬虫，避免旧进程状态污染新站；设置页「清理缓存」清 JAR 磁盘 + JS/Py 内存与落盘目录。

### Java bridge（JAR 爬虫）

`bridge/` 源码两套编译产物（**不要**把桌面 JVM shadowJar 再 d8 进 APK）：

| | 桌面 / 其他平台 | Android |
|--|------|---------|
| 怎么编 | `bridge/build.sh` → `spider-bridge.jar`（含 `android/` stub） | Gradle 模块 `:kotv-bridge`（真实 Android SDK，对齐 TV `:catvod`） |
| 加载宿主 | 捆绑 JRE + `URLClassLoader` 父优先；`--serve` HTTP `:9979` | 编进 **App ClassLoader**；`JarLoader` 直调 `SpiderBridge` |
| 站点 jar | 只吃 PC JVM `.class` 瘦包 | **同时**吃 TV/CatVodSpider dex jar（`DexClassLoader(file, Path.jar(), Path.jar(), App)`）和 PC 瘦包（先 D8） |
| OkHttp | bridge **5.4.0**；请求自动 tag `clientId` | App `force` **5.4.0** |

- CatVodSpider 的 `custom_spider.jar` 只有 `com.github.catvod.{spider,js}`；`crawler.Spider` / Gson / OkHttp / QuickJS 由宿主提供（见其 `checkJar` allowed refs）。
- JVM 瘦包不走 R8 `spider.merge`，站点 **exclude** 宿主同名类，父优先用宿主。
- 站点约定 `com.github.catvod.spider.*`；配置 `csp_ClassName`。
- `libquickjs-android-wrapper.so` 仅进 APK，桌面 JRE 不绑这套 JNI。

## 运行时捆绑

发行包把运行时放进引擎同级的 `runtime/`，**Java/Python 仅用捆绑路径**（不读 `JAVA_HOME`/系统 PATH）：

| 组件 | 用途 | 来源 / 说明 |
|------|------|------|
| JRE 21 | JAR 爬虫 | BellSoft Liberica 21（全平台一致） |
| Python 3.14 | Python 爬虫 | CPython standalone；Windows x64 用 PythonVista embed 以兼容旧系统 |
| Chromium | 网页嗅探 / 解析 | macOS·Linux x64：CFT Stable headless-shell；Win x64：Win7 REWORK 最新；Win ARM64：最新 snapshot；Linux ARM64 回落系统 Chrome |
| FFmpeg | 媒体处理 | osxexperts / Gyan / BtbN |
| QuickJS | JS 爬虫 | CGO 编译进主程序，无单独目录 |

`prepare-runtime.sh` 下载并装配 `runtime/`；查找顺序：可执行文件旁 `runtime/` → `KOTV_RUNTIME` 环境变量 → 开发态仓库 `runtime/`。

## 播放

| 引擎 | 平台 | 说明 |
|------|------|------|
| **MPV**（media_kit） | Android + 桌面 | 页内 libmpv 由 media_kit 自带（不进 `runtime/`）；`vo=libmpv`，可配 `mpv.conf`/hwdec |
| **FVP**（libmdk） | Android + 桌面 | 备选页内引擎，硬/软/自动解码列表由设置下发 |
| 外部 VLC / MPV | 桌面 | 旁路播放，使用系统安装或 PATH |

续播、单集循环基于媒体态（按 ScopeID 分桶）。

## 平台与构建

CI 在 **KOTV Build**（`github-action.yml`）统一构建：

| 平台 | job | 产出 |
|------|-----|------|
| Windows x64 | `build-win-amd64` | ZIP + Inno 安装包 |
| Windows x64（Win7） | `build-flutter-win7` | 同上加 `-win7` 后缀；子系统 6.01 + MSVCRT MinGW |
| Windows ARM64 | `build-win-amd64`（arm 分支） | ZIP |
| Linux x64 | `build-linux` | ZIP |
| macOS arm64 | `build-mac-arm64` | DMG |
| macOS x64 | `build-mac-amd64` | DMG |
| Android | `build-android` | aarch64 / armv7 APK |
| Web | `build-web` | linux-x64 引擎 + `webapp/` ZIP |

> **Web / Win7 是主 CI 内的 job**，并非独立 workflow。
> **iOS**：`flutter/ios/` 开发目录存在，但**尚未完全实现、未纳入 CI 构建**，不在已发布平台内。设计上 iOS 只做 UI 与播放：iOS 无法像 Android 那样动态加载 JAR/DEX，也不能在端侧跑 JVM/Python/QuickJS 爬虫运行时，本地抓取不可行，内容解析统一走远端 Go 引擎（共用 `/api/v1`）。
> **Android TV / leanback**：无独立 TV 构建；当前 Android 为手机/平板 APK。

打包脚本（`scripts/`）：

| 脚本 | 作用 |
|------|------|
| `prepare-runtime.sh` | 下载装配 `runtime/`（JRE/Python/Chromium/FFmpeg） |
| `package.sh` | 本地组装发行目录（当前/指定平台） |
| `package-flutter-{macos,linux,windows,android,web}.sh` | 各平台 Flutter 打包（windows 含 Win7 变体由 `KOTV_WIN7=1` 触发） |
| `build-engine-*.sh` `bundle-flutter-runtime.sh` `make-win-installer.ps1` | 引擎编译 / 运行时捆绑 / Windows 安装包 |
| `verify-runtime.sh` `kotv-release-name.sh` | 运行时校验 / 发行命名 |

## 目录结构

```
KOTV/
  cmd/
    engine/        主引擎（无 UI，:9978）
    updater/       ZIP 自更新
    try_spiders/   爬虫试跑（调试）
    diagflow/      诊断
  internal/
    app/ server/   引擎装配 + HTTP 服务
    spider/        CMS/JS/Python/JAR 爬虫分发
    parse/         嗅探 / 解析
    bridge→java    （见 bridge/）
    live/         直播 / EPG
    dlna/ cast/    投屏
    remote/        遥控 / 前端桥接
    danmaku/       弹幕
    update/        自更新逻辑
    ...（config/auth/settings/model/player/subtitle/thunder/...）
  bridge/          Java 项目 → 桌面 spider-bridge.jar（PC JVM 瘦包宿主）
  flutter/android/kotv-bridge/  安卓宿主（TV dex + PC 瘦包，编进 App CL）
  flutter/         Flutter UI（lib/ 业务，ios/android/macos/linux/windows/web 平台目录）
  scripts/         运行时准备 / 打包 / 安装
  runtime/         捆绑运行时（开发态；发行时随包）
  webapp/          Flutter Web 构建产物（CI 生成，gitignore）
  docs/ARCHITECTURE.md
```
