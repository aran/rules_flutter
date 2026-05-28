import Cocoa
import FlutterMacOS

@objc(MainFlutterWindow)
class MainFlutterWindow: NSWindow {
  convenience init(flutterViewController: FlutterViewController) {
    self.init(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    let windowFrame = self.frame
    self.title = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ""
    contentViewController = flutterViewController
    setFrame(windowFrame, display: true)
    center()
    makeKeyAndOrderFront(nil)
  }
}
