import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // 默认窗口 1280×720；min 放宽以支持迷你悬浮窗，常态下限由 Dart window_manager 约束
    self.setContentSize(NSSize(width: 1280, height: 720))
    self.minSize = NSSize(width: 280, height: 180)
    self.title = "KO影视"
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
