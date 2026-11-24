import AVFoundation
import Metal
import QuartzCore
#if canImport(Libmpv)
import Libmpv
#endif
#if os(macOS)
import Cocoa
typealias KotvMpvWindow = NSWindow
private typealias KotvMpvColor = NSColor
#else
import Flutter
import UIKit
typealias KotvMpvWindow = UIWindow
private typealias KotvMpvColor = UIColor
#endif

/// macOS / iOS 原生 libmpv，视频层垫在 Flutter 表面之下：
/// - 默认 `vo=avfoundation`：AVSampleBufferDisplayLayer（ASBDL），VideoToolbox 帧连同杜比视界 RPU
///   交给系统显示层；
/// - Vulkan：`vo=gpu-next` + `gpu-context=moltenvk`，wid 传 CAMetalLayer。libmpv 以 drawableSize 为
///   渲染尺寸、以层上的 `mpvEDRHeadroom` 判断屏幕能否显示 HDR、层隐藏时不出帧，EDR 由 MoltenVK 设置。
///
/// 宿主：macOS 把容器层 `insertSublayer(..., at: 0)` 进 contentView.layer 并涂黑；
/// iOS 在窗口最底插一个黑底宿主视图，Flutter 视图改为不透明=否。Dart 洞清成透明露出画面。
/// 几何：`updateFrame` 按洞矩形摆容器层；续播点在 FILE_LOADED 后再 seek（勿 loadfile start=）。
/// EDR：HDR 直出开且 sigPeak>1 即开，软硬解一样（VT 帧缺省的色彩标记由补丁 0053 按 mpv 的推断补齐）。
/// 所有 `mpv_*` 仅在 [mpvQueue]（VO 会 `dispatch_sync` 主队列，主线程同步调 mpv 会死锁）。
final class KotvMpvCore {
  /// macOS：包里带了 MoltenVK ICD（AppDelegate 已写入 VK_ICD_FILENAMES）且有 Metal 设备。
  /// iOS：MoltenVK 静态链入 libmpv，有 Metal 设备即可。
  static var isVulkanAvailable: Bool {
    guard MTLCreateSystemDefaultDevice() != nil else { return false }
    #if os(macOS)
    guard let raw = getenv("VK_ICD_FILENAMES") else { return false }
    return String(cString: raw).split(separator: ":").contains {
      FileManager.default.fileExists(atPath: String($0))
    }
    #else
    return true
    #endif
  }

  let vulkan: Bool
  private weak var window: KotvMpvWindow?
  #if os(iOS)
  /// 窗口最底的黑底宿主；容器层挂在它的 layer 上。
  private var hostView: UIView?
  #endif
  private var containerLayer: KotvMpvContainerLayer?
  private var videoLayer: CALayer?
  private var displayLayer: AVSampleBufferDisplayLayer? { videoLayer as? AVSampleBufferDisplayLayer }
  private var metalLayer: CAMetalLayer? { videoLayer as? CAMetalLayer }
  private let mpvQueue = DispatchQueue(label: "com.bobo.kotv.mpv")
  private var mpv: OpaquePointer?
  private var wakeup: (() -> Void)?
  private var positionTimer: DispatchSourceTimer?
  private var lastSigPeak = 0.0
  /// 会话 HDR 偏好；EDR 门闩见 [updateEDRMode]。
  private var hdrEnabled = true
  private var isVisible = false
  /// macOS：窗口被遮挡；iOS：App 退到后台。
  private var layerHiddenForOcclusion = false
  private var layerHiddenForScreenSleep = false
  private var destroyed = false
  /// 最近一次洞矩形（已转成宿主层坐标）；无参 updateFrame 时复用。
  private var lastHoleFrame: CGRect?
  /// loadfile 勿带 start=（VT+avfoundation 会卡住不出 FILE_LOADED）；FILE_LOADED 后再 seek，且不 pause。
  private var pendingStartMs: Int64 = 0
  #if os(macOS)
  private var playbackActivity: NSObjectProtocol?
  #endif
  private var pausedState = true

  /// 遮挡或屏幕睡眠时需要藏层。
  private var hasLayerHideReason: Bool {
    layerHiddenForOcclusion || layerHiddenForScreenSleep
  }

