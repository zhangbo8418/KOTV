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

## 字体

**仅 Win7 发行包**内嵌 Noto（CJK + 彩色/黑白 emoji，约 28MB）；Win10+/macOS/Linux/Android 用系统字体。Win7 包在 Win10/11 上仍走彩色 emoji 回退链，不会误用黑白 NotoEmoji。

## Android APK

需要 `ANDROID_NDK_HOME`（或已安装 Android SDK NDK）。打包：

```bash
./scripts/package-flutter-android.sh
```

产物：

- `dist/KO影视-{version}-aarch64.apk`
- `dist/KO影视-{version}-armv7.apk`

无本机 NDK 时推到 `restore-sidecar`，由 GitHub Actions 编译（workflow：`KOTV Flutter Android`），在 Actions → Artifact 下载；也可手动 **Run workflow**。

其它平台发行名同样为 `KO影视-{version}-{arch}.{ext}`（如 macOS `KO影视-0.1.0-aarch64.dmg`，Win7 `KO影视-0.1.0-x86_64-win7.zip`）。

- 引擎：`libkotv_engine.so` 双 ABI 进 `jniLibs`，由 Flutter 拉起 sidecar
- 爬虫：同进程 `:9979` SpiderService（JAR/PY/嗅探）
- **迅雷**（对齐 TV）：`magnet` / `thunder://` / **`ed2k`** / `.torrent`（及解码后的 ftp 等），`libs/thunder-release.aar`，**不走 anacrolix**
- 播放默认：ExoPlayer；可选手动切 MPV / ijk
- 迅雷 AAR：`flutter/android/app/libs/thunder-release.aar`（可从 TV `app/libs/` 同步）

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
- 产物为 `KO影视-{version}-x86_64-win7.zip`，用于 Win7 真机回归。

```bash
cd flutter
flutter build ipa --no-codesign
```
