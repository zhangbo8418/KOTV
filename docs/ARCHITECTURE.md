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
   ├─ JAR 爬虫     → Java bridge（JVM 常驻，HTTP 多路）
   └─ Node 爬虫    → 捆绑 Node 起猫爪源包（`index.js` / `index.js.md5`）
       运行时：JRE(Liberica21) · Python(CPython3.14) · 嗅探浏览器(runtime/chromium) · FFmpeg
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
| `remote/poll` `/ui` | 遥控队列 / 界面弹窗套接字 |
| `cancel` `shutdown` | 取消当前调用 / 关引擎 |
| `net` `tools` `settings` `bt/progress` | 代理配置 / 工具 / 设置 / 磁力进度 |

### 多前端 / ScopeID 隔离

一个引擎服务多个前端（本机 + 远端租户），用 **ScopeID** 隔离：

| 概念 | 取值 |
|------|------|
| 远端租户 | `u:<userId>` |
| 本机（含本机登录/admin） | `c:<clientId>` |

隔离规则：

- **共享**：多仓/单仓列表与脚本磁盘缓存、遥控 push/弹幕偏广播。
- **按 Scope / DataOwner 独立**：当前选中的源 / 首页 / 直播、媒体态、遥控队列；`settings.Proxy` 按 owner 分桶（宿主重载 Config 时临时 Bind 空 user，只用宿主桶）。
- **站点 cookie 落盘**（`Path.tv`）：本机 → `/TV/`（安卓外置存储同名）；远端 → `/TV/s_u_<用户名>/`（登录名，不跟账号 UUID）。会话隔离仍用 `u:<userId>`。目录名只经 `Util.tvDirName` / `paths.TVDirName`。并发子任务用 `Bind(Snapshot())` 带上 username。不建 `s_c_*`；全部清理删 `s_c_*` 与旧 `s_u_<uuid>`（`paths.IsLegacyTVDir`）。安卓清理：Go 扫 `filesDir/KOTV`；宿主另清 `cacheDir` 爬虫/Exo/mpv-cache，全部时扫外置遗留 TV 桶。
- **运行时**：JAR 桌面/安卓均为单 bridge（租户隔离在 bridge 内）；Py/JS/Node/Chromium 远端仍按用户分桶。Go 引擎始终只有一个。
- **取消/卡死**：`SoftCancelForClient` 按 Scope：JAR 只断 in-flight（不杀唯一 JVM）；Py/Node 取消 in-flight **并**停该 Scope 相关脚本进程（解 IPC，非 HardRestart）。显式 `hard` → `RestartCallerRuntime`（远端仅 KillUser；本机 SoftCancel→清本租户，**仅** bridge 不健康才 `HardRestartSharedRuntimes`）。`KillUserRuntime` 清该用户 bridge 态并杀其 Py/JS/Node/Chromium，不杀 JVM。取消接口不自动升 hard。
- **鉴权**：
  - **Web**：同源本站入口，固定连本页后端（不配远程引擎）；打开页必须登录（与 `remoteAuth` 无关）。
  - **PC/安卓本机**：免登录即全功能。
  - **PC/安卓连远端**：须开启 `remoteAuth`，并在设置里填远端地址后登录。

## 爬虫

`internal/spider` 按站点 `api` 字段分发（`Get(key, api, ext, jar)`）：

| 类型 | 判定 | 实现 |
|------|------|------|
| CMS（内置） | 非 `.py`/`.js`/`csp_` | 引擎内置解析（type 0/1/4） |
| JS | `api` 含 `.js`（非猫爪源包） | 内嵌 **QuickJS**（CGO）；本机/远端按 `RuntimeUserID` 分池，worker 继承 Dedicated 绑 JVM Function |
| Python | `api` 含 `.py` | 捆绑 `runtime/python`；按 `RuntimeUserID` 分池，同站可并行 |
| Node | `api` 以 `/spider/` 开头（来自猫爪 `/config`） | 捆绑 `runtime/node`（安卓 `libkotv_node.so` + `libnode.so` 同进 jniLibs）；本机共享桶、远端按 `RuntimeUserID` 独立桶，桶内一源包一进程 |
| JAR | `api` 前缀 `csp_` | **Java bridge**（JVM）：桌面/安卓均为单进程；`Util.tenantKey()` 分桶 spiders / Prefers / recentJar / userProxy；loaders 按 jar 路径全局共享 |

