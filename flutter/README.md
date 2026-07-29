# KO影视 Flutter UI

- UI：KO影视主题壳 + 深色色板
- 引擎：**Go**（桌面/安卓：`cmd/engine` 进程；iOS：仅做前端与播放，内容抓取走远程引擎）
- **爬虫**
  - 桌面 / Android：CMS + JS + PY +（可选）JAR
  - iOS：不提供本地爬虫能力（JS/PY/JAR 均不在端侧运行）
- 其它：直播占位；历史本机缓存；IPA 侧载

## 联调

```bash
./scripts/run-flutter.sh macos
```

## 遥控器（安卓）

实体遥控方向键 + 手机打开 `http://<引擎IP>:9978/` Web 遥控。

## iOS

- 仅负责前端展示与播放链路。
- 启动后先连接可用后端服务（可为局域网或公网服务器）。
- 内容抓取由后端服务完成。

## Windows 7（实验线）

- **官方最后支持 Win7 的稳定版是 Flutter 3.19.x**；Win7 CI 钉 `3.19.6`（见 `.github/workflows/flutter-win7.yml`）。
- 主线（Win10+ / macOS / Linux）仍用较新 Flutter（`sdk: ^3.5.4`）；Win7 构建前会跑 `scripts/adapt-flutter-win7-sdk.sh` 临时放宽约束。
- **不再**对 Win7 线替换 RustDesk 魔改 engine（那只修启动 `GetHostNameW`，管不了加载后闪退）。
- 桌面 **内置 MPV** 使用 Flutter **media_kit 自带 libmpv**（不进 `runtime/`）。
- Python 爬虫依赖与 TV `chaquo/requirements.txt` 对齐（`scripts/python-requirements.txt`），打进 `runtime/python`。
- UI 闪退时由看门狗杀掉残留 `kotv-engine`（见 `engine_launcher.dart`）。
- 产物为 `KOTV-flutter-win7-experimental-*.zip`，用于 Win7 真机回归。

```bash
cd flutter
flutter build ipa --no-codesign
```
