@Tags(['e2e'])

/// End-to-end screenshot tests for `e2e/plugin_example`.
///
/// Validates that the demonstrator app launches and renders a non-blank
/// frame across every platform `rules_flutter` supports. The screenshot is
/// the dispositive end-to-end gate: if plugin auto-wiring is broken,
/// `MissingPluginException` blanks the screen; if Native Assets are
/// broken, the app crashes before drawing anything — both fail the
/// non-blank check.
///
/// macOS / iOS-Simulator / Android subtests share the same dev_tool
/// screenshot pipeline (`Device.screenshot` → HTTP control channel →
/// captured PNG). Each runs `:plugin_app` on a different platform; the
/// non-blank PNG is dispositive evidence that the build pipeline
/// produced a working app for that platform.
library;

import 'dart:io';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';

/// PNG signature: 89 50 4E 47 0D 0A 1A 0A.
const _pngHeader = <int>[0x89, 0x50, 0x4E, 0x47];

/// Minimum reasonable size for a non-blank Flutter screenshot. A blank /
/// solid-color PNG of typical phone-screen dimensions compresses to a
/// few hundred bytes; a real Flutter UI with text + widgets is at least
/// tens of KB. 4KB is comfortably above the blank threshold and well
/// below any real-app rendering.
const _minNonBlankBytes = 4 * 1024;

/// Common screenshot assertion: launch [target] on [device], wait one
/// frame, capture via the HTTP control channel, and assert the PNG is
/// well-formed and non-blank. Keeping this in a helper means the
/// per-platform subtests differ only in `device`/`target`/skip
/// predicate. Each platform points the dev_tool at its launchable
/// bundle target (`:plugin_macos`, `:plugin_ios`, `:plugin_android`),
/// not the underlying `:plugin_app` flutter_application — the dev_tool
/// resolves the first build output and expects a runnable artifact.
Future<void> _runScreenshotTest({
  required String workspace,
  required String target,
  required String device,
  required String outputBasename,
}) async {
  final dt = await startDevTool(
    workspace: workspace,
    target: target,
    device: device,
  );

  try {
    await dt.waitForEvent('app.started');
    final http = await dt.waitForHttpControl();
    expect(http, isNotNull);

    // Wait for first frame.
    await Future<void>.delayed(const Duration(seconds: 3));

    final outputPath = '${Directory.systemTemp.path}/$outputBasename.png';
    await dt.httpScreenshotToFile(dt.appId!, outputPath);

    final file = File(outputPath);
    expect(
      file.existsSync(),
      isTrue,
      reason: 'screenshot file should exist at $outputPath',
    );

    final bytes = file.readAsBytesSync();
    expect(
      bytes.length,
      greaterThanOrEqualTo(_minNonBlankBytes),
      reason: 'screenshot looks blank '
          '(${bytes.length} bytes < $_minNonBlankBytes); '
          'plugin auto-wiring or Native Assets likely failed',
    );
    expect(
      bytes.sublist(0, 4),
      _pngHeader,
      reason: 'screenshot is not a valid PNG',
    );

    file.deleteSync();
    await dt.sendCommand(1, 'app.stop');
  } finally {
    await dt.dispose();
  }
}

