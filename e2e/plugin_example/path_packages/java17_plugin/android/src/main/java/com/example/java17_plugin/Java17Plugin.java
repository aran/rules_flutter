package com.example.java17_plugin;

import androidx.annotation.NonNull;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * Answers `describe` on the `java17_plugin` channel. Written with pattern
 * matching for `instanceof` (Java 16) and a switch expression (Java 14), which
 * compile only at the level the plugin's Gradle build declares.
 */
public final class Java17Plugin implements FlutterPlugin, MethodChannel.MethodCallHandler {
  private MethodChannel channel;

  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
    channel = new MethodChannel(binding.getBinaryMessenger(), "java17_plugin");
    channel.setMethodCallHandler(this);
  }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
    channel.setMethodCallHandler(null);
    channel = null;
  }

  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
    switch (call.method) {
      case "describe" -> result.success(describe(call.arguments));
      default -> result.notImplemented();
    }
  }

  private static String describe(Object value) {
    if (value instanceof String text) {
      return "string of " + text.length();
    }
    return "other";
  }
}
