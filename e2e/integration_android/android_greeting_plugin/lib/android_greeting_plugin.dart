import 'package:flutter/services.dart';

/// Method-channel client for the native Android Kotlin greeting plugin.
class AndroidGreetingPlugin {
  /// Creates an [AndroidGreetingPlugin] instance.
  const AndroidGreetingPlugin();

  static const MethodChannel _channel = MethodChannel(
    'rules_flutter/android_greeting',
  );

  /// Requests the greeting string from the native Android Kotlin plugin.
  Future<String?> getGreeting() {
    return _channel.invokeMethod<String>('getGreeting');
  }
}