void main() {
  final workspace = e2eWorkspace('plugin_example');

  // -- macOS ------------------------------------------------------------
  //
  // Validates Track A's Native Assets pipeline end-to-end: modern
  // path_provider_foundation 2.6.0+ FFI through objective_c.dylib has
  // to actually resolve at runtime for the screen to render.
  group(
    'macOS e2e',
    () {
      test('plugin_macos renders non-blank frame', () async {
        await _runScreenshotTest(
          workspace: workspace,
          target: ':plugin_macos',
          device: 'macos',
          outputBasename: 'plugin_macos_e2e',
        );
      });

      test('Dart plugin registration survives hot restart', () async {
        // Regression: the Dart plugin registrant is invoked by the engine's
        // pre-main hook on every root-isolate launch, including the restarted
        // (dev-tool-compiled) dill. Previously it ran only from a build-
        // generated wrapper main the restart dill lacked, so platform-
        // interface statics reset on restart and path_provider (et al.)
        // broke. The keyed Text renders getApplicationDocumentsDirectory():
        // a real absolute path means the Dart registration worked.
        final dt = await startDevTool(
          workspace: workspace,
          target: ':plugin_macos',
          device: 'macos',
        );
        try {
          await dt.waitForEvent('app.started');
          await dt.waitForHttpControl();
          final appId = dt.appId!;

          Future<String> documentsPath(String tag) async {
            Map<String, dynamic> resp = const {};
            for (var i = 0; i < 30; i++) {
              resp = await dt.httpCommand('app.getText', {
                'appId': appId,
                'key': 'e2e_documents_path',
              });
              // Retry both extension availability and the async
              // FutureBuilder resolving the plugin results.
              final text = resp['result']?['text'] as String? ?? '';
              if (resp['error'] == null && text.startsWith('/')) return text;
              await Future<void>.delayed(const Duration(milliseconds: 500));
            }
            fail('documentsPath never resolved $tag: '
                'error=${resp['error']} text=${resp['result']?['text']}');
          }

          final before = await documentsPath('at launch');
          expect(before, startsWith('/'),
              reason: 'path_provider must resolve at launch');

          final restart = await dt.sendCommand(9, 'app.restart', {
            'appId': appId,
          });
          expect(restart['error'], isNull,
              reason: 'app.restart: ${restart['error']}');

          final after = await documentsPath('after restart');
          expect(after, before,
              reason: 'path_provider must still resolve after hot restart '
                  '(Dart registrant must re-run)');
        } finally {
          await dt.dispose();
        }
      }, timeout: const Timeout(Duration(minutes: 4)));
    },
    skip: !Platform.isMacOS ? 'macOS only' : null,
  );

  // -- iOS Simulator ----------------------------------------------------
  //
  // Validates the iOS Apple Native Assets path (different bundle slot,
  // different code-sign target). Requires Xcode with the simulator
  // runtime; test harness boots/uses whatever simulator the dev_tool
  // selects.
  group(
    'iOS Simulator e2e',
    () {
      test('plugin_ios renders non-blank frame', () async {
        await _runScreenshotTest(
          workspace: workspace,
          target: ':plugin_ios',
          device: 'ios-simulator',
          outputBasename: 'plugin_ios_sim_e2e',
        );
      });
    },
    skip: !Platform.isMacOS ? 'macOS only (needs Xcode Simulator)' : null,
  );

  // -- Android ----------------------------------------------------------
  //
  // Operates against whatever `adb devices` exposes — emulator or
  // USB-authorized physical device, whichever the user brought up. The
  // test does not start or stop emulators (mirrors how Bazel Android
  // instrumentation tests behave).
  group(
    'Android e2e',
    () {
      test(
        'plugin_android renders non-blank frame',
        () async {
          // dev_tool's -d flag takes an Android serial, not a generic
          // 'android' token. Honor $ANDROID_SERIAL if set (lets the user
          // pick emulator vs connected device when both are attached);
          // otherwise pick the first `device`-state entry from `adb
          // devices`.
          final serial =
              Platform.environment['ANDROID_SERIAL'] ?? firstAndroidSerial();
          expect(
            serial,
            isNotNull,
            reason: 'no Android device authorized; check `adb devices`',
          );
          await _runScreenshotTest(
            workspace: workspace,
            target: ':plugin_android',
            device: serial!,
            outputBasename: 'plugin_android_e2e',
          );
        },
        skip: 'Pristine flutter-create debug APKs lack '
            'android.permission.INTERNET (flutter_android_app does not merge '
            'the debug variant manifest), so the Dart VM service cannot bind '
            'and the app cannot be driven; tracked as '
            'android-debug-vm-service-gap. The fail-fast diagnostic for this '
            'state is asserted by the test below.',
      );

      test('plugin_android debug launch fails fast without INTERNET', () async {
        // plugin_example keeps its flutter-create manifests pristine:
        // android.permission.INTERNET lives only in the debug/profile
        // variant manifests, which flutter_android_app does not merge.
        // Android's kernel-level INTERNET enforcement (AID_INET group)
        // blocks even the loopback bind the Dart VM service needs, so a
        // debug launch can never produce app.started. The observable
        // contract until variant-manifest merging lands is the dev tool's
        // immediate diagnostic instead of a silent multi-minute timeout.
        final serial =
            Platform.environment['ANDROID_SERIAL'] ?? firstAndroidSerial();
        expect(
          serial,
          isNotNull,
          reason: 'no Android device authorized; check `adb devices`',
        );
        final dt = await startDevTool(
          workspace: workspace,
          target: ':plugin_android',
          device: serial!,
        );
        try {
          final exitCode = await dt.process.exitCode
              .timeout(const Duration(minutes: 5));
          final stderrText = dt.stderrLines.join('\n');
          expect(exitCode, isNot(0),
              reason: 'dev tool should abort the launch; stderr:\n$stderrText');
          expect(stderrText, contains('android.permission.INTERNET'));
          expect(stderrText, contains('Dart VM service'));
          expect(stderrText,
              contains('android/app/src/debug/AndroidManifest.xml'));
          expect(
            dt.events.any((e) => e['event'] == 'app.started'),
            isFalse,
            reason: 'app must not be reported started when the preflight '
                'fails',
          );
        } finally {
          await dt.dispose();
        }
      });
    },
    skip: !hasAndroidDevice()
        ? 'no Android device authorized (run `adb devices` to confirm)'
        : null,
  );
}
