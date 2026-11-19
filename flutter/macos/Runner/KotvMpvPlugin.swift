import Cocoa
import FlutterMacOS

/// MethodChannel `kotv_mpv` / EventChannel `kotv_mpv/events`（与 Android 同名）。
final class KotvMpvPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var core: KotvMpvCore?
  private var eventSink: FlutterEventSink?
  private var decodeMode = "auto"
  /// Dart `KotvMpvOpts.hwdecValue()`；非空则优先于 decode 映射。
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

  /// 兼容旧注册签名。
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

  private func ensureCore() throws -> KotvMpvCore {
    if let core { return core }
    let created = KotvMpvCore()
    created.onEvent = { [weak self] map in self?.emit(map) }
    let win = hostWindow ?? NSApp.mainWindow ?? NSApp.windows.first
    guard let win, created.initialize(in: win) else {
      throw NSError(
        domain: "kotv_mpv",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "mpv init failed"]
      )
    }
    core = created
    applySessionOpts(created)
    return created
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

  /// hwdec 写入点：优先 Dart 下发；否则 decode → auto/videotoolbox/no。
  private func applySessionOpts(_ core: KotvMpvCore) {
    if !hwdecOverride.isEmpty {
      core.setProperty("hwdec", hwdecOverride)
    } else {
      switch decodeMode {
      case "soft", "no", "sw":
        core.setProperty("hwdec", "no")
      case "hard", "hw":
        core.setProperty("hwdec", "videotoolbox")
      default:
        core.setProperty("hwdec", "auto")
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

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "isVulkanAvailable":
      result(false)
    case "create":
      ingest(args)
      livePlayback = (args?["live"] as? Bool) ?? livePlayback
      do {
        let c = try ensureCore()
        applySessionOpts(c)
        result(["ok": true, "ready": true])
      } catch {
        result(FlutterError(code: "CREATE_FAILED", message: error.localizedDescription, details: nil))
      }
    case "open":
      ingest(args)
      livePlayback = (args?["live"] as? Bool) ?? false
      let url = (args?["url"] as? String) ?? ""
      let startAt = (args?["startAtMs"] as? NSNumber)?.int64Value ?? 0
      do {
        let c = try ensureCore()
        applySessionOpts(c)
        if let props = args?["props"] as? [String: Any] {
          for (k, v) in props { c.setProperty(k, "\(v)") }
        }
        if let headers = args?["headers"] as? [String: String], !headers.isEmpty {
          let fields = headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
          c.setProperty("http-header-fields", fields)
        }
        c.open(url: url, startAtMs: startAt)
        result(nil)
      } catch {
        result(FlutterError(code: "OPEN_FAILED", message: error.localizedDescription, details: nil))
      }
    case "play":
      core?.play(); result(nil)
    case "pause":
      core?.pause(); result(nil)
    case "stop":
      core?.stop(); result(nil)
    case "dispose":
      core?.destroy()
      core = nil
      result(nil)
    case "seek":
      core?.seek(positionMs: (args?["positionMs"] as? NSNumber)?.int64Value ?? 0)
      result(nil)
    case "setVolume":
      core?.setVolume((args?["volume"] as? NSNumber)?.doubleValue ?? 100)
      result(nil)
    case "setRate":
      core?.setRate((args?["rate"] as? NSNumber)?.doubleValue ?? 1)
      result(nil)
    case "setAspect":
      core?.setAspect((args?["mode"] as? String) ?? "default")
      result(nil)
    case "setOpts":
      ingest(args)
      if let c = core { applySessionOpts(c) }
      if let props = args?["props"] as? [String: Any] {
        for (k, v) in props { core?.setProperty(k, "\(v)") }
      }
      result(nil)
    case "setDecode":
      ingest(args)
      if let c = core { applySessionOpts(c) }
      result(nil)
    case "setRepeatOne":
      core?.setProperty("loop-file", ((args?["on"] as? Bool) ?? false) ? "inf" : "no")
      result(nil)
    case "setAudioOffsetMs":
      let ms = (args?["ms"] as? NSNumber)?.doubleValue
        ?? (args?["audioOffsetMs"] as? NSNumber)?.doubleValue
        ?? 0
      core?.setProperty("audio-delay", String(ms / 1000.0))
      result(nil)
    case "setEqualizer":
      if let af = args?["audioAf"] as? String { core?.setProperty("af", af) }
      if let vf = args?["videoVf"] as? String { core?.setProperty("vf", vf) }
      if let scale = args?["subtitleFontScale"] as? NSNumber {
        core?.setProperty("sub-scale", "\(scale.doubleValue)")
      }
      result(nil)
    case "setAudioTrack":
      if let id = args?["id"] as? String { core?.command(["set", "aid", id]) }
      result(nil)
    case "setVideoTrack":
      if let id = args?["id"] as? String { core?.command(["set", "vid", id]) }
      result(nil)
    case "setSubtitleTrack":
      if let id = args?["id"] as? String { core?.command(["set", "sid", id]) }
      result(nil)
    case "setSecondarySubtitleTrack":
      if let id = args?["id"] as? String { core?.command(["set", "secondary-sid", id]) }
      result(nil)
    case "setSubtitleOffsetMs":
      let ms = (args?["ms"] as? NSNumber)?.doubleValue ?? 0
      core?.setProperty("sub-delay", String(ms / 1000.0))
      result(nil)
    case "setSubtitleStyle":
      result(nil)
    case "addSubtitle":
      if let url = args?["url"] as? String { core?.command(["sub-add", url]) }
      result(nil)
    case "setRenderMode", "setSurfaceLayerEnabled":
      result(nil)
    case "setVisible":
      let visible = (args?["visible"] as? Bool) ?? false
      core?.setVisible(visible)
      result(nil)
    case "updateFrame", "setVideoRect":
      if let x = (args?["x"] as? NSNumber)?.doubleValue,
         let y = (args?["y"] as? NSNumber)?.doubleValue,
         let w = (args?["w"] as? NSNumber)?.doubleValue
          ?? (args?["width"] as? NSNumber)?.doubleValue,
         let h = (args?["h"] as? NSNumber)?.doubleValue
          ?? (args?["height"] as? NSNumber)?.doubleValue
      {
        core?.updateFrame(CGRect(x: x, y: y, width: w, height: h))
      } else {
        core?.updateFrame(nil)
      }
      result(nil)
    case "getAudioTracks", "getVideoTracks", "getSubtitleTracks":
      result("[]")
    case "videoInfo":
      result(core?.videoInfo() ?? [:])
    case "queueNext", "clearNext", "skipToNext":
      result(false)
    case "discTitleCount", "discChapterCount":
      result(0)
    case "setDiscTitle", "setDiscChapter", "openDiscMenu", "retryVideo":
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// 极简 mpv.conf 解析（与 Dart `KotvMpvOpts.parseConfLines` 同语义子集）。
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