  var onEvent: (([String: Any]) -> Void)?
  var isReady: Bool { mpv != nil && !destroyed }

  init(vulkan: Bool) {
    self.vulkan = vulkan
  }

  /// 运行期开关 HDR 直出（影响 EDR 与 target-colorspace-hint）。
  func setHdrEnabled(_ enabled: Bool) {
    hdrEnabled = enabled
    asyncMpv { [weak self] in
      guard let self, let handle = self.mpv else { return }
      mpv_set_property_string(handle, "target-colorspace-hint", enabled ? "auto" : "no")
    }
    updateEDRMode(sigPeak: lastSigPeak)
  }

  /// 主线程建 layer；mpv 初始化见 [startMpv]。
  func prepareLayers(in window: KotvMpvWindow) -> Bool {
    assert(Thread.isMainThread)
    if containerLayer != nil {
      self.window = window
      attachContainer(frame: lastHoleFrame ?? containerLayer?.frame)
      return true
    }
    self.window = window

    let container = KotvMpvContainerLayer()
    container.backgroundColor = KotvMpvColor.black.cgColor
    container.isOpaque = true
    #if os(macOS)
    container.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    #endif

    let layer: CALayer
    if vulkan {
      layer = CAMetalLayer()
    } else {
      let asbdl = AVSampleBufferDisplayLayer()
      asbdl.videoGravity = .resizeAspect
      layer = asbdl
    }
    layer.isOpaque = true
    layer.backgroundColor = KotvMpvColor.black.cgColor
    container.addSublayer(layer)
    container.videoLayer = layer

    containerLayer = container
    videoLayer = layer
    guard attachContainer(frame: nil) else {
      containerLayer = nil
      videoLayer = nil
      return false
    }
    layer.frame = container.bounds
    setContainerHidden(true)
    observeHostNotifications(window)
    return true
  }

  func startMpv(completion: @escaping (Bool) -> Void) {
    mpvQueue.async { [weak self] in
      guard let self, !self.destroyed else {
        completion(false)
        return
      }
      if self.mpv != nil {
        completion(true)
        return
      }
      guard let layer = self.videoLayer else {
        completion(false)
        return
      }
      let ok = self.setupMpv(layer: layer)
      if ok { self.startPositionTimer() }
      completion(ok)
    }
  }

  func setVisible(_ visible: Bool) {
    assert(Thread.isMainThread)
    guard containerLayer != nil else { return }
    isVisible = visible
    if visible {
      attachContainer(frame: lastHoleFrame ?? containerLayer?.frame)
      beginPlaybackActivity()
    } else {
      endPlaybackActivity()
    }
    setContainerHidden(!visible || hasLayerHideReason)
    if visible {
      recoverDisplayLayerIfNeeded()
    }
  }

  /// Dart 逻辑坐标（顶左原点）→ 宿主层坐标。nil/无效则复用上次洞或铺满。
  func updateFrame(_ rect: CGRect? = nil) {
    assert(Thread.isMainThread)
    let target: CGRect
    if let rect, rect.width > 1, rect.height > 1, let converted = hostRect(fromFlutter: rect) {
      target = converted
      // 即使 layer 尚未建好也先记下洞，open/setVisible 时用。
      lastHoleFrame = target
    } else if let lastHoleFrame {
      target = lastHoleFrame
    } else if let bounds = hostBounds {
      target = bounds
    } else {
      return
    }
    guard let containerLayer else { return }
    withoutLayerAnimations {
      containerLayer.frame = target
      updateContentsScale()
    }
  }

  func asyncMpv(_ body: @escaping () -> Void) {
    mpvQueue.async { [weak self] in
      guard let self, !self.destroyed else { return }
      body()
    }
  }

  func setProperty(_ name: String, _ value: String) {
    guard let handle = mpv else { return }
    // video-zoom 会逼 vo_avfoundation 走 Core Image，毁掉 HDR/DV 直出。
    if name == "video-zoom" || name == "vo" || name == "wid" || name == "gpu-api"
      || name == "gpu-context" || name.hasPrefix("avfoundation-")
    {
      return
    }
    if name == "hdr-enabled" {
      let on = value == "yes" || value == "true" || value == "1"
      DispatchQueue.main.async { [weak self] in self?.setHdrEnabled(on) }
      return
    }
    if name == "target-colorspace-hint" {
      let on = value != "no" && value != "false" && value != "0"
      hdrEnabled = on
      mpv_set_property_string(handle, name, value)
      updateEDRMode(sigPeak: lastSigPeak)
      return
    }
    mpv_set_property_string(handle, name, value)
  }

