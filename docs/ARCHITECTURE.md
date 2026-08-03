# 架构决策：Flutter UI + Go 引擎

## 结论

**Flutter UI + Go 引擎核**（`cmd/engine` / 可嵌入库 + 现有 `internal/spider`）。

曾考虑「全量迁 Java/TV 栈」因跨端成本否决。**否决的是用 JVM 当主引擎，不是砍 JS/PY。**

## 爬虫能力（都在 Go 里）

| 类型 | 实现 | 桌面 | Android | iOS IPA（侧载） |
|------|------|------|---------|-----------------|
| CMS 0/1/4 | Go HTTP | ✅ | ✅ | ✅（Go 进包即可） |
| **JS**（`*.js`） | Go 内嵌 **QuickJS**（CGO） | ✅ | ✅ | ❌（产品策略：iOS 不跑本地爬虫） |
| **Python**（`*.py`） | 捆绑 / 嵌入 `runtime/python` | ✅ | ✅ | ❌（产品策略：iOS 不跑本地爬虫） |
| **JAR**（`csp_*`） | JRE + Dex/ClassLoader 系 bridge | ✅ | ✅ | ❌ **本机动态加载 JAR 不可行**（无 Android ART / 常规 JVM 宿主） |

### iOS 澄清（重要）

1. **IPA 能跑 Go**：不是「iOS 不能跑 Go」。侧载 IPA 可把 Go 编成静态库 / `gomobile` / 同进程引擎嵌进 App。受限的是 App Store 策略与工程嵌入方式，不是语言本身。
2. **当前产品策略**：iOS 端不提供本地爬虫能力（JS/PY/JAR 不在端侧运行），仅负责前端展示与播放链路。
3. iOS 启动后应先连接可用后端服务（局域网或公网均可），由后端完成内容抓取。

## 形态

```text
Flutter App（含 iOS IPA）
   │  HTTP /api/v1 + X-Kotv-Client-Id
   ▼
Go Engine（可部署到服务器，多前端并发）
   ├─ CMS
   ├─ JS  → QuickJS worker 池（同站可并行）
   ├─ PY  → Python 进程池（同站可并行）
   └─ JAR → HTTP 多路 bridge（桌面/安卓；可并发，按 client 软取消）
```

### 多前端 / 服务器并发

| 能力 | 说明 |
|------|------|
| `X-Kotv-Client-Id` | Flutter 持久化身份；API / ui/poll / postMsg 按客户端隔离 |
| **点播会话** | 有 clientId 时各自持有 ephemeral `config.Manager` + `SiteService`（Ready/Source/home）；空 clientId 仍用共享 `App.Config` |
| **直播 / 媒体态** | 有 clientId 时各自持有 `live.Service` 与媒体元数据；`/media` 与 `remote.SetMediaStore` 按 clientId 分桶 |
| **遥控队列** | control / search 按 clientId 分桶；`/action` 可带 `clientId`；遥控页可选目标客户端（空=广播已知客户端） |
| **OkHttp net** | 点播配置 headers/proxy/hosts/doh 按 clientId 写入 bridge `NetProfiles`；ephemeral 换源也会下发，互不覆盖 |
| **会话恢复** | `clientId` 持久在 Flutter；上次点播源/首页写入引擎 `data/client_sessions.json`，进程重启后首次请求自动恢复 |
| **远端鉴权** | `settings.remoteAuth` 开启后非本机请求需 `Authorization: Bearer`；`/admin` 管理用户；`allowRegister` 可开关注册 |
| **每用户运行时** | **脚本文件**（JAR/Py/JS 下载缓存）全局共享；**引擎进程**仅远端租户独立（本机永远共享一套 JVM/Py/JS）。`session/leave` / 90s 无心跳 → 只杀该用户引擎；换源超时 → `RestartUserRuntime` |
| 换源 | ephemeral 不写 `settings.VOD`、不持久化共享 DB home；不清全局脚本缓存（软取消当前 client） |
| JAR | 桌面 `--serve` 为本地 HTTP（对齐 Android `:9979`）；jar 文件按 URL MD5 全局缓存，各用户 JVM 各自加载 |
| Py / JS | 脚本按 api 哈希全局缓存；远端每用户独立进程池，本机共享池 |
| 取消 | `/api/v1/cancel` 只软取消**当前 client**；远端卡死才 Kill 该用户引擎 |
| JS | `getClientId()` / `postMsg(msg)` 宿主 API，路由回正确前端 |

### 本地 vs 远端

