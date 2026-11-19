import Cocoa
import FlutterMacOS

/// MethodChannel `kotv_mpv` / EventChannel `kotv_mpv/events`。
///
/// mpv API 一律经 [KotvMpvCore.asyncMpv]；layer 显隐/几何留在主线程。
final class KotvMpvPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var core: KotvMpvCore?
  private var eventSink: FlutterEventSink?
  private var decodeMode = "auto"
  private var hwdecOverride = ""
  private var conf = ""
  private var diskCache = false
  private var livePlayback = false
  private var dolbyVisionPolicy = 0
  private weak var hostWindow: NSWindow?

  static func register(with registrar: FlutterPluginRegistrar, window: NSWindow?) {
    let instance = KotvMpvPlugin()
    instance.hostWindow = window
    let method = FlutterMethodChannel(name: "kotv_mpv", binaryMessenger: registrar.messenger)
    let events = FlutterEventChannel(name: "kotv_mpv/events", binaryMessenger: registrar.messenger)
    registrar.addMethodCallDelegate(instance, channel: method)
    events.setStreamHandler(instance)
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    register(with: registrar, window: NSApp.mainWindow ?? NSApp.windows.first)
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private func emit(_ map: [String: Any]) {
    eventSink?(map)
  }

  private func ingest(_ args: [String: Any]?) {
    guard let args else { return }
    if let d = args["decode"] as? String, !d.isEmpty { decodeMode = d }
    if let h = args["hwdec"] as? String, !h.isEmpty { hwdecOverride = h }
    if let c = args["conf"] as? String { conf = c }
    if let v = args["diskCache"] as? Bool { diskCache = v }
    if let v = args["live"] as? Bool { livePlayback = v }
    if let v = args["dolbyVisionPolicy"] as? Int { dolbyVisionPolicy = v }
    if let v = args["dolbyVisionPolicy"] as? NSNumber { dolbyVisionPolicy = v.intValue }
  }

  private func applySessionOpts(_ core: KotvMpvCore) {
    if !hwdecOverride.isEmpty {
      core.setProperty("hwdec", hwdecOverride)
    } else {
      switch decodeMode {
      case "soft", "no", "sw":
        core.setProperty("hwdec", "no")
      default:
        // 自动/硬解：videotoolbox（软解 DV 在 avfoundation 上易黑帧）。
        core.setProperty("hwdec", "videotoolbox")
      }
    }
    switch dolbyVisionPolicy {
    case 2:
      core.setProperty("demuxer-dovi-profile7", "no")
    case 1:
      core.setProperty("demuxer-dovi-profile7", "yes")
    default:
      core.setProperty("demuxer-dovi-profile7", "auto")
    }
    if livePlayback || !diskCache {
      core.setProperty("cache", "no")
      core.setProperty("cache-pause", "no")
      core.setProperty("cache-pause-initial", "no")
    } else {
      core.setProperty("cache", "yes")
    }
    for (key, value) in KotvMpvOptsParser.parse(conf) {
      core.setProperty(key, value)
    }
  }

  /// 主线程建 layer，mpvQueue 上 init；完成后再回主线程 result。
  private func ensureCore(completion: @escaping (Result<KotvMpvCore, Error>) -> Void) {
    if let core, core.isReady {
      completion(.success(core))
      return
    }
    let win = hostWindow ?? NSApp.mainWindow ?? NSApp.windows.first
    guard let win else {
      completion(.failure(NSError(
        domain: "kotv_mpv", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "no window"]
      )))
      return
    }
    let created = core ?? KotvMpvCore()
    created.onEvent = { [weak self] map in self?.emit(map) }
    guard created.prepareLayers(in: win) else {
      completion(.failure(NSError(
        domain: "kotv_mpv", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "layer prepare failed"]
      )))
      return
    }
    core = created
    created.startMpv { [weak self] ok in
      DispatchQueue.main.async {
        if ok {
          // 初始化后先隐藏，等 open/首帧再显。
          created.setVisible(false)
          completion(.success(created))
          return
        }
        created.destroy {
          self?.core = nil
          completion(.failure(NSError(
            domain: "kotv_mpv", code: 3,
            userInfo: [NSLocalizedDescriptionKey: "mpv init failed"]
          )))
        }
      }
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "isVulkanAvailable":
      result(false)

    case "create":
      ingest(args)
      livePlayback = (args?["live"] as? Bool) ?? livePlayback
      ensureCore { [weak self] res in
        switch res {
        case .success(let c):
          c.asyncMpv {
            self?.applySessionOpts(c)
            DispatchQueue.main.async { result(["ok": true, "ready": true]) }
          }
        case .failure(let e):
          result(FlutterError(code: "CREATE_FAILED", message: e.localizedDescription, details: nil))
        }
      }

    case "open":
      ingest(args)
      livePlayback = (args?["live"] as? Bool) ?? false
      let url = (args?["url"] as? String) ?? ""
      let startAt = (args?["startAtMs"] as? NSNumber)?.int64Value ?? 0
      let props = args?["props"] as? [String: Any]
      let headers = args?["headers"] as? [String: String]
      ensureCore { [weak self] res in
        switch res {
        case .success(let c):
          c.asyncMpv {
            self?.applySessionOpts(c)
            if let props {
              for (k, v) in props { c.setProperty(k, "\(v)") }
            }
            if let headers, !headers.isEmpty {
              let fields = headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
              c.setProperty("http-header-fields", fields)
            }
            c.open(url: url, startAtMs: startAt)
            DispatchQueue.main.async { result(nil) }
          }
        case .failure(let e):
          result(FlutterError(code: "OPEN_FAILED", message: e.localizedDescription, details: nil))
        }
      }

    case "play":
      guard let c = core else { result(nil); return }
      c.asyncMpv { c.play(); DispatchQueue.main.async { result(nil) } }
    case "pause":
      guard let c = core else { result(nil); return }
      c.asyncMpv { c.pause(); DispatchQueue.main.async { result(nil) } }
    case "stop":
      guard let c = core else { result(nil); return }
      c.asyncMpv { c.stop(); DispatchQueue.main.async { result(nil) } }
    case "dispose":
      guard let c = core else { result(nil); return }
      core = nil
      c.destroy { result(nil) }

    case "seek":
      let ms = (args?["positionMs"] as? NSNumber)?.int64Value ?? 0
      guard let c = core else { result(nil); return }
      c.asyncMpv { c.seek(positionMs: ms); DispatchQueue.main.async { result(nil) } }

    case "setVolume":
      let v = (args?["volume"] as? NSNumber)?.doubleValue ?? 100
      guard let c = core else { result(nil); return }
      c.asyncMpv { c.setVolume(v); DispatchQueue.main.async { result(nil) } }

    case "setRate":
      let r = (args?["rate"] as? NSNumber)?.doubleValue ?? 1
      guard let c = core else { result(nil); return }
      c.asyncMpv { c.setRate(r); DispatchQueue.main.async { result(nil) } }

    case "setAspect":
      let mode = (args?["mode"] as? String) ?? "default"
      guard let c = core else { result(nil); return }
      c.asyncMpv { c.setAspect(mode); DispatchQueue.main.async { result(nil) } }

    case "setOpts", "setDecode":
      ingest(args)
      let props = args?["props"] as? [String: Any]
      guard let c = core else { result(nil); return }
      c.asyncMpv { [weak self] in
        self?.applySessionOpts(c)
        if let props {
          for (k, v) in props { c.setProperty(k, "\(v)") }
        }
        DispatchQueue.main.async { result(nil) }
      }

    case "setRepeatOne":
      let on = (args?["on"] as? Bool) ?? false
      guard let c = core else { result(nil); return }
      c.asyncMpv { c.setProperty("loop-file", on ? "inf" : "no"); DispatchQueue.main.async { result(nil) } }

    case "setAudioOffsetMs":
      let ms = (args?["ms"] as? NSNumber)?.doubleValue
        ?? (args?["audioOffsetMs"] as? NSNumber)?.doubleValue
        ?? 0
      guard let c = core else { result(nil); return }
      c.asyncMpv { c.setProperty("audio-delay", String(ms / 1000.0)); DispatchQueue.main.async { result(nil) } }

    case "setEqualizer":
      let af = args?["audioAf"] as? String
      let vf = args?["videoVf"] as? String
      let scale = args?["subtitleFontScale"] as? NSNumber
      guard let c = core else { result(nil); return }
      c.asyncMpv {
        if let af { c.setProperty("af", af) }
        if let vf { c.setProperty("vf", vf) }
        if let scale { c.setProperty("sub-scale", "\(scale.doubleValue)") }
        DispatchQueue.main.async { result(nil) }
      }

    case "setAudioTrack":
      let id = args?["id"] as? String
      guard let c = core else { result(nil); return }
      c.asyncMpv {
        if let id { c.command(["set", "aid", id]) }
        DispatchQueue.main.async { result(nil) }
      }
    case "setVideoTrack":
      let id = args?["id"] as? String
      guard let c = core else { result(nil); return }
      c.asyncMpv {
        if let id { c.command(["set", "vid", id]) }
        DispatchQueue.main.async { result(nil) }
      }
    case "setSubtitleTrack":
      let id = args?["id"] as? String
      guard let c = core else { result(nil); return }
      c.asyncMpv {
        if let id { c.command(["set", "sid", id]) }
        DispatchQueue.main.async { result(nil) }
      }
    case "setSecondarySubtitleTrack":
      let id = args?["id"] as? String
      guard let c = core else { result(nil); return }
      c.asyncMpv {
        if let id { c.command(["set", "secondary-sid", id]) }
        DispatchQueue.main.async { result(nil) }
      }

    case "setSubtitleOffsetMs":
      let ms = (args?["ms"] as? NSNumber)?.doubleValue ?? 0
      guard let c = core else { result(nil); return }
      c.asyncMpv { c.setProperty("sub-delay", String(ms / 1000.0)); DispatchQueue.main.async { result(nil) } }

    case "addSubtitle":
      let url = args?["url"] as? String
      guard let c = core else { result(nil); return }
      c.asyncMpv {
        if let url { c.command(["sub-add", url]) }
        DispatchQueue.main.async { result(nil) }
      }

    case "setVisible":
      core?.setVisible((args?["visible"] as? Bool) ?? false)
      result(nil)

    case "updateFrame", "setVideoRect":
      // macOS：忽略洞口矩形，始终铺满 contentView（Win/Linux 另走 HWND/wid）。
      core?.updateFrame()
      result(nil)

    case "videoInfo":
      guard let c = core else { result([:]); return }
      c.asyncMpv {
        let info = c.videoInfo()
        DispatchQueue.main.async { result(info) }
      }

    case "getAudioTracks", "getVideoTracks", "getSubtitleTracks":
      result("[]")
    case "queueNext", "clearNext", "skipToNext":
      result(false)
    case "discTitleCount", "discChapterCount":
      result(0)
    case "setSubtitleStyle", "setRenderMode", "setSurfaceLayerEnabled",
         "setDiscTitle", "setDiscChapter", "openDiscMenu", "retryVideo":
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

enum KotvMpvOptsParser {
  static func parse(_ text: String) -> [(String, String)] {
    var out: [(String, String)] = []
    let managed: Set<String> = [
      "vo", "wid", "gpu-api", "gpu-context", "hwdec", "demuxer-dovi-profile7",
      "cache", "cache-on-disk", "cache-pause", "cache-pause-initial",
    ]
    for raw in text.split(whereSeparator: \.isNewline) {
      var line = raw.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") { continue }
      if let hash = line.firstIndex(of: "#") {
        line = String(line[..<hash]).trimmingCharacters(in: .whitespaces)
      }
      if line.isEmpty { continue }
      let key: String
      let value: String
      if let eq = line.firstIndex(of: "=") {
        key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
        value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
      } else if let sp = line.firstIndex(where: { $0.isWhitespace }) {
        key = String(line[..<sp]).trimmingCharacters(in: .whitespaces)
        value = String(line[line.index(after: sp)...]).trimmingCharacters(in: .whitespaces)
      } else {
        key = line
        value = "yes"
      }
      let base = key.hasPrefix("no-") ? String(key.dropFirst(3)) : key
      if managed.contains(base) || managed.contains(key) { continue }
      out.append((key, value))
    }
    return out
  }
}
