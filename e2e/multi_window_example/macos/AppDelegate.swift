import Cocoa
import FlutterMacOS

@main
@objc(AppDelegate)
class AppDelegate: NSObject, NSApplicationDelegate {
  var tasksWindow: TasksWindow!
  var calendarWindow: CalendarWindow!

  func applicationDidFinishLaunching(_ notification: Notification) {
    let tasksEngine = FlutterEngine(name: "tasks", project: nil)
    tasksEngine.run(withEntrypoint: nil)

    let calendarEngine = FlutterEngine(name: "calendar", project: nil)
    calendarEngine.run(withEntrypoint: "calendarMain")

    RegisterGeneratedPlugins(registry: tasksEngine)
    RegisterGeneratedPlugins(registry: calendarEngine)

    let tasksVC = FlutterViewController(engine: tasksEngine, nibName: nil, bundle: nil)
    let calendarVC = FlutterViewController(engine: calendarEngine, nibName: nil, bundle: nil)

    tasksWindow = TasksWindow(flutterViewController: tasksVC)
    calendarWindow = CalendarWindow(flutterViewController: calendarVC)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
