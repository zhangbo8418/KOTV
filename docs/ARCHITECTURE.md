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

详见 [`flutter/README.md`](../flutter/README.md)。
