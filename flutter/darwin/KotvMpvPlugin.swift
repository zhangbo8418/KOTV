import Foundation
#if os(macOS)
import Cocoa
import FlutterMacOS
#else
import Flutter
import UIKit
#endif

/// MethodChannel `kotv_mpv` / EventChannel `kotv_mpv/events`（macOS / iOS 共用）。
///
/// mpv API 一律经 [KotvMpvCore.asyncMpv]；layer 显隐/几何留在主线程。
final class KotvMpvPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var core: KotvMpvCore?
  private var eventSink: FlutterEventSink?
  /// Dart [KotvMpvOpts.hwdecValue]。
  private var hwdec = ""
  private var vulkan = false
  private var conf = ""
  private var diskCache = false
  private var livePlayback = false
  /// 单集循环时不排下一集。
  private var repeatOne = false
  private weak var hostWindow: KotvMpvWindow?
  /// Dart 洞（顶左原点）。core 重建间隙 updateFrame 可能落到 nil，须缓存到 ensureCore 后再应用。
  private var pendingHoleFlutter: CGRect?

  static func register(with registrar: FlutterPluginRegistrar, window: KotvMpvWindow?) {
    let instance = KotvMpvPlugin()
    instance.hostWindow = window
    #if os(macOS)
    let messenger = registrar.messenger
    #else
    let messenger = registrar.messenger()
    #endif
    let method = FlutterMethodChannel(name: "kotv_mpv", binaryMessenger: messenger)
    let events = FlutterEventChannel(name: "kotv_mpv/events", binaryMessenger: messenger)
    registrar.addMethodCallDelegate(instance, channel: method)
    events.setStreamHandler(instance)
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    register(with: registrar, window: nil)
  }

  /// 注册时窗口可能还没建好（iOS 隐式引擎），用到时再找。
  private func resolveWindow() -> KotvMpvWindow? {
    if let hostWindow { return hostWindow }
    #if os(macOS)
    hostWindow = NSApp.mainWindow ?? NSApp.windows.first
    #else
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let windows = scenes.flatMap(\.windows)
    hostWindow = windows.first(where: \.isKeyWindow)
      ?? windows.first(where: { $0.rootViewController is FlutterViewController })
    #endif
    return hostWindow
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
    if let h = args["hwdec"] as? String, !h.isEmpty { hwdec = h }
    if let v = args["vulkan"] as? Bool { vulkan = v && KotvMpvCore.isVulkanAvailable }
    if let c = args["conf"] as? String { conf = c }
    if let v = args["diskCache"] as? Bool { diskCache = v }
    if let v = args["live"] as? Bool { livePlayback = v }
    if let v = args["repeatOne"] as? Bool { repeatOne = v }
  }

  private func applySessionOpts(_ core: KotvMpvCore) {
    if !hwdec.isEmpty { core.setProperty("hwdec", hwdec) }
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
  /// Vulkan 开关只在新建 core 时生效（dispose 后下次播放）。
  private func ensureCore(completion: @escaping (Result<KotvMpvCore, Error>) -> Void) {
    if let core, core.isReady {
      completion(.success(core))
      return
    }
    guard let win = resolveWindow() else {
      completion(.failure(NSError(
        domain: "kotv_mpv", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "no window"]
      )))
      return
    }
    let created = core ?? KotvMpvCore(vulkan: vulkan)
    created.onEvent = { [weak self] map in self?.emit(map) }
    guard created.prepareLayers(in: win) else {
      completion(.failure(NSError(
        domain: "kotv_mpv", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "layer prepare failed"]
      )))
      return
    }
    core = created
    applyPendingHole(to: created)
    created.startMpv { [weak self] ok in
      DispatchQueue.main.async {
        if ok {
          // 初始化后先隐藏，等 open/首帧再显。
          created.setVisible(false)
          self?.applyPendingHole(to: created)
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

  private func applyPendingHole(to core: KotvMpvCore) {
    guard let hole = pendingHoleFlutter, hole.width > 1, hole.height > 1 else { return }
    core.updateFrame(hole)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "isVulkanAvailable":
      result(KotvMpvCore.isVulkanAvailable)

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
          // 主线程先套洞，再进 mpvQueue open，避免 hasHole=false → 一角。
          self?.applyPendingHole(to: c)
          c.asyncMpv {
            self?.applySessionOpts(c)
            if let props {
              for (k, v) in props { c.setProperty(k, "\(v)") }
            }
            if let headers, !headers.isEmpty {
              // mpv 的字符串列表以逗号分隔，值里的逗号（如 UA 的 "KHTML, like Gecko"）要转义。
              let fields = headers
                .map { "\($0.key): \($0.value)".replacingOccurrences(of: ",", with: "\\,") }
                .joined(separator: ",")
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
      repeatOne = on
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

    case "setAudioTrack", "setVideoTrack", "setSubtitleTrack", "setSecondarySubtitleTrack":
      let prop: String
      switch call.method {
      case "setAudioTrack": prop = "aid"
      case "setVideoTrack": prop = "vid"
      case "setSubtitleTrack": prop = "sid"
      default: prop = "secondary-sid"
      }
      // 与 Dart 同口径：字幕空 id = 关闭，音视频空 id = 自动。
      var id = (args?["id"] as? String) ?? ""
      let key = id.lowercased()
      let sub = prop == "sid" || prop == "secondary-sid"
      if key == "off" || key == "none" || (key.isEmpty && sub) { id = "no" }
      if key.isEmpty && !sub { id = "auto" }
      guard let c = core else { result(nil); return }
      c.asyncMpv {
        c.command(["set", prop, id])
        DispatchQueue.main.async { result(nil) }
      }

    case "setSubtitleOffsetMs":
      let ms = (args?["ms"] as? NSNumber)?.doubleValue ?? 0
      guard let c = core else { result(nil); return }
      c.asyncMpv { c.setProperty("sub-delay", String(ms / 1000.0)); DispatchQueue.main.async { result(nil) } }

    case "addSubtitle":
      let path = (args?["path"] as? String) ?? ""
      let title = (args?["title"] as? String) ?? ""
      let select = (args?["select"] as? Bool) ?? true
      guard let c = core, !path.isEmpty else { result(nil); return }
      c.asyncMpv {
        var cmd = ["sub-add", path, select ? "select" : "auto"]
        if !title.isEmpty { cmd.append(title) }
        c.command(cmd)
        DispatchQueue.main.async { result(nil) }
      }

    case "setVisible":
      // 显隐只由原生 open/stop/遮挡/前后台驱动；忽略通道，避免洞组件双写。
      result(nil)

    case "updateFrame", "setVideoRect":
      // Dart 逻辑坐标（顶左原点）；Core 内转成宿主层坐标。
      if let x = (args?["x"] as? NSNumber)?.doubleValue,
         let y = (args?["y"] as? NSNumber)?.doubleValue,
         let w = (args?["w"] as? NSNumber)?.doubleValue
          ?? (args?["width"] as? NSNumber)?.doubleValue,
         let h = (args?["h"] as? NSNumber)?.doubleValue
          ?? (args?["height"] as? NSNumber)?.doubleValue,
         w > 1, h > 1
      {
        let hole = CGRect(x: x, y: y, width: w, height: h)
        pendingHoleFlutter = hole
        if let c = core {
          c.updateFrame(hole)
        }
      } else {
        core?.updateFrame()
      }
      result(nil)

    case "videoInfo":
      guard let c = core else { result([:]); return }
      c.asyncMpv {
        let info = c.videoInfo()
        DispatchQueue.main.async { result(info) }
      }

    case "getAudioTracks", "getVideoTracks", "getSubtitleTracks":
      let type = call.method == "getAudioTracks" ? "audio" : call.method == "getVideoTracks" ? "video" : "sub"
      guard let c = core else { result("[]"); return }
      c.asyncMpv {
        let json = c.tracksJSON(type: type)
        DispatchQueue.main.async { result(json) }
      }

    case "queueNext":
      let id = (args?["id"] as? String) ?? ""
      let url = (args?["url"] as? String) ?? ""
      let startAt = (args?["startAtMs"] as? NSNumber)?.int64Value ?? 0
      let subs = (args?["subs"] as? [[String: Any]]) ?? []
      guard let c = core, !livePlayback, !repeatOne, !id.isEmpty, !url.isEmpty else {
        result(false)
        return
      }
      c.asyncMpv {
        c.queueNext(id: id, url: url, startAtMs: startAt, subs: subs)
        DispatchQueue.main.async { result(true) }
      }
    case "clearNext":
      guard let c = core else { result(nil); return }
      c.asyncMpv { c.clearNext(); DispatchQueue.main.async { result(nil) } }
    case "skipToNext":
      guard let c = core else { result(false); return }
      c.asyncMpv {
        let ok = c.skipToNext()
        DispatchQueue.main.async { result(ok) }
      }

    case "discInfo":
      guard let c = core else { result([:]); return }
      c.asyncMpv {
        let info = c.discInfo()
        DispatchQueue.main.async { result(info) }
      }
    case "setDiscTitle", "setDiscChapter":
      let index = (args?["index"] as? NSNumber)?.intValue ?? -1
      guard let c = core, index >= 0 else { result(nil); return }
      let prop = call.method == "setDiscTitle" ? "edition" : "chapter"
      c.asyncMpv { c.setProperty(prop, String(index)); DispatchQueue.main.async { result(nil) } }
    case "discNav":
      let action = (args?["action"] as? String) ?? ""
      let x = (args?["x"] as? NSNumber)?.doubleValue
      let y = (args?["y"] as? NSNumber)?.doubleValue
      guard let c = core, !action.isEmpty else { result(nil); return }
      c.asyncMpv { c.discNav(action, x: x, y: y); DispatchQueue.main.async { result(nil) } }

    case "setSubtitleStyle", "setRenderMode", "setSurfaceLayerEnabled", "retryVideo":
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