- `getClientId()` 返回当前 ScopeID，`postMsg` 据此路由回正确前端。
- 取消/重启门面（`runtime_cancel.go`）：`SoftCancelForClient` / `SoftCancelAll`（JAR 不杀 JVM；Py/Node 另停 Scope 相关脚本进程）、`RestartCallerRuntime`（递进恢复）、`HardRestartSharedRuntimes`（桌面重建 JVM；安卓 clearAll 不重启进程）、`KillUserRuntime`、`ShutdownAllRuntimes`。底层 interrupt* 与嗅探钩子不导出。
- 缓存两分法：爬虫包体公共无 uid——`CacheRoot/{jar,py,js,node}`（桌面 `kotv.cache.dir=CacheRoot`；安卓 `KOTV_CACHE_DIR=getCacheDir()` 与 `Path.jar/js/py` 同根）。可变态落 `CacheRoot/run/<uid|shared>/…`（桌面 JVM 注 `kotv.user.runtime.root=CacheRoot/run`，bridge 按 tenant 落到 `…/jvm/{prefs,files}`）。Py/Node/Chromium 进程仍按 `RuntimeUserID` 分桶；本机空 uid 共用 `shared`。
- 换源时 `ResetScriptSpiders()` 销毁 JS/Python/Node 爬虫，避免旧进程状态污染新站；设置页「清理缓存」经 `SoftCancelAll` 后清 JAR 磁盘 + JS/Py/Node 内存与落盘目录。
- 配置地址以 `index.js` / `index.js.md5` 结尾时视为猫爪源包：下载校验后起 Node，`GET /config` 取 `video.sites`（忽略 read/comic/music/pan）；播放/弹幕改写为 `/node/<pkg>/…`。OPENWEB（`node_openweb.go`）：本机原样；远端 `/node/<pkg>/…?token=`（无媒体钥匙）并按调用方定向投递；路径首段登记根别名，`node_root_auth.go` 种 Cookie，页内绝对路径 API 反代 ActivePkg。Flutter 原样打开下发 URL。`messageToDart` → 本机 `/msg`。

### Java bridge（JAR 爬虫）

`bridge/` 源码两套编译产物（**不要**把桌面 JVM shadowJar 再 d8 进 APK）：

| | 桌面 / 其他平台 | Android |
|--|------|---------|
| 怎么编 | `bridge/build.sh` → `spider-bridge.jar`（含 `android/` stub） | Gradle 模块 `:kotv-bridge`（真实 Android SDK） |
| 加载宿主 | 捆绑 JRE + `URLClassLoader` 父优先；`--serve` HTTP `:9979` | 编进 **App ClassLoader**；`JarLoader` 直调 `SpiderBridge` |
| 站点 jar | 只吃 PC JVM `.class` 瘦包 | **同时**吃 CatVodSpider dex jar（`DexClassLoader(file, Path.jar(), Path.jar(), App)`）和 PC 瘦包（先 D8） |
| OkHttp | bridge **5.5.0**；请求自动 tag `clientId` | App `force` **5.5.0** |

