import FirebaseCore

/// The app's own Swift code on FirebaseCore, the product the firebase_core
/// plugin depends on. Both reach the app from the root's one repository of
/// firebase-ios-sdk, so the app carries one copy of it.
public enum NativeFirebase {
  /// The default Firebase app's name, once the plugin has configured it.
  public static func defaultAppName() -> String? {
    FirebaseApp.app()?.name
  }
}