  func command(_ args: [String]) {
    guard let handle = mpv, !args.isEmpty else { return }
    var cArgs: [UnsafePointer<CChar>?] = args.map { strdup($0) }.map { UnsafePointer($0) }
    cArgs.append(nil)
    defer {
      for p in cArgs {
        if let p { free(UnsafeMutablePointer(mutating: p)) }
      }
    }
    cArgs.withUnsafeMutableBufferPointer { buf in
      _ = mpv_command(handle, buf.baseAddress)
    }
  }

  func open(url: String, startAtMs: Int64 = 0) {
    pendingStartMs = max(0, startAtMs)
    // loadfile 前显示层；遮罩由 Dart 洞负责。
    DispatchQueue.main.async { [weak self] in self?.setVisible(true) }
    // replace 即可换片；勿 stop（会打断无缝换集），勿 pause。
    // 勿把 start= 写进 loadfile：硬解 VT 在 underlay 上会长期不出 FILE_LOADED。
    command(["loadfile", url, "replace"])
    command(["set", "pause", "no"])
    pausedState = false
  }

  func play() {
    command(["set", "pause", "no"])
    pausedState = false
    DispatchQueue.main.async { [weak self] in
      guard let self, self.isVisible else { return }
      self.beginPlaybackActivity()
    }
  }

  func pause() {
    command(["set", "pause", "yes"])
    pausedState = true
    DispatchQueue.main.async { [weak self] in self?.endPlaybackActivity() }
  }

  func stop() {
    command(["stop"])
    pausedState = true
    DispatchQueue.main.async { [weak self] in self?.setVisible(false) }
  }

  func seek(positionMs: Int64) {
    let sec = String(format: "%.3f", Double(positionMs) / 1000.0)
    command(["seek", sec, "absolute"])
  }

  func setVolume(_ volume: Double) {
    setProperty("volume", String(max(0, min(100, volume))))
  }

  func setRate(_ rate: Double) {
    setProperty("speed", String(max(0.25, min(4.0, rate))))
  }

  func setAspect(_ mode: String) {
    let gravity: AVLayerVideoGravity
    switch mode {
    case "fill", "cover":
      gravity = .resizeAspectFill
      setProperty("keepaspect", "no")
    case "stretch":
      gravity = .resize
      setProperty("keepaspect", "no")
    default:
      gravity = .resizeAspect
      setProperty("keepaspect", "yes")
      setProperty("panscan", "0")
      setProperty("video-aspect-override", "no")
    }
    DispatchQueue.main.async { [weak self] in
      self?.displayLayer?.videoGravity = gravity
    }
  }

  func videoInfo() -> [String: Any] {
    guard let handle = mpv else { return [:] }
    var hwdec = ""
    var hwcur = ""
    var vo = ""
    var hint = ""
    var peak = 0.0
    var w: Int64 = 0, h: Int64 = 0
    if let raw = mpv_get_property_string(handle, "hwdec") {
      hwdec = String(cString: raw); mpv_free(raw)
    }
    if let raw = mpv_get_property_string(handle, "hwdec-current") {
      hwcur = String(cString: raw); mpv_free(raw)
    }
    if let raw = mpv_get_property_string(handle, "current-vo") {
      vo = String(cString: raw); mpv_free(raw)
    }
    if let raw = mpv_get_property_string(handle, "target-colorspace-hint") {
      hint = String(cString: raw); mpv_free(raw)
    }
    mpv_get_property(handle, "video-params/sig-peak", MPV_FORMAT_DOUBLE, &peak)
    mpv_get_property(handle, "dwidth", MPV_FORMAT_INT64, &w)
    mpv_get_property(handle, "dheight", MPV_FORMAT_INT64, &h)
    let edrOn = !vulkan && hdrEnabled && peak > 1.0
    return [
      "hwdec": hwdec,
      "hwdec-current": hwcur.isEmpty ? hwdec : hwcur,
      "current-vo": vo,
      "width": Int(w),
      "height": Int(h),
      "sig-peak": peak,
      "hdr-enabled": hdrEnabled,
      "edr-on": edrOn,
      "target-colorspace-hint": hint,
    ]
  }