- **dex 包**（`custom_spider.jar`）：jar 内仅 `com.github.catvod.{js,spider}` + `classes.dex`；外部符号须落在 CatVodSpider `jar/checkJar.ps1` 的 `$allowed`（如 `crawler/`、`android/`、`okhttp3/`、`com/whl/quickjs/`），由宿主 `:catvod`/`:kotv-bridge` 提供。R8 可能把站点依赖 merge 进 `spider.merge.*`，**不是**「jar 里完全没有 okhttp 字节码」。
- **PC JVM 瘦包**（CatVodSpider 的 pc 线等）：在同一宿主契约下，打包时 **额外** exclude bridge 宿主同名类 + 不打 okhttp/sardine fat（父 CL 用 bridge）；Android 侧再 D8。验收见 `verifyUniversalJar`，**不能**用 dex 包的 exclude 文案描述 PC 线。
- 站点约定 `com.github.catvod.spider.*`；配置 `csp_ClassName`。
- 多用户：桌面只启一台 `--serve`；安卓共用 `SpiderService`。可变态键 `Util.tenantKey()`（空 uid→`shared`）；切仓/`clearRuntimeJars` 只 `clearTenant`，`clearAll` 仅清缓存磁盘与 HardRestart。安卓 `Path.files()` 落 `files/kotv_tenant/<tenant>/`；桌面 stub 经 Context 落到 `run/<tenant>/jvm/files`。
- `KillUserRuntime` → RPC `clearTenant`（含 NetProfiles/Prefers/OkHttp 鉴权·跳转记忆）+ 擦 `UserJVMDir`，不杀 JVM。单次 JAR 传输失败不杀桥；进程死或**连续两次** `/health` 失败才重建。远端 hard 恢复只 KillUser，不跟 HardRestart。
- 离线释放：`session/leave` 与 `auth/logout` 即时 `releaseUserRuntime`；前端切回本机前先 `sessionLeave`。强杀未 Leave 时靠 Presence（30s Ping / **90s** 超时）兜底。
- 远端用户数据：历史/收藏/续播/直播收藏与上次频道、`vod`/`home`/`live` 选择按 `DataOwner` 分桶；仓库与直播**列表**共享，选中只记个人；其它设置缺键用**代码内置缺省**（`builtinDefaults`，不跟宿主当前内存）；`liveLoad` DTO 缓存按 Scope；共享仓/直播 **Upsert** 统一走 `Manager.SharedUpsertGate`；新增与删改、清共享缓存、主机路径备份/恢复需本机/管理员；宿主 `reloadConfig`（含清缓存重拉）临时 Bind 空 user，避免 Dedicated admin 污染宿主 Config/代理；leave `keep` 用 `settings.GetHost`；仓/直播 Note* 收拢在 `source_leave`。
- 再登录水合：Dedicated 会话 `bootstrapSession` 末尾 `rehydrateSessionSpider`（`SetConfigBase`/`SetNetConfig`/`EnsureRootJar` 写根路径）；主机换仓 `followHostSessions` / 清缓存 `restoreSessionSources` 均 Dedicated Bind 后再水合。
- `LoadJar` 只清当前租户 Go 侧 jar 就绪态 + 本 URL 无 md5 标记；`clearJar` 才全局 bump。包体仍共用 `JarPath`。Go→桥 HTTP（含 health/probe）共用 `localproxy.BridgeClient` Transport（超时靠 ctx）。
- 安卓 Py：`sess_key=userId#site#slot`；`/py/interrupt` 按 `userId` 清（空=`shared`），不误伤其它租户。HardRestart 的 `/jar/interrupt` 只清 `shared` Chaquopy（与 Go `clearSharedJsPy` 同口径），不动远端用户桶。
- `unloadJar`/`reloadJar` 按 jar 路径卸共享 ClassLoader，并 destroy **全体租户**下该 jar 的 spider 实例（包体共用；不按用户复制 CL）。
- SoftCancel：JAR 只断 in-flight、不清租户 Spider；Py/Node 另停 Scope 相关脚本进程。卡死靠**显式** `hard:true`（设置「卡死恢复」）/ `KillUserRuntime` / `clearTenant`（取消不自动升 hard）。
- 切源/切站：`loadConfig`/`setHome` 前 soft cancel；JS HTTP 与下载/CMS 可取消；SoftCancel 可 interrupt 该 clientId 的 `/jar/call` 线程；HardRestart 后全局 bump Go jar 就绪态并水合。
- `libquickjs-android-wrapper.so` 仅进 APK，桌面 JRE 不绑这套 JNI。

## 运行时捆绑

发行包把运行时放进引擎同级的 `runtime/`，**Java/Python 仅用捆绑路径**（不读 `JAVA_HOME`/系统 PATH）：

| 组件 | 用途 | 来源 / 说明 |
|------|------|------|
| JRE 21 | JAR 爬虫 | BellSoft Liberica 21（全平台一致） |
| Python 3.14 | Python 爬虫 | CPython standalone；Windows x64 用 PythonVista embed 以兼容旧系统 |
| Node | 猫爪源包 | 桌面 `runtime/node`（LTS；Win7 为 node18-win7）；安卓 jniLibs 捆绑 `libkotv_node.so` + `libnode.so` |
| 嗅探浏览器（目录 `runtime/chromium`） | 网页嗅探 / 解析 | 进程名不固定：macOS·Linux x64 多为 `chrome-headless-shell`；Win x64 为 `chrome.exe`（Win7 REWORK）；Win ARM64 为 CFT/snapshot；无捆绑时回落系统 Chrome/Chromium/Edge；Linux ARM64 通常仅系统；**Android 用 WebView，不捆绑** |
| FFmpeg | 媒体处理 | osxexperts / Gyan / BtbN |
| QuickJS | JS 爬虫 | CGO 编译进主程序，无单独目录 |

