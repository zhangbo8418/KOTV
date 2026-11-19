import AVFoundation
import Cocoa
import QuartzCore

/// macOS 原生 libmpv：`vo=avfoundation` underlay。
///
/// 层挂在窗口宿主 `contentView`（非 FlutterView）上：stage 全窗黑垫 + 播放洞 ASBDL；
/// Flutter 为宿主子视图且 `zPosition` 更高，透明洞才露出画面、洞外不透桌面。
/// 所有 `mpv_*` 仅在 [mpvQueue] 上调用（VO 会 `dispatch_sync` 主队列，主线程同步调 mpv 会死锁）。
final class KotvMpvCore {
  private weak var window: NSWindow?
  /// 全窗不透明黑垫（z 低于 Flutter 子视图）。
  private var stageLayer: CALayer?
  private var containerLayer: KotvMpvContainerLayer?
  private var videoLayer: AVSampleBufferDisplayLayer?
  /// libmpv client API 串行队列（含事件排空）。
  private let mpvQueue = DispatchQueue(label: "com.bobo.kotv.mpv")
  private var mpv: OpaquePointer?
  private var wakeup: (() -> Void)?
  private var positionTimer: DispatchSourceTimer?
  private var lastSigPeak = 0.0
  private var isVisible = false
  private var layerHiddenForOcclusion = false
  private var destroyed = false

  var onEvent: (([String: Any]) -> Void)?
  var isReady: Bool { mpv != nil && !destroyed }

  /// 在主线程准备 layer；mpv 初始化在 [mpvQueue]（勿在主线程调）。
  func prepareLayers(in window: NSWindow) -> Bool {
    assert(Thread.isMainThread)
    if containerLayer != nil {
      self.window = window
      if let contentView = window.contentView, let contentLayer = contentView.layer {
        layoutLayers(in: contentLayer, videoFrame: containerLayer?.frame ?? contentView.bounds)
      }
      return true
    }
    guard let contentView = window.contentView else { return false }
    self.window = window

    let stage = CALayer()
    stage.backgroundColor = NSColor.black.cgColor
    stage.isOpaque = true
    stage.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]

