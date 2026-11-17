/// A Dart-only plugin with one class per desktop platform, each recording its
/// registration.
library;

/// The platforms whose plugin class has been registered, in order.
final List<String> registrations = [];

/// The Linux implementation.
class DartPluginLinux {
  /// Called by the Dart plugin registrant.
  static void registerWith() => registrations.add('linux');
}

/// The macOS implementation.
class DartPluginMacOS {
  /// Called by the Dart plugin registrant.
  static void registerWith() => registrations.add('macos');
}

/// The Windows implementation.
class DartPluginWindows {
  /// Called by the Dart plugin registrant.
  static void registerWith() => registrations.add('windows');
}