`prepare-runtime.sh` 下载并装配 `runtime/`（含 node）；桌面打包在缺 jre 或 node 时都会再跑一遍，发行包校验 `runtime/node`。查找顺序：可执行文件旁 `runtime/` → `KOTV_RUNTIME` 环境变量 → 开发态仓库 `runtime/`。

## 播放

| 引擎 | 平台 | 说明 |
|------|------|------|
| **MPV** | 全部原生平台：原生 `kotv_mpv`（iOS 经 MPVKit） | macOS：`vo=avfoundation`+ASBDL 垫 contentView.layer，开播不藏层、Flutter 黑遮至就绪；Win：`gpu-next`+子 HWND；Linux：X11 `wid`（Wayland 画面嵌入未接）；hwdec 由 `KotvMpvOpts.hwdecValue()`；碟片导航仅 Android；ISO 见 `disc_play.dart` |
| **FVP**（libmdk） | 桌面 / iOS（Android 仅 Exo + MPV） | 备选页内引擎，硬/软/自动解码列表由设置下发 |
| 外部播放器 | 全平台 | 安卓 Intent；桌面网格选本机视频应用后把当前播放地址（含代理）原样交给该应用；引擎 API 仅无 GUI 兜底 |

续播、单集循环基于媒体态（按 ScopeID 分桶）。

## 平台与构建

CI 在 **KOTV Build**（`github-action.yml`）统一构建：

| 平台 | job | 产出 |
|------|-----|------|
| Windows x64 | `build-win-amd64` | ZIP + Inno 安装包 |
| Windows x64（Win7） | `build-flutter-win7` | 同上加 `-win7` 后缀；子系统 6.01 + MSVCRT MinGW |
| Windows aarch64 | `build-win-arm64`（`windows-11-arm`） | ZIP + Inno |
| Linux x64 | `build-linux-amd64` | ZIP |
| Linux aarch64 | `build-linux-arm64`（`ubuntu-24.04-arm`） | ZIP |
| macOS arm64 | `build-mac-arm64` | DMG |
| macOS x64 | `build-mac-amd64` | DMG |
| Android | `build-android` | aarch64 / armv7 APK |
| Web | `build-web` | musl 静态 linux-x64 引擎 + `webapp/` ZIP |
| 群晖 DSM 7.2 | `synology-piece` → `synology-package` | 静态引擎 + Toolkit 运行时；组件×架构分 job，合并为 x86_64 / armv8 SPK |
| iOS | `build-ios` | 未签名 IPA |

> **Web / Win7 / 群晖是主 CI 内的 job**，并非独立 workflow。
> **iOS**：CI 打未签名 IPA（`build-ios`）。端上没有本机引擎，只做 UI 与播放：不能动态加载 JAR/DEX，也不能跑 JVM/Python/QuickJS。内容解析走远端 Go 引擎（共用 `/api/v1`）。未签名包不能直接装到真机。
> **大屏（leanback）**：当前无独立大屏构建，Android 仅手机/平板 APK。

打包脚本（`scripts/`）：

| 脚本 | 作用 |
|------|------|
| `prepare-runtime.sh` | 下载装配 `runtime/`（JRE/Python/Node/Chromium/FFmpeg） |
| `build-android-node-launcher.sh` | 安卓 Node 启动器 `libkotv_node.so` |
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
  flutter/android/kotv-bridge/  安卓宿主（dex 包 + PC 瘦包，编进 App CL）
  flutter/         Flutter UI（lib/ 业务，ios/android/macos/linux/windows/web 平台目录）
  scripts/         运行时准备 / 打包 / 安装
  runtime/         捆绑运行时（开发态；发行时随包）
  webapp/          Flutter Web 构建产物（CI 生成，gitignore）
  docs/ARCHITECTURE.md
```
