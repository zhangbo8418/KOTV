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
   │  HTTP /api/v1  或  同进程嵌入
   ▼
Go Engine
   ├─ CMS
   ├─ JS  → QuickJS
   ├─ PY  → Python runtime（打进包）
   └─ JAR → 仅桌面/安卓；iOS 不启用本地爬虫
```

## 平台取舍

| 平台 | 策略 |
|------|------|
| 桌面 | Flutter + 本机 Go 进程（JS/PY/JAR 全开） |
| Android / TV | 同上 + 遥控器 |
| iOS | Flutter + Go（仅 UI/播放）；启动后先连接可用后端服务 |
| 直播 | 首期占位 |

工程现状：桌面/安卓已用独立 `cmd/engine` 进程；iOS 嵌入（gomobile/静态链）为下一刀，开发期可连接任意可达后端联调。

## JAR：PC + Android 共用 bridge（不要照搬 TV）

站点爬虫 jar **约定只含 JVM `.class`、不含 dex**（同一份给桌面和安卓用）。Android ART 不能直接加载，必须经 App 侧 `JarDexer`（嵌入 **D8 / `com.android.tools:r8`**）转成含 dex 的 sealed jar；站点字节码可用 Java 17。

TV（FongMi）把 Spider ABI 放进 **App ClassLoader**。KOTV 要 **同一份 `spider-bridge.jar` 跑桌面 JVM 与 Android ART**，所以 Spider ABI 留在 bridge 内：

| | 桌面 | Android |
|--|------|---------|
| bridge | `URLClassLoader` / child-first | 打包期 d8 → APK assets → `DexClassLoader` |
| 站点 jar | 直接加载 `.class` | **始终** `JarDexer`（D8）→ sealed dex jar → `DexClassLoader` |
| 注入 | 无 | `JarLoader` → `setSiteJarEnsureMethod(Method)`（防 R8 把 JarDexer 收成 `u1.a`） |

站点爬虫约定（KOTV 新线）：**一份 JVM `.class` 瘦包**（无 `android/**` / 无 dex）。PC 直载；Android 经 `JarDexer` 转 dex + **child-first** `DexClassLoader`（与桌面一致，避免站点 `OkHttp`/`Util` 被 bridge 盖住）。TV 专用 DEX 包是另一条产品线，不要当双端通用包。

**不要**把 Spider 类挪进 Flutter App：桌面无法共用。Android 专属能力（D8 / seal / child-first DexCL）用 **Method 注入** 挂在 App CL。

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
