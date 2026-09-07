import Cocoa
import FlutterMacOS
import Darwin

class MainFlutterWindow: NSWindow {
  private var hostChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // 默认窗口 1280×720；min 放宽以支持迷你悬浮窗，常态下限由 Dart window_manager 约束
    self.setContentSize(NSSize(width: 1280, height: 720))
    self.minSize = NSSize(width: 280, height: 180)
    self.title = "KO影视"
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

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
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    hostChannel = ch

    super.awakeFromNib()
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
