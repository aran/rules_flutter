@Tags(['e2e'])
import 'dart:io';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';

void main() {
  final workspace = e2eWorkspace('macos_example');

  group('macOS e2e', () {
    test('HTTP control channel screenshot captures Flutter UI', () async {
      final dt = await startDevTool(
        workspace: workspace,
        target: ':app',
        device: 'macos',
      );

      try {
        await dt.waitForEvent('app.started');
        final http = await dt.waitForHttpControl();
        expect(http, isNotNull);

        // Wait for first frame.
        await Future<void>.delayed(const Duration(seconds: 3));

        // Take screenshot via HTTP endpoint.
        final outputPath =
            '${Directory.systemTemp.path}/macos_e2e_http.png';
        await dt.httpScreenshotToFile(dt.appId!, outputPath);

        final file = File(outputPath);
        expect(file.existsSync(), isTrue);
        final bytes = file.readAsBytesSync();
        expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
        file.deleteSync();

        // Stop the app.
        await dt.sendCommand(1, 'app.stop');
      } finally {
        await dt.dispose();
      }
    });

    test('native screenshot endpoint composites the app\'s windows', () async {
      // Native macOS screenshot shells to a bundled Swift helper resolved
      // from Bazel runfiles, which `dart run` doesn't provide.
      final dt = await startDevTool(
        workspace: workspace,
        target: ':app',
        device: 'macos',
        useBazelBuiltBinary: true,
      );

      try {
        await dt.waitForEvent('app.started');
        expect(await dt.waitForHttpControl(), isNotNull);

        // Window must be visible on screen before ScreenCaptureKit can
        // enumerate it via SCShareableContent.
        await Future<void>.delayed(const Duration(seconds: 3));

        final bytes = await dt.httpNativeScreenshot(dt.appId!);
        expect(bytes.length, greaterThan(0));
        expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);

        await dt.sendCommand(1, 'app.stop');
      } finally {
        await dt.dispose();
      }
    });
  }, skip: !Platform.isMacOS ? 'macOS only' : null);
}
