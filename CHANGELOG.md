# Changelog

## v0.3.6

- 新增群晖 DSM 7.2 SPK（x86_64 / armv8）：Web 服务形态（engine + webapp）；**引擎与** Node/Python/JRE/Chromium 均由官方 Toolkit 在 CI 编译（x86_64 用 `geminilake`，armv8 用 `rtd1296`；非 musl / 非 Liberica 预编译）。Chromium 解析 CFT Stable 最新版编 headless_shell。
- CI 新增 Windows aarch64、Linux aarch64 桌面包；Linux x64 job 更名为 `build-linux-amd64`。
- 依赖：Go `1.27.4`（含 go-legacy-win7）；chromedp `0.24.0` / cdproto `0.160.12`；quickjs-go `0.7.8`；anacrolix/torrent `1.63.0`；golang.org/x/* 与 modernc.org/sqlite 跟最新；torrent 传递依赖可升则升（roaring/bitset/pion webrtc 等），`anacrolix/stm` 停在 `0.5.0`（`0.6` 与 dht/v2 不兼容）。Flutter 钉死收拢到 `scripts/kotv-flutter-pins.sh`：主线 `3.50.1`；Win8+ x64/arm64 `3.47.1` + DComp；Win7 `3.19.6`。Flutter 包与 `pubspec.lock` 同步到 Dart 3.13 上限；`html`/`riverpod`/`fvp`/`path_provider_android` 等钉死项不动。Android Media3 源改为钉 commit（上游 `release-1.11.0-fongmi` 分支已删）。CI Windows 工具链收拢为专用脚本。
- 版本号同源升至 `0.3.6`（pubspec `0.3.6+46`）。

## v0.3.5

- 桌面原生 MPV（`kotv_mpv`）：macOS underlay（vo=avfoundation）、Windows 子 HWND（vo=gpu-next）、Linux X11 wid；hwdec 由 Dart `KotvMpvOpts.hwdecValue()` 单点下发。桌面为薄宿主（轨表/排队/碟片等尚未齐；碟片导航仅 Android）。
- Windows Win8+：CI/打包灌入 DComp 补丁引擎制品（Flutter 钉 3.47.1 + `FLUTTER_WINDOWS_DCOMP` + 关 Impeller）；与 macOS 相同为 Flutter 播控盖在视频上（洞 `BlendMode.clear`）；**不**编入 Win7 播控壳。
- Windows Win7：库存引擎 + **进程内 GDI+** 播控（单 `kotv.exe`，无 WPF 副进程）；`KOTV_WIN7=1` 时编入 `win7_chrome_shell` + `kotv_win_chrome`，MethodChannel 驱动顶底栏/选集/直播栏/弹层/弹幕。样式契约与本应用 Flutter 播控一致；Win8+ 包不编链。API 收拢到 `kotv_win_chrome.dart`。字幕仍由 mpv/libass 画在视频 HWND。独立仓 [kotv-win7-mpv-chrome](https://github.com/zhangbo8418/kotv-win7-mpv-chrome) 仅作 UI 回归宿主，**不**打进本仓发行包。
- macOS：mpv API 离主线程；ASBDL 垫 contentView.layer；开播不因遮罩藏层（仅 Flutter 黑遮）；默认 videotoolbox；失败 ASBDL flush+补帧；进度 300ms 节流；软解 EDR。
- Win7 硬解直出经 `setProperty(hwdec=dxva2)`；关直出为 `auto`。
- CI：FFmpeg `dovi_convert` helpers；Linux EventChannel 签名；Windows 生成 `mpv.lib`（禁 MSVC 直链 .dll）；Win7 SDK 改用 `withOpacity`。
- 清理未链接多余 mpv 副本；iOS 仍走 media_kit。
- 版本号同源升至 `0.3.5`（pubspec `0.3.5+45`）。

## v0.3.4

- 管理控制台：分组策略、用量/主机指标、审核与角色/分组管理；管理台前端与字体资源收拢。
- 远端鉴权与网关：组策略下发、通知确认、注册审批等接口与 Flutter 侧对接。
- 版本号同源升至 `0.3.4`（pubspec `0.3.4+44`）。

## v0.3.3

- 硬切换集：`kotvStopPlayersForEpisodeSwitch` 统一先 pause 再卸文件，桌面 media_kit 不每集 dispose；直播切台复用同一路径；无缝仍走 playlist。
- 拆机收拢：`kotvReleaseOwnedMpv` + `kotvDisposeMpvPlayer` 为桌面/安卓卸会话唯一路径；去掉 softStop 与 dispose 叠 pause/stop；Win7 直出/换引擎/离页仍拆机。
- 桌面 libmpv 拆机门闩等待上限：超时置 stuck，拒再建 Player，提示「播放器异常，请重启应用」。
- 单桥韧性收拢：SoftCancel / KillUser / HardRestart 门面；切源可打断（loadConfig/setHome soft cancel、JS/Scope HTTP 可取消、按 clientId interrupt `/jar/call` 线程）；HardRestart 后 bump jar 就绪态并水合。
- 租户隔离：Android HardRestart `/jar/interrupt` 只清 `shared` Chaquopy（与 Go `clearSharedJsPy` 同口径），空 userId 视为 shared，不误伤远端用户桶。
- 资源复用：Go→桥 HTTP（含 health/probe）共用 `localproxy.BridgeClient` Transport；jar 包体仍 `cache_flight` / 公共 `JarPath`。
- 清理：去掉死 `interruptJar` / `shortTimeoutClient` / logging-interceptor；桌面 Prefers 驱逐改反射，kotv-bridge 可编。
- 版本号同源升至 `0.3.3`（pubspec `0.3.3+43`）。

## v0.3.2

- 版本号收拢：`pubspec` / `update.CurrentVersion` / Flutter 回退常量同源为 `0.3.2`；各打包脚本统一经 `kotv_engine_version_ldflags` 注入，关于/检查更新/运行库与产物名一致。
- 运行时隔离：JVM / Python / Node / QuickJS 按 `RuntimeUserID` 分桶；软取消与硬重启走统一门面，超时/放弃后回收忙进程，避免切集挂死互相串扰。
- 软解保留 GPU Texture 输出；开播 failover：非 soft → soft → 换引擎。
- 运行时用户隔离补齐：Chromium 按用户独立 user-data-dir；JVM Prefers/files 与 Python 工作目录进 `cache/run/<uid|shared>/`（包体仍公共）；取消/Kill 门面纳入嗅探。
- 修复共享 JVM 漏回放本机 `c:` 网络配置；SoftCancel 不再误毁租户 Chromium；嗅探分配与信号量同锁。
- 包体共享收拢：`cache/{jar,py,js,node}` 公共无 uid；Node data / JS Local 进 `cache/run`；远程 JS 模块内容寻址；下载 `doOnce` 合并并发。
- 爬虫取消/关停门面收拢（SoftCancelAll / ShutdownAllRuntimes / releaseUserRuntime）；interrupt* 不导出；打包前核对版本字面量同源。

## v0.3.1

- Win7 MPV：关直出与 Win10 同为 `hwdec=auto`（官方自选，无额外拒互通）；开直出仍 `dxva2`，不能直出时会话退回关直出（新建 D3D11 Player）。「硬解直出」仅 Win7 显示。撤回 ANGLE/FVP 的 DXGI HEVC 选卡。
- 撤回 RK/旧安卓退全屏 HWC park（接受旧机退全屏崩溃风险）；`setSurfaceLayerEnabled` 恢复 park 前逻辑。
- Android CI：打包后清 `flutter/build` 等中间产物再上传；APK `compression-level: 0`；按 ABI 拆 `android-aarch64` / `android-armv7` artifact。
- 开播 failover：非 soft → soft → 换引擎（自动档由引擎自选；挂死靠显式软解）。
- Node 首页：`homeVod` 失败/空体再试 `homeVideo`，真实错误上抛；空推荐不钉死 home 缓存；去掉误导性「没有返回推荐」横幅。
- Win7 全屏：子窗对齐失败继续重试；对齐后再确认踢一次（ANGLE/纹理晚落稳）。
- Node 切站：启动失败清掉 `stopping`，避免 Ensure/watch 空转无限转圈。
- 远程 OPENWEB：Go 统一代理（会话戳记、`/node/<pkg>/`、根别名反代 + Cookie）；本机不改写；Flutter 原样打开下发 URL。
- 下载列表已完成任务可点开播放（本机直读路径，远端 play 换成 `/file/`）。
- Node 切站：修复 watch 休眠后误杀新进程；未登记 api 时保留已起源包，避免 Win7 长时间转圈。
- MPV 无缝换集（桌面 media_kit + 安卓原生）：有排队时 `keep-open=no` 让列表自然前进（消片尾 pause）；无排队恢复 `yes` 以 `eof-reached` 报 completed；单集循环拒 queue；手动下一集仍走 playlist-pos/next。
- Win7 系统全屏：子窗按客户区对齐，未对齐延后重试（去掉固定毫秒盲踢）；详情/直播进全屏时序收拢。
- 本机站点/网盘凭证落 `/TV/`；远端 `/TV/s_u_<用户名>/`（跟登录名，不跟账号 UUID）；不建 `s_c_*`。目录名收拢到 `Util.tvDirName` / `paths.TVDirName`。子 goroutine 用 `Bind(Snapshot())` 带上 username。全部清理：`ui/` 只留 `client.json`；TV 删 `s_c_*` 与旧 `s_u_<uuid>`。
- 安卓清理缓存：宿主清 `cacheDir` 下 jar/js/py/node、`run` 可变态、epg/jpa/mpv/mpv-cache/proxy、`codeCache/kotv_site_jars` 与 Exo；全部时按 `IsLegacyTVDir` 删外置遗留 TV 桶（Go 扫 `filesDir/KOTV`）。

## v0.3.0

- 桌面详情双击：内嵌 → 全窗口 → 系统全屏 → 内嵌。
- 猫影视 / 猫爪 Node 源：配置识别 `video.sites` 与 `index.js(.md5)`；桌面捆绑 Node（Win7 为 node18），安卓 jniLibs 直接集成 `libkotv_node.so` 与 `libnode.so`；播放走 `/node/<pkg>/` 反代，支持 toast / 弹幕推送 / 播放信息 / profile / 打开网页等回调。打包强制校验 Node 已编入。安卓起 Node 子进程注入 `LD_LIBRARY_PATH`；环境信息桌面报 Node 路径，安卓只报 `libkotv_node`（不报绝对路径）。配置加载超时透出引擎错误，不再误报「地址无效」。Win7 起 Node/python/java 子进程带 `CREATE_NO_WINDOW`；`Status` 对 node 与 java/python 一样只报路径，不再每次 settings 执行 `node -v`（避免所有源场景闪 CMD）。`resolveSitePaths` 不再把 `/spider/…` 拼成 http；home 下发 filter、POST homeVod/homeVideo（无路由则互为回退）；按 api 前缀分派 Node（含 type=4）；Node 推送（type=4）跳过 home/search，缺失路由返回空；空首页可搜站提示使用顶部搜索。
- 已选中的集再点进入全屏；字幕「自动」勾选状态修正；播放返回 / 切 Tab：短超时 flush 与软停，硬释放后台执行。
- 网盘下载：302 重挂 Cookie；单线程；起播回包 `cloud` 后入下载列表；完成态可点开播放（本机直喂，远端走 play 换成 `/file/`）。
- 弹幕：缓冲/暂停不投，真播放后投；小幅 position 落后不清屏；猫爪 danmuPush 与集加载共用加载入口，await 后再认推送，勿二次拉取覆盖。
- 猫爪远端：播放 JSON / 弹幕走 `/node/<pkg>/`；OPENWEB 本机不改写，远端由引擎改写为 `/node/<pkg>/…` 并按调用方定向投递；页内绝对路径根别名动态反代 + token/Cookie 鉴权。Flutter 原样打开下发 URL。下载列表本机路径含 `#`/`$` 时不再误拆集。
- 安卓 FVP：进出全屏串行；退全屏先 hold 整屏几何，量槽后再缩 Positioned。
- 播放信息：片源缺 colorInfo 时用 codecs/DV profile 补色彩标签；Exo「· 隧道」仅跟 `isTunnelingEnabled`。
- 桌面 MPV/FFmpeg（AV3A）与 fvp 跟进上游；Win7 线 fvp 同步，仍用 Flutter 3.19 + SDK 放宽。
- CI：fvp 0.40.0 的 disposeAsync / `_untilCancelled(prepare)` 与 X-KOTV-Prepare-Ms 补丁锚点；FFmpeg bdf17191 的 libear（arcdav3a.pc / extra-libs）；Linux libaribcaption 在 CMake 4 下补 CMAKE_POLICY_VERSION_MINIMUM；桌面 libplacebo 跟到 v7.387.0（匹配 mpv ada80027）；iOS 先 pub get 再写本地 mdk podspec，避免与 fvp `mdk ~> 0.39` 冲突；安卓跳过上游 MediaCodec 已内置的 output 序列化补丁；Win7 mpv 补丁跟进 `PathAllocCanonicalize`；macOS arm64 运行时 ffmpeg 改 eugeneware 静态包（旧镜像 404）。
- 远程前端：按协议号握手，账号密码加密传输，记住登录与后端身份；未登录不能进入任何页面，连不上不改地址。
- 远端每个接口都要鉴权，设备与遥控类接口只给管理员；下载按用户隔离，远端会话恢复用户自己的仓与首页。
- 引擎先开端口再后台加载点播配置，断网时也能连上本机后端；首页加载只转圈。
- 本机 9978 端口被别的程序（如其它影视应用）占着时立即提示，不再无限转圈；引擎也不再反复拉起。
- 安卓 MPV：Rockchip 与 Android 8.0 以下硬解直出，全屏黑边不再透出详情页；播完自动播下一集。
- Windows MPV：硬解交给 mpv 官方的自动选择；Win10 及以上的 libmpv 不再按 Win7 目标编译，也不再打 Win7 补丁。
- Win7 MPV：「硬解直出」默认关：关=`d3d11va-copy` 链，ANGLE D3D11；打开后 ANGLE D3D9 + `dxva2`，10 位 / Intel 四五代 H265 拒绝互通后直接软解（不经 `dxva2-copy`）。开关在设置、详情页播放器、直播与回看（软解时不显示）。
- iOS 系统播放器：地址不带 .m3u8 后缀的 HLS 也按 HLS 打开。
- 开播无画面时：各内置引擎（含桌面 MPV）硬解无画面先改「自动」再试一次（只对这次播放），再换下一个内置播放器，不再软硬互换；Exo 不再自己软解重建，选「硬」时视频只用硬件解码器。播放信息里的解码器名一律大写。
- 「循环播放视频」由详情页统一保存，各平台各播放器换集、换播放器后仍生效；Exo 改用自带的单集循环，不再播完重开。

## v0.2.2

- 下载页边距与首页一致；播放页查看任务叠层打开，返回仍回播放。
- 主 Tab：桌面还原 Material 转场，安卓关闭切换动画；下载设置与文案收拢。
- 「我的」检测爬虫真正调用引擎检测；已入队剧集不可再选（引擎侧去重）。
- 点播首页/分类、目录、历史、收藏、下载支持下拉刷新；空列表也可下拉。
- 目录浏览只走空 path 列表；版本/tools 文案与下载选项标签再收拢。

## v0.2.1

- iOS 没有本机引擎时不再把 127.0.0.1 探满超时。远端连不上就停，不清掉已保存的地址。连不上或登录失败弹窗说明，登录框保持打开。已有地址填进连接框；地址可用时先登录，取消后才回到连接页。
- Win7 系统全屏回到消息循环再改子窗口，退出时按进入前的窗口矩形还原。

## v0.2.0

- 版本号收到 0.2.0。健康检查和「我的」页跟引擎版本走，不再各写一份。
- iOS 顶栏留在状态栏下面，源名和海报里的彩色表情能显示。发行文件名跟这份版本号。

## v0.1.0

- 首个 GitHub Actions 多平台发行包（Windows / Linux / macOS arm64 / amd64）
- Windows 捆绑运行时（Win7 尽力兼容）：Temurin JRE（含 Win10 UCRT + api-ms-win-core-path）、PythonVista、Chromium-for-windows-7-REWORK、FFmpeg 7.0、MSVCRT MinGW（QuickJS CGO）；Windows 主程序改用 go-legacy-win7 构建
- 捆绑 JRE / Python / Chromium / FFmpeg；QuickJS 内嵌主程序
- JAR 爬虫改为捆绑 JRE 常驻 `spider-bridge --serve`：JVM 只启动一次、与 UI 进程隔离，崩溃可自动拉起
- 详情/直播页内嵌播放：默认 FVP（桌面）/ ExoPlayer（Android）；内置 MPV 改原生通道
- Windows QuickJS(CGO)：MSVCRT MinGW、`_WIN32_WINNT=0x0601`、static-libgcc，并做 Win7 依赖门禁
