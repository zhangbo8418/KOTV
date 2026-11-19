import Cocoa
import FlutterMacOS
import Darwin
import UniformTypeIdentifiers
#if arch(x86_64)
import ObjectiveC
#endif

class MainFlutterWindow: NSWindow {
  /// 强引用 MethodChannel，避免 awakeFromNib 返回后通道被释放。
  private var hostChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    // Flutter 3.47 的 Impeller 在 Intel Mac 上滚动界面时整窗闪烁。
    // 修复在 3.48 稳定版里还没有。x86_64 切片在引擎读 Info.plist 之前关掉 Impeller，界面走 Skia。
    // arm64 编译不到这段，仍用 Impeller。
    #if arch(x86_64)
    kotvUseSkiaOnIntel()
    #endif

    let flutterViewController = FlutterViewController()
    // 窗口不透明，避免整窗与桌面混合；Flutter 透明，露出 contentView.layer 下的 ASBDL。
    self.isOpaque = true
    self.backgroundColor = .black
    flutterViewController.backgroundColor = .clear
    self.contentViewController = flutterViewController

    // 默认窗口 1280×720；min 放宽以支持迷你悬浮窗，常态下限由 Dart window_manager 约束
    self.setContentSize(NSSize(width: 1280, height: 720))
    self.minSize = NSSize(width: 280, height: 180)
    self.title = "KO影视"
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)
    KotvMpvPlugin.register(
      with: flutterViewController.registrar(forPlugin: "KotvMpvPlugin"),
      window: self
    )

    let ch = FlutterMethodChannel(
      name: "kotv_host",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    ch.setMethodCallHandler { call, result in
      switch call.method {
      case "getInterfaceRxBytes":
        result(Self.interfaceRxBytes())
      case "getMemoryInfo":
        result(Self.memoryInfo())
      case "hasExternalVideoApp":
        result(Self.hasExternalVideoApp())
      case "listExternalVideoApps":
        result(Self.listExternalVideoApps())
      case "openExternalVideoApp":
        guard let args = call.arguments as? [String: Any],
              let id = args["id"] as? String,
              let url = args["url"] as? String else {
          result(FlutterError(code: "args", message: "id/url required", details: nil))
          return
        }
        Self.openExternalVideoApp(id: id, url: url) { ok in
          result(ok)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    hostChannel = ch

    super.awakeFromNib()
  }

  /// 浏览器会抢 http URL；外置列表只留视频类应用。
  private static let browserBundleIds: Set<String> = [
    "com.apple.Safari",
    "com.apple.SafariTechnologyPreview",
    "com.google.Chrome",
    "com.google.Chrome.canary",
    "com.google.Chrome.beta",
    "org.mozilla.firefox",
    "org.mozilla.firefoxdeveloperedition",
    "com.microsoft.edgemac",
    "com.microsoft.edgemac.canary",
    "com.operasoftware.Opera",
    "com.brave.Browser",
    "com.vivaldi.Vivaldi",
    "company.thebrowser.Browser",
    "com.apple.WebKit.Networking",
  ]

  /// 候选应用 URL（按视频/播放列表类型合并去重前的原始列表）。
  private static func candidateExternalVideoAppURLs() -> [URL] {
    var appURLs: [URL] = []
    if #available(macOS 12.0, *) {
      let workspace = NSWorkspace.shared
      appURLs += workspace.urlsForApplications(toOpen: .mpeg4Movie)
      appURLs += workspace.urlsForApplications(toOpen: .quickTimeMovie)
      appURLs += workspace.urlsForApplications(toOpen: .mpeg2TransportStream)
      if let avi = UTType(filenameExtension: "avi") {
        appURLs += workspace.urlsForApplications(toOpen: avi)
      }
      if let m3u = UTType(filenameExtension: "m3u") {
        appURLs += workspace.urlsForApplications(toOpen: m3u)
      }
      if let m3u8 = UTType(filenameExtension: "m3u8") {
        appURLs += workspace.urlsForApplications(toOpen: m3u8)
      }
    } else {
      for name in ["IINA", "VLC", "mpv", "QuickTime Player", "Elmedia Video Player", "Movist Pro"] {
        if let path = NSWorkspace.shared.fullPath(forApplication: name) {
          appURLs.append(URL(fileURLWithPath: path))
        }
      }
    }
    return appURLs
  }

  /// 遍历本机视频应用；[visit] 返回 false 时提前结束（供 has/list 共用）。
  private static func forEachExternalVideoApp(_ visit: (_ appURL: URL, _ id: String, _ name: String) -> Bool) {
    let selfId = Bundle.main.bundleIdentifier ?? ""
    var seen = Set<String>()
    for appURL in candidateExternalVideoAppURLs() {
      guard let bid = Bundle(url: appURL)?.bundleIdentifier, !bid.isEmpty else { continue }
      if bid == selfId || browserBundleIds.contains(bid) { continue }
      if !seen.insert(bid).inserted { continue }
      let name = FileManager.default.displayName(atPath: appURL.path)
      if !visit(appURL, bid, name) { return }
    }
  }

  private static func hasExternalVideoApp() -> Bool {
    var found = false
    forEachExternalVideoApp { _, _, _ in
      found = true
      return false
    }
    return found
  }

  /// 本机视频应用列表（排除浏览器与自身），带 64px PNG 图标。
  private static func listExternalVideoApps() -> [[String: Any]] {
    var out: [[String: Any]] = []
    forEachExternalVideoApp { appURL, bid, name in
      var row: [String: Any] = ["id": bid, "name": name]
      if let png = pngIcon(forAppAt: appURL, side: 64) {
        row["icon"] = FlutterStandardTypedData(bytes: png)
      }
      out.append(row)
      return true
    }
    out.sort {
      let a = ($0["name"] as? String) ?? ""
      let b = ($1["name"] as? String) ?? ""
      return a.localizedCompare(b) == .orderedAscending
    }
    return out
  }

  /// `/usr/bin/open -b <bundleId> <播放地址>`：把当前播放地址原样交给选定应用。
  private static func openExternalVideoApp(id: String, url: String, completion: @escaping (Bool) -> Void) {
    let bid = id.trimmingCharacters(in: .whitespacesAndNewlines)
    let raw = url.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !bid.isEmpty, !raw.isEmpty else {
      completion(false)
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let proc = Process()
      proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
      proc.arguments = ["-b", bid, raw]
      do {
        try proc.run()
        proc.waitUntilExit()
        let ok = proc.terminationStatus == 0
        DispatchQueue.main.async { completion(ok) }
      } catch {
        DispatchQueue.main.async { completion(false) }
      }
    }
  }

  private static func pngIcon(forAppAt appURL: URL, side: Int) -> Data? {
    let src = NSWorkspace.shared.icon(forFile: appURL.path)
    guard let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: side,
      pixelsHigh: side,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ) else {
      return nil
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    src.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
  }

  /// 网卡累计下行字节（跳过 lo0）。缓冲期差分即网速。
  private static func interfaceRxBytes() -> Int64 {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return -1 }
    defer { freeifaddrs(ifaddr) }

    var total: UInt64 = 0
    var ptr: UnsafeMutablePointer<ifaddrs>? = first
    while let cur = ptr {
      let name = String(cString: cur.pointee.ifa_name)
      if name != "lo0",
         let addr = cur.pointee.ifa_addr,
         addr.pointee.sa_family == UInt8(AF_LINK),
         let dataPtr = cur.pointee.ifa_data {
        let data = dataPtr.assumingMemoryBound(to: if_data.self).pointee
        total &+= UInt64(data.ifi_ibytes)
      }
      ptr = cur.pointee.ifa_next
    }
    return Int64(bitPattern: total)
  }

  private static func memoryInfo() -> [String: Int64] {
    let total = Int64(ProcessInfo.processInfo.physicalMemory)
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
    let host = mach_host_self()
    let kr = withUnsafeMutablePointer(to: &stats) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(host, HOST_VM_INFO64, $0, &count)
      }
    }
    var pageSize: vm_size_t = 0
    host_page_size(host, &pageSize)
    let avail: Int64
    if kr == KERN_SUCCESS {
      let freePages = UInt64(stats.free_count + stats.inactive_count + stats.purgeable_count)
      avail = Int64(freePages * UInt64(pageSize))
    } else {
      avail = 0
    }
    return ["totalBytes": total, "availBytes": avail]
  }
}

#if arch(x86_64)
private func kotvUseSkiaOnIntel() {
  let bundle: AnyClass = Bundle.self
  let original = NSSelectorFromString("objectForInfoDictionaryKey:")
  let replacement = #selector(Bundle.kotv_objectForInfoDictionaryKey(_:))
  guard let from = class_getInstanceMethod(bundle, original),
        let to = class_getInstanceMethod(bundle, replacement) else {
    return
  }
  method_exchangeImplementations(from, to)
}

extension Bundle {
  @objc func kotv_objectForInfoDictionaryKey(_ key: String) -> Any? {
    if key == "FLTEnableImpeller" {
      return NSNumber(value: false)
    }
    return kotv_objectForInfoDictionaryKey(key)
  }
}
#endif
