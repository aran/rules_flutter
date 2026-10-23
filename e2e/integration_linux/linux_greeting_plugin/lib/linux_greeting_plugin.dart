import 'package:flutter/services.dart';

/// Method-channel client for the native Linux C++ greeting plugin.
class LinuxGreetingPlugin {
  /// Creates a [LinuxGreetingPlugin] instance.
  const LinuxGreetingPlugin();

  static const MethodChannel _channel = MethodChannel(
    'rules_flutter/linux_greeting',
  );

  /// Requests the greeting string from the native Linux C++ plugin.
  Future<String?> getGreeting() {
    return _channel.invokeMethod<String>('getGreeting');
  }
}
