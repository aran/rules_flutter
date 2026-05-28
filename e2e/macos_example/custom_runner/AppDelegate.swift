import Cocoa
import FlutterMacOS

@main
@objc(AppDelegate)
class AppDelegate: FlutterAppDelegate {
  override func applicationDidFinishLaunching(_ notification: Notification) {
    let flutterViewController = FlutterViewController()
    RegisterGeneratedPlugins(registry: flutterViewController)

    let window = MainFlutterWindow(flutterViewController: flutterViewController)
    mainFlutterWindow = window

    super.applicationDidFinishLaunching(notification)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
