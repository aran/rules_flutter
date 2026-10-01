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
import 'editable_workspace.dart';

/// Runs [target] on [device] and returns the app's verdict, from [tag] on.
Future<String> _glassResults({
  required String target,
  required String device,
  List<String> extraArgs = const [],
  String tag = 'glass_results',
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
      tag,
      timeout: const Duration(minutes: 2),
    );
    final results = line.substring(line.indexOf(tag));
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

  // `//impeller_shader` draws with a shader SkSL cannot compile, which the
  // build keeps for Impeller alone, as `flutter build` does.
  for (final (platform, target, device) in [
    ('macOS', '//impeller_shader:app_macos', 'macos'),
    ('iOS simulator', '//impeller_shader:app_ios', 'ios-simulator'),
  ]) {
    test(
      '$platform: a shader SkSL cannot compile still draws under Impeller',
      () async {
        expect(
          await _glassResults(
            target: target,
            device: device,
            tag: 'impeller_shader_results',
          ),
          'impeller_shader_results paint=PASS',
        );
      },
      skip: notMac,
      timeout: _timeout,
    );
  }

  // Shader hot reload: an edit to a package shader reaches the running app
  // on a hot reload, as under `flutter run` — the tool rebuilds the shader,
  // uploads it, and has the engine reinitialize the program. The app prints
  // the colour it paints after every reassemble.
  for (final (platform, target, device) in [
    ('macOS', '//glass_app:glass_macos', 'macos'),
    ('iOS simulator', '//glass_app:glass_ios', 'ios-simulator'),
  ]) {
    test(
      '$platform: an edited shader draws after a hot reload',
      () async {
        final ws = await editableWorkspace('plugin_example');
        final shader = ws.file('glass_plugin/shaders/tint.frag');
        final source = shader.readAsStringSync();
        expect(source, contains('fragColor = uColor;'));
        final dt = await startDevTool(
          workspace: ws.root,
          target: target,
          device: device,
        );
        try {
          await dt.waitForEvent(
            'app.started',
            timeout: const Duration(minutes: 8),
          );
          await dt.waitForAppLog(
            'glass_results',
            timeout: const Duration(minutes: 2),
          );

          shader.writeAsStringSync(
            source.replaceFirst(
              'fragColor = uColor;',
              'fragColor = vec4(0.0, 1.0, 0.0, 1.0);',
            ),
          );
          final reload = await dt.sendCommand(
            1,
            'app.hotReload',
            params: {'appId': dt.appId},
          );
          expect(reload['error'], isNull, reason: '$reload');
          expect(
            reload['result']?['assetPaths'],
            contains('packages/glass_plugin/shaders/tint.frag'),
            reason: 'the reload must deliver the rebuilt shader: $reload',
          );
          // Green, where the app launched painting magenta.
          await dt.waitForAppLog(
            'glass_paint_color 0xff00ff00',
            timeout: const Duration(minutes: 1),
          );
        } finally {
          await dt.sendCommand(2, 'daemon.shutdown');
        }
      },
      skip: notMac,
      timeout: _timeout,
    );
  }

  // Probed once, and read by both the `skip:` and the body; see
  // plugin_example_e2e_test.dart's Android group for why.
  final android = AndroidDeviceProbe.detect();
  test(
    'Android: a shader SkSL cannot compile still draws under Impeller',
    () async {
      final probe = android;
      if (probe is! AndroidDeviceFound) {
        fail(
          'Android device detection failed: '
          '${(probe as AndroidProbeFailed).reason}',
        );
      }
      expect(
        await _glassResults(
          target: '//impeller_shader:app_android',
          device: 'android:${probe.serial}',
          tag: 'impeller_shader_results',
        ),
        'impeller_shader_results paint=PASS',
      );
    },
    skip: android.skipReason,
    timeout: _timeout,
  );

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
