import AppKit
import FlutterMacOS

public class GlassPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "glass_plugin", binaryMessenger: registrar.messenger)
    registrar.addMethodCallDelegate(GlassPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "reduceTransparency":
      result([
        "platform": "macos",
        "reduceTransparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
      ])
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
