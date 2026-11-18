/// A plugin whose iOS code links a prebuilt dynamic framework.
library;

import 'package:flutter/services.dart';

/// The plugin's channel.
class VendoredPlugin {
  static const _channel = MethodChannel('vendored_plugin');

  /// The greeting the prebuilt framework answers with.
  static Future<String?> greeting() =>
      _channel.invokeMethod<String>('greeting');
}
