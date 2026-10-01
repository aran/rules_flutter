/// A package shaped like a Liquid Glass UI kit: fragment shaders bundled
/// under `flutter: shaders:` and a native plugin reading an accessibility
/// setting.
library;

import 'dart:ui' as ui;

import 'package:flutter/services.dart';

/// The package's fragment programs, loaded from its own bundle.
class GlassShaders {
  GlassShaders._(this.tint, this.invert);

  /// Fills with one colour; for `Paint.shader`.
  final ui.FragmentProgram tint;

  /// Inverts its input; for `ImageFilter.shader`.
  final ui.FragmentProgram invert;

  /// Loads both programs. A package's shaders are bundled under
  /// `packages/<package>/`, as its other assets are.
  static Future<GlassShaders> load() async => GlassShaders._(
    await ui.FragmentProgram.fromAsset(
      'packages/glass_plugin/shaders/tint.frag',
    ),
    await ui.FragmentProgram.fromAsset(
      'packages/glass_plugin/shaders/invert.frag',
    ),
  );
}

const _channel = MethodChannel('glass_plugin');

/// What the native side reports: which platform answered, and whether the
/// user asked for reduced transparency.
Future<Map<String, Object?>> reduceTransparency() async {
  final reply = await _channel.invokeMapMethod<String, Object?>(
    'reduceTransparency',
  );
  return reply ?? const {};
}
