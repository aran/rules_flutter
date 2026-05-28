# Minimal app-level keep rules — exists only to enable R8 (android_binary
# runs the shrinker only when proguard_specs is non-empty). Per-plugin
# keep rules flow in transitively from each spoke's consumer-rules.pro,
# wired via `kt_android_library(proguard_specs = ...)` in
# `_make_android_subpackage_build_content`.

# Keep the runner activity that the manifest references.
-keep class com.example.plugin_example.MainActivity { *; }

# Keep the auto-generated Flutter plugin registrant.
-keep class io.flutter.plugins.GeneratedPluginRegistrant { *; }

# androidx.window probes reflectively for vendor-provided sidecar
# classes; suppressing missing-class warnings is the standard
# Flutter-Android pattern (matches what flutter create's app proguard
# emits).
-dontwarn androidx.window.**
-dontwarn com.google.common.util.concurrent.ListenableFuture