| | 本地（loopback / 未开 remoteAuth） | 远端租户（remoteAuth 且非本机已登录） |
|--|--|--|
| 登录 | 不需要 | 用户名密码 → token |
| 爬虫脚本 | 全局共享磁盘缓存 | 同一套全局缓存 |
| JAR/Py/JS **引擎** | **共享** 单 JVM + 池 | **每用户独立** 进程 |
| App 关闭 | `/api/v1/shutdown` 关整引擎 | `session/leave` 只杀该用户引擎 |
| 管理 | — | `/admin` 用户 CRUD、注册/鉴权开关 |

仍共享：桌面 Go embed 播放器单例、用户设置全局代理（`settings.Proxy`）、遥控 push/弹幕偏广播。直播树/媒体态仅进程内保留（重启不恢复）。

## 平台取舍

| 平台 | 策略 |
|------|------|
| 桌面 | Flutter + 本机 Go 进程（JS/PY/JAR 全开） |
| Android / TV | 同上 + 遥控器 |
| iOS | Flutter + Go（仅 UI/播放）；启动后先连接可用后端服务 |
| 直播 | 首期占位 |

工程现状：桌面/安卓已用独立 `cmd/engine` 进程；iOS 嵌入（gomobile/静态链）为下一刀，开发期可连接任意可达后端联调。

## JAR：PC + Android 对齐 FongMi TV / [CatVodSpider](https://github.com/FongMi/CatVodSpider)

官方模型（TV `catvod` + CatVodSpider `app/`）：

| 角色 | 官方怎么做 |
|--|--|
| **宿主** | TV `catvod` 进 **App ClassLoader**：`Spider` ABI、`OkHttp`/`Util`/`Path`/`Init`/`Proxy`、okhttp3 **5.4.0**（`force`） |
| **站点 jar** | `assembleRelease` + R8（`-flattenpackagehierarchy spider.merge`）+ apktool → 只留 `spider/**` + `js/**`（+ merge）的 **DEX** jar |
| **加载** | 标准父优先 `DexClassLoader(parent = App.classLoader)`（`TV/.../JarLoader.java`） |
| **站点自有 OkHttp/Util** | 源码在 CatVodSpider `app/.../net`、`utils`；**出包改名进 `spider.merge`**，不与宿主同 FQCN 冲突；包装内 `Spider.client()` → 宿主 OkHttp |

KOTV 不能把 Spider 塞进 Flutter App（桌面要共用），因此把 **TV catvod 宿主角色**放进 **bridge**（源码以 TV catvod 为基准，并吸收 CatVodSpider 站点常用 API）：

| | 桌面 | Android |
|--|------|---------|
| bridge（≈ TV catvod） | `URLClassLoader` **父优先**；`--serve` = **HTTP 多路** | 打包期 d8 → APK assets → 父优先 `DexClassLoader` + NanoHTTPD `:9979` |
| 站点 jar | JVM `.class` 瘦包（Java 17） | `JarDexer`（D8）→ sealed dex → 父优先 |
| 注入 | 无 | `JarLoader` → `setSiteJarEnsureMethod`（D8 转站点 jar） |
| OkHttp | bridge **5.4.0**；请求自动 tag `clientId` | App `force` **5.4.0**（与 TV 一致） |

JVM 瘦包无法走 R8 `spider.merge`，因此站点 **exclude** 宿主同名类（`Util`/`OkHttp`/`Json`/`Path`/`Init`/`Proxy`/`crawler`/`UiBridge`），父优先直接用 bridge——运行语义对齐官方「宿主提供 API」。

站点约定：`com.github.catvod.spider.*`；配置 `csp_ClassName`。TV 专用 DEX `custom_spider.jar` 是另一条打包线，宿主模型相同。

**不要**把 Spider 类挪进 Flutter App。Android 专属能力（D8 / seal）用 Method 注入挂在 App CL。

## 播放：Exo / MPV / IJK 与 TV 的差异

- **Exo**（Android）：stock Media3；软硬解 = `EXTENSION_RENDERER_MODE` + 软件 MediaCodec 优先；无 TV 私有 `setFfmpegVideoPrefer`。
- **IJK**（Android）：`mediacodec*` 软硬解；切换解码须重开（选项仅在 `setDataSource` 前生效）。
- **MPV**（media_kit，Android + 桌面）：

| 选项 | Android | 桌面 PC |
|------|---------|---------|
| hwdec / 解码方式 | ✅ | ✅（`auto`/`no`；系统硬解） |
| mpv.conf | ✅ | ✅ |
| Vulkan | ⚠️ 尽力（media_kit 写死 EGL） | ⚠️ 可设 `gpu-api=vulkan`，vo 仍须 `libmpv` |
| gpu-next | ✅ `vo=gpu-next` | ❌ Flutter Texture 必须 `vo=libmpv` |

详见 [`flutter/README.md`](../flutter/README.md)。
