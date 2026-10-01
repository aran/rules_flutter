@Tags(['e2e'])
/// End-to-end: a plugin written in the workspace that ships fragment shaders.
///
/// `e2e/plugin_example`'s `//glass_app` draws with `//glass_plugin`'s two
/// shaders — one as a `Paint.shader`, one as an `ImageFilter.shader` inside a
/// `BackdropFilter` — reads the pixels back, calls the plugin's Swift or
/// Kotlin, and prints its verdict as one `glass_results` line. That covers
/// the package's `pkg_shaders` reaching each platform's bundle at
/// `packages/glass_plugin/`, compiled for that platform's renderer, and a
/// workspace plugin's native code being registered.
///
/// On web, shader image filters are unsupported, so the app checks that it
/// says so; skwasm, CanvasKit in the dev loop and a production CanvasKit
/// (dart2js) build each get a run, and the line names the renderer.
library;

import 'dart:io';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';

/// Runs [target] on [device] and returns the app's verdict, from
/// `glass_results` on.
Future<String> _glassResults({
  required String target,
  required String device,
  List<String> extraArgs = const [],
}) async {
  // The in-tree workspace: these runs read the app's output and change
  // nothing.
  final dt = await startDevTool(
    workspace: e2eWorkspace('plugin_example'),
    target: target,
    device: device,
    extraArgs: extraArgs,
  );
  try {
    await dt.waitForEvent('app.started', timeout: const Duration(minutes: 8));
    final line = await dt.waitForAppLog(
      'glass_results',
      timeout: const Duration(minutes: 2),
    );
    final results = line.substring(line.indexOf('glass_results'));
    // What the app saw, in the run's log whether or not it matches.
    print('e2e: $target on $device: $results');
    return results;
  } finally {
    await dt.sendCommand(1, 'daemon.shutdown');
  }
}

/// Both shaders drew, and [platform]'s native code answered.
Matcher _drewOn(String platform) => matches(
  RegExp(
    '^glass_results paint=PASS filter=PASS '
    'plugin=$platform:(true|false)\$',
  ),
);

/// The paint shader drew, the filter was refused, and the app ran under
/// [renderer].
Matcher _drewOnWeb(String renderer) => matches(
  RegExp(
    // The error's type name, which dart2js minifies.
    r'^glass_results paint=PASS filter=unsupported\([^)]+\) '
    'plugin=none-on-web renderer=$renderer\$',
  ),
);

const _timeout = Timeout(Duration(minutes: 12));

void main() {
  final notMac = !Platform.isMacOS ? 'macOS only' : null;

  test(
    'macOS: package shaders draw as paint and as a backdrop filter',
    () async {
      expect(
        await _glassResults(target: '//glass_app:glass_macos', device: 'macos'),
        _drewOn('macos'),
      );
    },
    skip: notMac,
    timeout: _timeout,
  );

  test(
    'iOS simulator: package shaders draw as paint and as a backdrop filter',
    () async {
      expect(
        await _glassResults(
          target: '//glass_app:glass_ios',
          device: 'ios-simulator',
        ),
        _drewOn('ios'),
      );
    },
    skip: notMac == null ? null : 'macOS only (needs Xcode Simulator)',
    timeout: _timeout,
  );

  // Probed once, and read by both the `skip:` and the body; see
  // plugin_example_e2e_test.dart's Android group for why.
  final android = AndroidDeviceProbe.detect();
  test(
    'Android: package shaders draw, and a workspace plugin is registered',
    () async {
      final probe = android;
      if (probe is! AndroidDeviceFound) {
        fail(
          'Android device detection failed: '
          '${(probe as AndroidProbeFailed).reason}',
        );
      }
      print('e2e: Android device ${probe.serial} (via ${probe.adb})');
      expect(
        await _glassResults(
          target: '//glass_app:glass_android',
          device: 'android:${probe.serial}',
        ),
        _drewOn('android'),
      );
    },
    skip: android.skipReason,
    timeout: _timeout,
  );

  test(
    'web, CanvasKit: the paint shader draws and the filter is refused',
    () async {
      expect(
        await _glassResults(target: '//glass_app:glass_web', device: 'chrome'),
        _drewOnWeb('canvaskit'),
      );
    },
    timeout: _timeout,
  );

  test(
    'web, CanvasKit production build: the paint shader draws and the filter '
    'is refused',
    () async {
      expect(
        await _glassResults(
          target: '//glass_app:glass_web_canvaskit',
          device: 'chrome',
          extraArgs: const ['--profile'],
        ),
        _drewOnWeb('canvaskit'),
      );
    },
    timeout: _timeout,
  );

  test(
    'web, skwasm: the paint shader draws and the filter is refused',
    () async {
      expect(
        await _glassResults(
          target: '//glass_app:glass_web',
          device: 'chrome',
          extraArgs: const ['--wasm'],
        ),
        _drewOnWeb('skwasm'),
      );
    },
    timeout: _timeout,
  );
}
