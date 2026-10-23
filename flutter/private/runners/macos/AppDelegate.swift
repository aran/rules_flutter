import Cocoa
import FlutterMacOS

@main
@objc(AppDelegate)
class AppDelegate: FlutterAppDelegate {
  override func applicationDidFinishLaunching(_ notification: Notification) {
    if NSApp.mainMenu == nil {
      setupDefaultMainMenu()
    }

    let flutterViewController = FlutterViewController()
    RegisterGeneratedPlugins(registry: flutterViewController)

    let window = MainFlutterWindow(flutterViewController: flutterViewController)
    mainFlutterWindow = window

    super.applicationDidFinishLaunching(notification)
  }

  private func setupDefaultMainMenu() {
    let appName =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
      ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
      ?? ProcessInfo.processInfo.processName

    let mainMenu = NSMenu()

    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)
    let appMenu = NSMenu()
    appMenu.addItem(
      withTitle: "About \(appName)",
      action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
      keyEquivalent: ""
    )
    appMenu.addItem(NSMenuItem.separator())
    appMenu.addItem(
      withTitle: "Hide \(appName)",
      action: #selector(NSApplication.hide(_:)),
      keyEquivalent: "h"
    )
    let hideOthers = appMenu.addItem(
      withTitle: "Hide Others",
      action: #selector(NSApplication.hideOtherApplications(_:)),
      keyEquivalent: "h"
    )
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    appMenu.addItem(
      withTitle: "Show All",
      action: #selector(NSApplication.unhideAllApplications(_:)),
      keyEquivalent: ""
    )
    appMenu.addItem(NSMenuItem.separator())
    appMenu.addItem(
      withTitle: "Quit \(appName)",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )
    appMenuItem.submenu = appMenu

    let windowMenuItem = NSMenuItem()
    mainMenu.addItem(windowMenuItem)
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(
      withTitle: "Minimize",
      action: #selector(NSWindow.performMiniaturize(_:)),
      keyEquivalent: "m"
    )
    windowMenu.addItem(
      withTitle: "Zoom",
      action: #selector(NSWindow.performZoom(_:)),
      keyEquivalent: ""
    )
    windowMenuItem.submenu = windowMenu
    NSApp.windowsMenu = windowMenu

    NSApp.mainMenu = mainMenu
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