  /// 卸 mpv 后延迟再摘层，避免在可见 sample-buffer 层上被拆 VO 时卡死。
  private static let layerRetireDelay: TimeInterval = 0.2

  func destroy(completion: (() -> Void)? = nil) {
    destroyed = true
    positionTimer?.cancel()
    positionTimer = nil
    endPlaybackActivity()
    NotificationCenter.default.removeObserver(self)
    #if os(macOS)
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    #endif

    let tearDownUI = { [weak self] in
      guard let self else {
        completion?()
        return
      }
      self.setContainerHidden(true)
      let layer = self.videoLayer
      let container = self.containerLayer
      #if os(iOS)
      let host = self.hostView
      self.hostView = nil
      #endif
      self.videoLayer = nil
      self.containerLayer = nil
      self.lastHoleFrame = nil
      self.window = nil
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.layerRetireDelay) {
        layer?.removeFromSuperlayer()
        container?.removeFromSuperlayer()
        #if os(iOS)
        host?.removeFromSuperview()
        #endif
        completion?()
      }
    }
    mpvQueue.async { [weak self] in
      guard let self else {
        DispatchQueue.main.async(execute: tearDownUI)
        return
      }
      if let handle = self.mpv {
        mpv_set_wakeup_callback(handle, nil, nil)
        mpv_wakeup(handle)
        mpv_terminate_destroy(handle)
        self.mpv = nil
      }
      self.wakeup?()
      self.wakeup = nil
      DispatchQueue.main.async(execute: tearDownUI)
    }
  }

  // MARK: - mpv

  private func setupMpv(layer: CALayer) -> Bool {
    guard let handle = mpv_create() else { return false }
    mpv = handle

    var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
    mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &wid)
    let vo = vulkan ? "gpu-next" : "avfoundation"
    mpv_set_option_string(handle, "vo", vo)
    if vulkan {
      mpv_set_option_string(handle, "gpu-api", "vulkan")
      mpv_set_option_string(handle, "gpu-context", "moltenvk")
    } else {
      mpv_set_option_string(handle, "avfoundation-presentation", "host")
      mpv_set_option_string(handle, "avfoundation-composite-osd", "no")
    }
    // 默认 videotoolbox；会话仍可由 Dart 覆盖为 soft/auto。
    mpv_set_option_string(handle, "hwdec", "videotoolbox")
    mpv_set_option_string(handle, "hwdec-codecs", "all")
    mpv_set_option_string(handle, "hwdec-software-fallback", "yes")
    mpv_set_option_string(handle, "target-colorspace-hint", "auto")
    mpv_set_option_string(handle, "keep-open", "yes")
    mpv_set_option_string(handle, "idle", "yes")
    mpv_set_option_string(handle, "osc", "no")
    mpv_set_option_string(handle, "input-default-bindings", "no")
    mpv_set_option_string(handle, "input-vo-keyboard", "no")
    mpv_set_option_string(handle, "terminal", "no")

    if mpv_initialize(handle) < 0 {
      mpv_terminate_destroy(handle)
      mpv = nil
      return false
    }

    var voRaw: UnsafeMutablePointer<CChar>?
    let voOk = mpv_get_property(handle, "vo", MPV_FORMAT_STRING, &voRaw) >= 0 && voRaw != nil
      && String(cString: voRaw!) == vo
    if let voRaw { mpv_free(voRaw) }
    if !voOk {
      mpv_terminate_destroy(handle)
      mpv = nil
      return false
    }

    mpv_observe_property(handle, 0, "pause", MPV_FORMAT_FLAG)
    mpv_observe_property(handle, 0, "paused-for-cache", MPV_FORMAT_FLAG)
    mpv_observe_property(handle, 0, "eof-reached", MPV_FORMAT_FLAG)
    mpv_observe_property(handle, 0, "dwidth", MPV_FORMAT_INT64)
    mpv_observe_property(handle, 0, "dheight", MPV_FORMAT_INT64)
    mpv_observe_property(handle, 0, "video-params/w", MPV_FORMAT_INT64)
    mpv_observe_property(handle, 0, "video-params/h", MPV_FORMAT_INT64)
    mpv_observe_property(handle, 0, "video-params/sig-peak", MPV_FORMAT_DOUBLE)
    mpv_observe_property(handle, 0, "hwdec-current", MPV_FORMAT_STRING)
    mpv_observe_property(handle, 0, "media-live", MPV_FORMAT_FLAG)

    let box = Unmanaged.passRetained(self)
    mpv_set_wakeup_callback(handle, { ctx in
      guard let ctx else { return }
      let core = Unmanaged<KotvMpvCore>.fromOpaque(ctx).takeUnretainedValue()
      core.mpvQueue.async { core.drainEvents() }
    }, box.toOpaque())
    wakeup = { box.release() }
    return true
  }

  private func startPositionTimer() {
    positionTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: mpvQueue)
    timer.schedule(deadline: .now() + .milliseconds(300), repeating: .milliseconds(300))
    timer.setEventHandler { [weak self] in self?.emitPosition() }
    timer.resume()
    positionTimer = timer
  }

  private func drainEvents() {
    guard let handle = mpv, !destroyed else { return }
    while true {
      let ev = mpv_wait_event(handle, 0)
      guard let ev else { break }
      if ev.pointee.event_id == MPV_EVENT_NONE { break }
      handleEvent(ev.pointee)
    }
  }

  private func handleEvent(_ event: mpv_event) {
    switch event.event_id {
    case MPV_EVENT_PROPERTY_CHANGE:
      guard let prop = event.data?.assumingMemoryBound(to: mpv_event_property.self).pointee,
            let namePtr = prop.name else { return }
      switch String(cString: namePtr) {
      case "pause", "paused-for-cache", "eof-reached":
        emitPosition()
      case "dwidth", "dheight", "video-params/w", "video-params/h":
        emitSize(ready: true)
      case "video-params/sig-peak":
        var peak = 0.0
        if let handle = mpv {
          mpv_get_property(handle, "video-params/sig-peak", MPV_FORMAT_DOUBLE, &peak)
        }
        updateEDRMode(sigPeak: peak)
      case "hwdec-current":
        emitVideoInfo()
      case "media-live":
        // 没有该属性的 libmpv（iOS MPVKit）只报 NONE，不会走到这里。
        if prop.format == MPV_FORMAT_FLAG,
           prop.data?.assumingMemoryBound(to: Int32.self).pointee != 0 {
          emit(["event": "live", "live": true])
        }
      default:
        break
      }
    case MPV_EVENT_FILE_LOADED, MPV_EVENT_PLAYBACK_RESTART:
      emitSize(ready: true)
      emitPosition()
      emitVideoInfo()
      var peak = 0.0
      if let handle = mpv {
        mpv_get_property(handle, "video-params/sig-peak", MPV_FORMAT_DOUBLE, &peak)
      }
      updateEDRMode(sigPeak: peak)
      // 续播点：首帧就绪后 seek，保持播放（不 pause），避免无缝换集卡死。
      if pendingStartMs > 0 {
        let ms = pendingStartMs
        pendingStartMs = 0
        seek(positionMs: ms)
      }
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.ensureFlutterAllowsUnderlay()
        self.setVisible(true)
      }
    case MPV_EVENT_END_FILE:
      if let data = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee {
        if data.reason == MPV_END_FILE_REASON_EOF {
          emit(["event": "completed"])
        } else if data.reason == MPV_END_FILE_REASON_ERROR {
          let detail = String(cString: mpv_error_string(data.error))
          emit(["event": "error", "message": "MPV \(detail) (\(data.error))"])
        }
      }
      emitPosition()
    default:
      break
    }
  }

  private func emit(_ map: [String: Any]) {
    DispatchQueue.main.async { [weak self] in self?.onEvent?(map) }
  }

  private func emitPosition() {
    guard let handle = mpv, !destroyed else { return }
    var pos = 0.0, dur = 0.0, buf = 0.0, speed = 0.0
    var pause: Int32 = 1, cache: Int32 = 0, eof: Int32 = 0
    var idle: Int32 = 0, coreIdle: Int32 = 0, seeking: Int32 = 0
    mpv_get_property(handle, "time-pos", MPV_FORMAT_DOUBLE, &pos)
    mpv_get_property(handle, "duration", MPV_FORMAT_DOUBLE, &dur)
    mpv_get_property(handle, "demuxer-cache-duration", MPV_FORMAT_DOUBLE, &buf)
    mpv_get_property(handle, "cache-speed", MPV_FORMAT_DOUBLE, &speed)
    mpv_get_property(handle, "pause", MPV_FORMAT_FLAG, &pause)
    mpv_get_property(handle, "paused-for-cache", MPV_FORMAT_FLAG, &cache)
    mpv_get_property(handle, "eof-reached", MPV_FORMAT_FLAG, &eof)
    mpv_get_property(handle, "idle-active", MPV_FORMAT_FLAG, &idle)
    mpv_get_property(handle, "core-idle", MPV_FORMAT_FLAG, &coreIdle)
    mpv_get_property(handle, "seeking", MPV_FORMAT_FLAG, &seeking)

    let playing = pause == 0 && idle == 0 && coreIdle == 0
    let buffering = seeking != 0 || cache != 0 || (!playing && eof == 0 && pos <= 0.05)
    pausedState = pause != 0
    emit([
      "event": "position",
      "positionMs": Int64((pos.isFinite ? pos : 0) * 1000),
      "durationMs": Int64(max(0, (dur.isFinite ? dur : 0) * 1000)),
      "bufferedMs": Int64(max(0, ((pos.isFinite ? pos : 0) + (buf.isFinite ? buf : 0)) * 1000)),
      "playing": playing,
      "buffering": buffering,
      "speedBps": Int64(max(0, speed.isFinite ? speed : 0)),
    ])
  }

  private func emitSize(ready: Bool) {
    guard let handle = mpv else { return }
    var w: Int64 = 0, h: Int64 = 0
    mpv_get_property(handle, "dwidth", MPV_FORMAT_INT64, &w)
    mpv_get_property(handle, "dheight", MPV_FORMAT_INT64, &h)
    if w <= 0 || h <= 0 {
      mpv_get_property(handle, "video-params/w", MPV_FORMAT_INT64, &w)
      mpv_get_property(handle, "video-params/h", MPV_FORMAT_INT64, &h)
    }
    // loadfile 抖动时 dwidth=0：禁止发 ready，否则 Dart 提前揭盖与 silent 误判。
    if ready && (w <= 0 || h <= 0) {
      return
    }
    emit(["event": ready ? "ready" : "size", "width": Int(w), "height": Int(h)])
  }

  private func emitVideoInfo() {
    var info = videoInfo()
    info["event"] = "videoInfo"
    emit(info)
  }

  /// 见类型注释：HDR 直出开且 sigPeak>1 开 EDR（软硬解一样）。Vulkan 由 MoltenVK 按交换链色彩空间开关 EDR。
  private func updateEDRMode(sigPeak: Double) {
    lastSigPeak = sigPeak
    guard !vulkan else { return }
    let shouldEnableEDR = hdrEnabled && sigPeak > 1.0
    let apply: () -> Void = { [weak self] in
      guard let self, let videoLayer = self.displayLayer else { return }
      self.withoutLayerAnimations {
        // 26+：preferredDynamicRange；macOS 14–25 / iOS 17–25：wantsExtendedDynamicRangeContent。
        if #available(macOS 26.0, iOS 26.0, *) {
          videoLayer.preferredDynamicRange = shouldEnableEDR ? .high : .standard
        } else if #available(macOS 14.0, iOS 17.0, *) {
          videoLayer.wantsExtendedDynamicRangeContent = shouldEnableEDR
        }
      }
    }
    if Thread.isMainThread {
      apply()
    } else {
      DispatchQueue.main.async(execute: apply)
    }
  }

  // MARK: - 宿主层

  /// 容器层挂进宿主并放到最底层；frame 为 nil 时铺满宿主。
  @discardableResult
  private func attachContainer(frame: CGRect?) -> Bool {
    guard let containerLayer, let window else { return false }
    #if os(macOS)
    guard let contentView = window.contentView else { return false }
    contentView.wantsLayer = true
    guard let superlayer = contentView.layer else { return false }
    #else
    let host: UIView
    if let hostView {
      host = hostView
    } else {
      host = UIView(frame: window.bounds)
      host.isUserInteractionEnabled = false
      host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      hostView = host
    }
    if host.superview !== window || window.subviews.first !== host {
      host.removeFromSuperview()
      window.insertSubview(host, at: 0)
    }
    host.frame = window.bounds
    let superlayer = host.layer
    #endif
    withoutLayerAnimations {
      superlayer.backgroundColor = KotvMpvColor.black.cgColor
      superlayer.isOpaque = true
      if containerLayer.superlayer !== superlayer || superlayer.sublayers?.first !== containerLayer {
        containerLayer.removeFromSuperlayer()
        superlayer.insertSublayer(containerLayer, at: 0)
      }
      containerLayer.frame = frame ?? superlayer.bounds
      updateContentsScale()
    }
    ensureFlutterAllowsUnderlay()
    return true
  }

  /// Flutter 表面默认按不透明合成；关掉才能透出下层视频。
  private func ensureFlutterAllowsUnderlay() {
    #if os(macOS)
    guard let containerLayer, let superlayer = window?.contentView?.layer else { return }
    for layer in superlayer.sublayers ?? [] where layer !== containerLayer && layer.isOpaque {
      layer.isOpaque = false
    }
    #else
    guard let flutter = window?.rootViewController as? FlutterViewController else { return }
    if flutter.isViewOpaque { flutter.isViewOpaque = false }
    if flutter.view.backgroundColor != .clear { flutter.view.backgroundColor = .clear }
    #endif
  }

  private var hostBounds: CGRect? {
    #if os(macOS)
    return window?.contentView?.bounds
    #else
    return hostView?.bounds ?? window?.bounds
    #endif
  }

  /// Flutter 视图逻辑坐标（顶左原点）→ 宿主层坐标。
  private func hostRect(fromFlutter rect: CGRect) -> CGRect? {
    #if os(macOS)
    guard let bounds = window?.contentView?.bounds else { return nil }
    return CGRect(
      x: rect.origin.x,
      y: bounds.height - rect.origin.y - rect.height,
      width: rect.width,
      height: rect.height
    )
    #else
    guard let window else { return nil }
    let flutterView = window.rootViewController?.view ?? window
    return flutterView.convert(rect, to: hostView ?? window)
    #endif
  }

  private var screenScale: CGFloat {
    #if os(macOS)
    return window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    #else
    return window?.screen.nativeScale ?? 2
    #endif
  }

  /// 屏幕可显示的 EDR 峰值倍数（1 = SDR）。
  private var edrHeadroom: CGFloat {
    #if os(macOS)
    return (window?.screen ?? NSScreen.main)?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1
    #else
    if #available(iOS 16.0, *), let screen = window?.screen {
      return screen.potentialEDRHeadroom
    }
    return 1
    #endif
  }

  private func updateContentsScale() {
    guard let containerLayer else { return }
    let scale = screenScale
    containerLayer.contentsScale = scale
    if let videoLayer, videoLayer.superlayer === containerLayer, videoLayer.contentsScale != scale {
      videoLayer.contentsScale = scale
    }
    if let metalLayer {
      metalLayer.setValue(NSNumber(value: Double(edrHeadroom)), forKey: "mpvEDRHeadroom")
      containerLayer.setNeedsLayout()
    }
  }

  private func recoverDisplayLayerIfNeeded() {
    guard let videoLayer = displayLayer, containerLayer?.isHidden == false else { return }
    guard videoLayer.status == .failed || videoLayer.requiresFlushToResumeDecoding else { return }
    videoLayer.flush()
    // 暂停时 flush 后补一帧，否则 ASBDL 可能一直空。
    asyncMpv { [weak self] in self?.command(["seek", "0", "relative+exact"]) }
  }

  private func setContainerHidden(_ hidden: Bool) {
    withoutLayerAnimations {
      containerLayer?.isHidden = hidden
      metalLayer?.isHidden = hidden
    }
  }

  private func withoutLayerAnimations(_ updates: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    updates()
    CATransaction.commit()
  }

  // MARK: - 遮挡 / 前后台

  private func setOccluded(_ occluded: Bool) {
    guard containerLayer != nil, mpv != nil, occluded != layerHiddenForOcclusion else { return }
    layerHiddenForOcclusion = occluded
    if occluded {
      setContainerHidden(true)
      endPlaybackActivity()
      return
    }
    if !layerHiddenForScreenSleep {
      setContainerHidden(!isVisible)
      if isVisible {
        recoverDisplayLayerIfNeeded()
      }
    }
    if isVisible && !pausedState {
      beginPlaybackActivity()
    }
  }

  private func observeHostNotifications(_ window: KotvMpvWindow) {
    let center = NotificationCenter.default
    #if os(macOS)
    center.addObserver(
      self, selector: #selector(windowOcclusionDidChange),
      name: NSWindow.didChangeOcclusionStateNotification, object: window
    )
    for name in [
      NSWindow.didChangeBackingPropertiesNotification,
      NSWindow.didChangeScreenNotification,
      NSWindow.didEnterFullScreenNotification,
      NSWindow.didExitFullScreenNotification,
    ] {
      // 勿清空 lastHoleFrame：退出/缩放后 Dart 会再下发洞；清空会导致 ASBDL 铺满、洞内只露一角。
      center.addObserver(self, selector: #selector(hostGeometryDidChange), name: name, object: window)
    }
    let workspace = NSWorkspace.shared.notificationCenter
    workspace.addObserver(
      self, selector: #selector(screensDidSleep),
      name: NSWorkspace.screensDidSleepNotification, object: nil
    )
    workspace.addObserver(
      self, selector: #selector(screensDidWake),
      name: NSWorkspace.screensDidWakeNotification, object: nil
    )
    #else
    center.addObserver(
      self, selector: #selector(appDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification, object: nil
    )
    center.addObserver(
      self, selector: #selector(appWillEnterForeground),
      name: UIApplication.willEnterForegroundNotification, object: nil
    )
    #endif
  }

  #if os(macOS)
  @objc private func windowOcclusionDidChange(_ notification: Notification) {
    setOccluded(!(window?.occlusionState.contains(.visible) ?? true))
  }

  @objc private func hostGeometryDidChange(_ notification: Notification) {
    updateFrame()
  }

  @objc private func screensDidSleep(_ notification: Notification) {
    guard containerLayer != nil, mpv != nil, !layerHiddenForScreenSleep else { return }
    layerHiddenForScreenSleep = true
    setContainerHidden(true)
    endPlaybackActivity()
  }

  @objc private func screensDidWake(_ notification: Notification) {
    guard containerLayer != nil, mpv != nil, layerHiddenForScreenSleep else { return }
    layerHiddenForScreenSleep = false
    if !layerHiddenForOcclusion {
      setContainerHidden(!isVisible)
      if isVisible && !pausedState {
        beginPlaybackActivity()
      }
    }
    recoverDisplayLayerIfNeeded()
  }

  private func beginPlaybackActivity() {
    guard playbackActivity == nil else { return }
    playbackActivity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiated, .latencyCritical],
      reason: "Video playback"
    )
  }

  private func endPlaybackActivity() {
    guard let playbackActivity else { return }
    ProcessInfo.processInfo.endActivity(playbackActivity)
    self.playbackActivity = nil
  }
  #else
  @objc private func appDidEnterBackground(_ notification: Notification) {
    setOccluded(true)
  }

  @objc private func appWillEnterForeground(_ notification: Notification) {
    setOccluded(false)
  }

  /// iOS 常亮由 Dart WakelockPlus 统一管理。
  private func beginPlaybackActivity() {}
  private func endPlaybackActivity() {}
  #endif
}

private final class KotvMpvContainerLayer: CALayer {
  weak var videoLayer: CALayer?

  override func action(forKey event: String) -> CAAction? { nil }

  override func layoutSublayers() {
    super.layoutSublayers()
    guard let videoLayer, videoLayer.superlayer === self else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    videoLayer.bounds = CGRect(origin: .zero, size: bounds.size)
    videoLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
    if let metal = videoLayer as? CAMetalLayer {
      let scale = metal.contentsScale
      metal.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }
    CATransaction.commit()
  }
}
