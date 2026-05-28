import Flutter
import UIKit

class PlannerSceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  var entrypoint: String? { nil }
  var sceneTitle: String { "" }
  var activityType: String { "" }

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else { return }
    windowScene.title = sceneTitle
    scene.userActivity = NSUserActivity(activityType: activityType)
    scene.userActivity?.title = sceneTitle

    let appDelegate = UIApplication.shared.delegate as! AppDelegate
    let engine = appDelegate.engineGroup.makeEngine(
      withEntrypoint: entrypoint, libraryURI: nil)
    GeneratedPluginRegistrant.register(with: engine)

    let flutterVC = FlutterViewController(engine: engine, nibName: nil, bundle: nil)

    window = UIWindow(windowScene: windowScene)
    window?.rootViewController = flutterVC
    window?.makeKeyAndVisible()
  }
}

class TasksSceneDelegate: PlannerSceneDelegate {
  override var sceneTitle: String { "Tasks" }
  override var activityType: String { "com.example.planner.tasks" }
}

class CalendarSceneDelegate: PlannerSceneDelegate {
  override var entrypoint: String? { "calendarMain" }
  override var sceneTitle: String { "Calendar" }
  override var activityType: String { "com.example.planner.calendar" }
}
