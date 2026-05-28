import Cocoa
import FlutterMacOS

class PlannerWindow: NSWindow {
  convenience init(
    flutterViewController: FlutterViewController,
    windowTitle: String,
    size: NSSize,
    horizontalOffset: CGFloat
  ) {
    self.init(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    let windowFrame = self.frame
    title = windowTitle
    contentViewController = flutterViewController
    setFrame(windowFrame, display: true)

    if let screen = NSScreen.main {
      let screenFrame = screen.visibleFrame
      let x = screenFrame.midX + horizontalOffset
      let y = screenFrame.midY - windowFrame.height / 2
      setFrameOrigin(NSPoint(x: x, y: y))
    }

    makeKeyAndOrderFront(nil)
  }
}

@objc(TasksWindow)
class TasksWindow: PlannerWindow {
  convenience init(flutterViewController: FlutterViewController) {
    self.init(
      flutterViewController: flutterViewController,
      windowTitle: "Planner — Tasks",
      size: NSSize(width: 480, height: 640),
      horizontalOffset: -500
    )
  }
}

@objc(CalendarWindow)
class CalendarWindow: PlannerWindow {
  convenience init(flutterViewController: FlutterViewController) {
    self.init(
      flutterViewController: flutterViewController,
      windowTitle: "Planner — Calendar",
      size: NSSize(width: 600, height: 480),
      horizontalOffset: 20
    )
  }
}
