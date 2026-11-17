import Flutter
import UIKit
import Darwin

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "kotv_host",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "getMemoryInfo":
        result(Self.memoryInfo())
      case "getBrightness":
        result(Double(UIScreen.main.brightness) * 100.0)
      case "setBrightness":
        if let p = call.arguments as? Double {
          UIScreen.main.brightness = CGFloat(max(0.01, min(1.0, p / 100.0)))
          result(true)
        } else if let n = call.arguments as? NSNumber {
          UIScreen.main.brightness = CGFloat(max(0.01, min(1.0, n.doubleValue / 100.0)))
          result(true)
        } else {
          result(FlutterError(code: "bad_args", message: "brightness percent", details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
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
