@Tags(['e2e'])
import 'dart:io';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';

void main() {
  final workspace = e2eWorkspace('macos_example');

  group('macOS e2e', () {
    // The macOS embedder enables Impeller by default
    // (`FlutterDartProject.enableImpeller`), and Impeller cannot encode a
    // compressed screenshot, so `_flutter.screenshot` cannot succeed for an
    // app this repo builds. What is asserted is therefore the refusal, not a
    // PNG: a `501` — the status that says a retry cannot help — whose body
    // names the endpoint that does capture this app. Asserting bytes here
    // would pass through `httpScreenshot`'s follow-through to `native` and
    // silently duplicate the test below.
    test(
      'screenshot/flutter refuses under Impeller and names native',
      () async {
        final dt = await startDevTool(
          workspace: workspace,
          target: ':app',
          device: 'macos',
        );

        await dt.waitForEvent('app.started');
        final http = await dt.waitForHttpControl();
        expect(http, isNotNull);

        final reply = await dt.httpFlutterScreenshotReply(dt.appId!);
        expect(reply.statusCode, HttpStatus.notImplemented);
        expect(reply.body, contains('screenshot/native'));

        // Stop the app.
        await dt.sendCommand(1, 'daemon.shutdown');
      },
    );

    test('native screenshot endpoint composites the app\'s windows', () async {
      // Native macOS screenshot shells to a bundled Swift helper resolved
      // from Bazel runfiles, which `dart run` doesn't provide.
      final dt = await startDevTool(
        workspace: workspace,
        target: ':app',
        device: 'macos',
      );

      await dt.waitForEvent('app.started');
      expect(await dt.waitForHttpControl(), isNotNull);

      // The window must be on screen before ScreenCaptureKit can enumerate it
      // via SCShareableContent, and no event reports that — so the endpoint
      // itself is the condition, polled rather than slept past.
      final bytes = await dt.nativeScreenshotWhenOnScreen(dt.appId!);
      expect(bytes.length, greaterThan(0));
      expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);

      await dt.sendCommand(1, 'daemon.shutdown');
    });
  }, skip: !Platform.isMacOS ? 'macOS only' : null);
}
