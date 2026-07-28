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

- Flutter 官方对 Win7 已非主支持平台，仓库提供 `Flutter 3.24.5` 的实验构建线。
- 使用 GitHub Actions 工作流：`.github/workflows/flutter-win7.yml`。
- 锁 `Flutter 3.24.5`；补丁在 `.github/patches/`，由 `scripts/patch-flutter-sdk.sh` 打入 SDK。
- **Win7 必须**用 `scripts/install-flutter-win7-engine.ps1` 替换 `windows-x64-release` engine（否则 `kotv.exe` 会因 `GetHostNameW` 无法启动）。
- 该产物为 `KOTV-flutter-win7-experimental-*.zip`，用于 Win7 真机回归与补丁迭代。

```bash
cd flutter
flutter build ipa --no-codesign
```
