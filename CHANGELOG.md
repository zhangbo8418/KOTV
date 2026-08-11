# Changelog

## v0.1.0

- 首个 GitHub Actions 多平台发行包（Windows / Linux / macOS arm64 / amd64）
- Windows 捆绑运行时（Win7 尽力兼容）：Temurin JRE（含 Win10 UCRT + api-ms-win-core-path）、PythonVista、Chromium 109、FFmpeg 7.0、MSVCRT MinGW（QuickJS CGO）；Windows 主程序改用 go-legacy-win7 构建
- 捆绑 JRE / Python / Chromium / FFmpeg；QuickJS 内嵌主程序
- JAR 爬虫改为捆绑 JRE 常驻 `spider-bridge --serve`：JVM 只启动一次、与 UI 进程隔离，崩溃可自动拉起
- 详情/直播页内嵌播放：默认 media_kit MPV（桌面）/ ExoPlayer（Android）
- Windows QuickJS(CGO)：MSVCRT MinGW、`_WIN32_WINNT=0x0601`、static-libgcc，并做 Win7 依赖门禁
