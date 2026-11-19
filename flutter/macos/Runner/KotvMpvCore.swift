import AVFoundation
import Cocoa
import QuartzCore

/// macOS 原生 libmpv：`vo=avfoundation`，ASBDL 插在 `contentView.layer` 最底层。
///
/// 窗口不透明黑底 + Flutter VC `.clear`；`attachContainerLayer` 把 contentView.layer
/// 涂黑并 `insertSublayer(..., at: 0)`，透明洞露出画面、洞外不透桌面。
/// 所有 `mpv_*` 仅在 [mpvQueue]（VO 会 `dispatch_sync` 主队列，主线程同步调 mpv 会死锁）。
final class KotvMpvCore {
  private weak var window: NSWindow?
  private var containerLayer: KotvMpvContainerLayer?
  private var videoLayer: AVSampleBufferDisplayLayer?
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

  /// 主线程建 layer；mpv 初始化见 [startMpv]。
  func prepareLayers(in window: NSWindow) -> Bool {
    assert(Thread.isMainThread)
    if containerLayer != nil {
      self.window = window
      if let contentView = window.contentView, let contentLayer = contentView.layer {
        attachContainerLayer(to: contentLayer, frame: containerLayer?.frame ?? contentView.bounds)
      }
      return true
    }
    guard let contentView = window.contentView else { return false }
    self.window = window

    let container = KotvMpvContainerLayer()
    container.frame = contentView.bounds
    container.backgroundColor = NSColor.black.cgColor
    container.isOpaque = true
    container.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

    let layer = AVSampleBufferDisplayLayer()
    layer.frame = container.bounds
    layer.isOpaque = true
    layer.backgroundColor = NSColor.black.cgColor
    layer.videoGravity = .resizeAspect
    container.addSublayer(layer)
    container.videoLayer = layer

    containerLayer = container
    videoLayer = layer
    contentView.wantsLayer = true
    guard let contentLayer = contentView.layer else {
      containerLayer = nil
      videoLayer = nil
      return false
    }
    attachContainerLayer(to: contentLayer, frame: contentView.bounds)
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
    if visible, let contentView = window?.contentView {
      contentView.wantsLayer = true
      if let superlayer = contentView.layer {
        attachContainerLayer(to: superlayer, frame: containerLayer?.frame ?? contentView.bounds)
      }
    }
    setContainerHidden(!visible || layerHiddenForOcclusion)
    if visible {
      recoverDisplayLayerIfNeeded()
    }
  }

  /// Dart 逻辑坐标（原点左上）→ AppKit layer（原点左下）。nil/无效则铺满 contentView。
  func updateFrame(_ rect: CGRect?) {
    assert(Thread.isMainThread)
    guard let containerLayer else { return }
    let target: CGRect
    if let rect, rect.width > 1, rect.height > 1, let bounds = window?.contentView?.bounds {
      target = CGRect(
        x: rect.origin.x,
        y: bounds.height - rect.origin.y - rect.height,
        width: rect.width,
        height: rect.height
      )
    } else if let contentView = window?.contentView {
      target = contentView.bounds
    } else {
      return
    }
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
    // loadfile 前显示层；遮罩由 Dart 洞负责。
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
      self.videoLayer = nil
      self.containerLayer = nil
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
      && String(cString: voRaw!) == "avfoundation"
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
      if isVisible {
        recoverDisplayLayerIfNeeded()
      }
    }
  }

  @objc private func windowDidChangeBacking(_ notification: Notification) {
    updateFrame(containerLayer?.frame)
  }

  /// 涂黑 contentView.layer 并插入容器到 index 0（Flutter 之下）。
  private func attachContainerLayer(to superlayer: CALayer, frame: CGRect) {
    guard let containerLayer else { return }
    withoutLayerAnimations {
      superlayer.backgroundColor = NSColor.black.cgColor
      superlayer.isOpaque = true
      let needsReorder = superlayer.sublayers?.first !== containerLayer
      if containerLayer.superlayer !== superlayer || needsReorder {
        containerLayer.removeFromSuperlayer()
        superlayer.insertSublayer(containerLayer, at: 0)
      }
      containerLayer.frame = frame
      updateContentsScale()
    }
  }

  private func updateContentsScale() {
    guard let containerLayer else { return }
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    containerLayer.contentsScale = scale
    if let videoLayer, videoLayer.superlayer === containerLayer, videoLayer.contentsScale != scale {
      videoLayer.contentsScale = scale
    }
  }

  private func recoverDisplayLayerIfNeeded() {
    guard let videoLayer, containerLayer?.isHidden == false else { return }
    guard videoLayer.status == .failed || videoLayer.requiresFlushToResumeDecoding else { return }
    videoLayer.flush()
    // 暂停时 flush 后补一帧，否则 ASBDL 可能一直空。
    asyncMpv { [weak self] in self?.command(["seek", "0", "relative+exact"]) }
  }

  private func setContainerHidden(_ hidden: Bool) {
    withoutLayerAnimations {
      containerLayer?.isHidden = hidden
    }
  }

  private func withoutLayerAnimations(_ updates: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    updates()
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
