/// Plugin that provides a greeting service.
///
/// Demonstrates a flutter_plugin with dart_plugin_class only (no native code).
/// The generated registrant calls GreetingPlugin.registerWith() at startup,
/// matching the no-arg signature pub.dev's Dart-side plugins use on
/// non-web platforms (e.g. PathProviderFoundation, UrlLauncherMacOS).
library greeting_plugin;

class GreetingPlugin {
  static String? _customGreeting;

  /// Called by the generated plugin registrant at app startup.
  static void registerWith() {
    _customGreeting = 'Hello from GreetingPlugin!';
  }

  /// Returns the greeting set during registration.
  static String get greeting => _customGreeting ?? 'No greeting registered';
}
