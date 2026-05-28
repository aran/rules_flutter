import Flutter
import UIKit

@main
@objc(AppDelegate)
class AppDelegate: UIResponder, UIApplicationDelegate {
  let engineGroup = FlutterEngineGroup(name: "planner", project: nil)

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return true
  }

  func application(
    _ application: UIApplication,
    configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    // First scene → Tasks (default). Additional scenes → Calendar.
    let hasExistingScene = application.openSessions
      .contains { $0 != connectingSceneSession }
    if hasExistingScene {
      let config = UISceneConfiguration(
        name: "Calendar", sessionRole: connectingSceneSession.role)
      config.delegateClass = CalendarSceneDelegate.self
      return config
    }
    let config = UISceneConfiguration(
      name: "Tasks", sessionRole: connectingSceneSession.role)
    config.delegateClass = TasksSceneDelegate.self
    return config
  }
}