    let container = KotvMpvContainerLayer()
    container.frame = contentView.bounds
    container.backgroundColor = NSColor.black.cgColor
    container.isOpaque = true
    container.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]

    let layer = AVSampleBufferDisplayLayer()
    layer.frame = container.bounds
    layer.isOpaque = true
    layer.backgroundColor = NSColor.black.cgColor
    layer.videoGravity = .resizeAspect
    layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
    container.addSublayer(layer)
    container.videoLayer = layer

    stageLayer = stage
    containerLayer = container
    videoLayer = layer
    contentView.wantsLayer = true
    guard let contentLayer = contentView.layer else {
      stageLayer = nil
      containerLayer = nil
      videoLayer = nil
      return false
    }
    layoutLayers(in: contentLayer, videoFrame: contentView.bounds)
    // 初始隐藏视频容器；全窗 stage 仍显示，避免透桌面。
    setContainerHidden(true)

    NotificationCenter.default.addObserver(
      self, selector: #selector(windowOcclusionDidChange),
      name: NSWindow.didChangeOcclusionStateNotification, object: window
    )
    NotificationCenter.default.addObserver(
      self, selector: #selector(windowDidChangeBacking),
      name: NSWindow.didChangeBackingPropertiesNotification, object: window
    )
    return true
  }

  /// 在 [mpvQueue] 上创建并初始化 mpv；成功后启动节流进度定时器。
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
    if let contentView = window?.contentView, let contentLayer = contentView.layer {
      contentView.wantsLayer = true
      layoutLayers(in: contentLayer, videoFrame: containerLayer?.frame ?? contentView.bounds)
    }
    setContainerHidden(!visible || layerHiddenForOcclusion)
  }

  func updateFrame(_ rect: CGRect?) {
    assert(Thread.isMainThread)
    guard let contentView = window?.contentView, let contentLayer = contentView.layer else { return }
    let bounds = contentView.bounds
    let target: CGRect
    if let rect, rect.width > 1, rect.height > 1 {
      // Dart 逻辑坐标原点左上 → AppKit layer 原点左下。
      target = CGRect(
        x: rect.origin.x,
        y: bounds.height - rect.origin.y - rect.height,
        width: rect.width,
        height: rect.height
      )
    } else {
      target = bounds
    }
    layoutLayers(in: contentLayer, videoFrame: target)
  }

  /// 投递到 mpv 队列（MethodChannel 路径用，勿在主线程同步等）。
  func asyncMpv(_ body: @escaping () -> Void) {
    mpvQueue.async { [weak self] in
      guard let self, !self.destroyed else { return }
      body()
    }
  }

  func setProperty(_ name: String, _ value: String) {
    guard let handle = mpv else { return }
    if name == "vo" || name == "wid" || name == "gpu-api" || name == "gpu-context"
      || name.hasPrefix("avfoundation-")
    {
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
    // 换集时保持 ASBDL 可见：隐藏会导致 vo 丢帧后只剩黑层；遮罩由 Dart hole 负责。
    DispatchQueue.main.async { [weak self] in self?.setVisible(true) }
    command(["stop"])
    if startAtMs > 0 {
      let sec = String(format: "%.3f", Double(startAtMs) / 1000.0)
      command(["loadfile", url, "replace", "start=\(sec)"])
    } else {
      command(["loadfile", url, "replace"])
    }
    command(["set", "pause", "no"])
  }

  func play() { command(["set", "pause", "no"]) }
  func pause() { command(["set", "pause", "yes"]) }
  func stop() {
    command(["stop"])
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
      self?.videoLayer?.videoGravity = gravity
    }
  }

  func videoInfo() -> [String: Any] {
    guard let handle = mpv else { return [:] }
    var hwdec = ""
    var hwcur = ""
    var vo = ""
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
    mpv_get_property(handle, "dwidth", MPV_FORMAT_INT64, &w)
    mpv_get_property(handle, "dheight", MPV_FORMAT_INT64, &h)
    return [
      "hwdec": hwdec,
      "hwdec-current": hwcur.isEmpty ? hwdec : hwcur,
      "current-vo": vo,
      "width": Int(w),
      "height": Int(h),
    ]
  }

  func destroy(completion: (() -> Void)? = nil) {
    destroyed = true
    positionTimer?.cancel()
    positionTimer = nil
    let tearDownUI = { [weak self] in
      guard let self else {
        completion?()
        return
      }
      NotificationCenter.default.removeObserver(self)
      self.videoLayer?.removeFromSuperlayer()
      self.containerLayer?.removeFromSuperlayer()
      self.stageLayer?.removeFromSuperlayer()
      self.videoLayer = nil
      self.containerLayer = nil
      self.stageLayer = nil
      self.window = nil
      completion?()
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

  // MARK: - private

  private func setupMpv(layer: AVSampleBufferDisplayLayer) -> Bool {
    guard let handle = mpv_create() else { return false }
    mpv = handle

    var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
    mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &wid)
    mpv_set_option_string(handle, "vo", "avfoundation")
    mpv_set_option_string(handle, "avfoundation-presentation", "host")
    mpv_set_option_string(handle, "avfoundation-composite-osd", "no")
    mpv_set_option_string(handle, "hwdec", "auto")
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
      && String(cString: voRaw!) == "avfoundation"
    if let voRaw { mpv_free(voRaw) }
    if !voOk {
      mpv_terminate_destroy(handle)
      mpv = nil
      return false
    }

    // 进度靠节流定时器；不 observe time-pos，避免与 VO/主线程交织刷事件。
    mpv_observe_property(handle, 0, "pause", MPV_FORMAT_FLAG)
    mpv_observe_property(handle, 0, "paused-for-cache", MPV_FORMAT_FLAG)
    mpv_observe_property(handle, 0, "eof-reached", MPV_FORMAT_FLAG)
    mpv_observe_property(handle, 0, "dwidth", MPV_FORMAT_INT64)
    mpv_observe_property(handle, 0, "dheight", MPV_FORMAT_INT64)
    mpv_observe_property(handle, 0, "video-params/w", MPV_FORMAT_INT64)
    mpv_observe_property(handle, 0, "video-params/h", MPV_FORMAT_INT64)
    mpv_observe_property(handle, 0, "video-params/sig-peak", MPV_FORMAT_DOUBLE)
    mpv_observe_property(handle, 0, "hwdec-current", MPV_FORMAT_STRING)

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
      default:
        break
      }
    case MPV_EVENT_FILE_LOADED, MPV_EVENT_PLAYBACK_RESTART:
      emitSize(ready: true)
      emitPosition()
      emitVideoInfo()
      DispatchQueue.main.async { [weak self] in self?.setVisible(true) }
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
    emit(["event": ready ? "ready" : "size", "width": Int(w), "height": Int(h)])
  }

  private func emitVideoInfo() {
    var info = videoInfo()
    info["event"] = "videoInfo"
    emit(info)
  }

  private func updateEDRMode(sigPeak: Double) {
    lastSigPeak = sigPeak
    guard let videoLayer else { return }
    let enable = sigPeak > 1.0
    DispatchQueue.main.async {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      if #available(macOS 14.0, *) {
        videoLayer.wantsExtendedDynamicRangeContent = enable
      }
      CATransaction.commit()
    }
  }

  @objc private func windowOcclusionDidChange(_ notification: Notification) {
    guard containerLayer != nil, mpv != nil else { return }
    let visible = window?.occlusionState.contains(.visible) ?? true
    if !visible && !layerHiddenForOcclusion {
      layerHiddenForOcclusion = true
      setContainerHidden(true)
    } else if visible && layerHiddenForOcclusion {
      layerHiddenForOcclusion = false
      setContainerHidden(!isVisible)
    }
  }

  @objc private func windowDidChangeBacking(_ notification: Notification) {
    // 只按当前播放洞重排；勿 updateFrame(nil) 扩成全窗盖住 UI。
    guard let contentView = window?.contentView, let contentLayer = contentView.layer else { return }
    layoutLayers(in: contentLayer, videoFrame: containerLayer?.frame ?? contentView.bounds)
  }

  /// stage（全窗黑）与视频容器挂在宿主 layer；zPosition 低于 Flutter 子视图（见 MainFlutterWindow）。
  private func layoutLayers(in superlayer: CALayer, videoFrame: CGRect) {
    guard let stageLayer, let containerLayer else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let bounds = superlayer.bounds
    stageLayer.frame = bounds
    stageLayer.zPosition = -2
    containerLayer.zPosition = -1
    if stageLayer.superlayer !== superlayer {
      stageLayer.removeFromSuperlayer()
      superlayer.insertSublayer(stageLayer, at: 0)
    }
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    containerLayer.contentsScale = scale
    videoLayer?.contentsScale = scale
    stageLayer.contentsScale = scale
    if containerLayer.superlayer !== superlayer {
      containerLayer.removeFromSuperlayer()
      superlayer.insertSublayer(containerLayer, above: stageLayer)
    } else if let subs = superlayer.sublayers,
              let si = subs.firstIndex(of: stageLayer),
              let ci = subs.firstIndex(of: containerLayer),
              ci < si
    {
      superlayer.insertSublayer(containerLayer, above: stageLayer)
    }
    containerLayer.frame = videoFrame
    CATransaction.commit()
  }

  private func setContainerHidden(_ hidden: Bool) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    containerLayer?.isHidden = hidden
    // stage 始终显示，挡住 Flutter α=0 处的桌面。
    stageLayer?.isHidden = false
    CATransaction.commit()
  }
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
    CATransaction.commit()
  }
}
