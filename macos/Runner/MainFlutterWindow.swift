import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    // 폰 화면처럼 세로로 긴 창으로 연다 (위치는 그대로, 크기만 바꾼다).
    let windowFrame = NSRect(x: self.frame.origin.x, y: self.frame.origin.y, width: 520, height: 780)
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.title = "도서관 좌석 예약"
    self.minSize = NSSize(width: 380, height: 520)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
