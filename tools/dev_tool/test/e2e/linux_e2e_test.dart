@Tags(['e2e', 'linux'])
/// A Linux app run under the dev tool: a hot reload and a hot restart land in
/// the window, and the native screenshot reads the X display.
///
/// The Linux capture is the dev tool's own X11 client (no `scrot`), so a test
/// that takes a picture proves the protocol path against a real server. The
/// run needs a display: on a machine with none, start Xvfb and export
/// `DISPLAY` and `LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe` first.
library;

import 'dart:io';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';
import 'editable_workspace.dart';

/// The app under test.
const _app = E2eApp('desktop_example');

const _greeting = 'Hello from rules_flutter!';

void main() {
  group('linux app', () {
    test(
      'a hot reload and a hot restart land in the window',
      () async {
        final ws = await editableWorkspace(_app);
        final main = ws.file('lib/main.dart');
        final original = main.readAsStringSync();
        expect(original, contains(_greeting), reason: 'fixture marker');

        final dt = await startDevTool(
          workspace: ws.root,
          target: ':linux_app',
          device: 'linux',
        );
        await dt.waitForEvent(
          'app.started',
          timeout: const Duration(minutes: 6),
        );
        final appId = dt.appId!;
        await dt.waitForHttpControl();
        await dt.waitForStderr('frontend_server_ready');

        final first = await dt.httpCommand('app.waitFor', {
          'appId': appId,
          'text': _greeting,
          'timeoutMs': '30000',
        });
        expect(first['error'], isNull, reason: 'the app should render: $first');
        final before = await dt.httpNativeScreenshot(appId);
        expect(before.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);

        // Hot reload.
        main.writeAsStringSync(
          original.replaceFirst(_greeting, '$_greeting reloaded'),
        );
        final reload = await dt.httpCommand('app.hotReload', {'appId': appId});
        final reloaded = reload['result'] as Map<String, dynamic>?;
        expect(reloaded, isNotNull, reason: 'app.hotReload: $reload');
        expect(reloaded!['succeeded'], isTrue, reason: '$reloaded');
        final afterReload = await dt.httpCommand('app.waitFor', {
          'appId': appId,
          'text': '$_greeting reloaded',
          'timeoutMs': '30000',
        });
        expect(afterReload['error'], isNull, reason: '$afterReload');
        final reloadedShot = await dt.httpNativeScreenshot(appId);
        expect(
          reloadedShot,
          isNot(before),
          reason: 'the window should show the edit',
        );

        // Hot restart.
        main.writeAsStringSync(
          original.replaceFirst(_greeting, '$_greeting restarted'),
        );
        final restart = await dt.httpCommand('app.restart', {
          'appId': appId,
          'fullRestart': true,
        });
        final restarted = restart['result'] as Map<String, dynamic>?;
        expect(restarted, isNotNull, reason: 'app.restart: $restart');
        expect(restarted!['succeeded'], isTrue, reason: '$restarted');
        final afterRestart = await dt.httpCommand('app.waitFor', {
          'appId': appId,
          'text': '$_greeting restarted',
          'timeoutMs': '30000',
        });
        expect(afterRestart['error'], isNull, reason: '$afterRestart');
        final restartedShot = await dt.httpNativeScreenshot(appId);
        expect(restartedShot, isNot(reloadedShot));

        await dt.sendCommand(1, 'daemon.shutdown');
      },
      timeout: const Timeout(Duration(minutes: 8)),
    );
  }, skip: !Platform.isLinux ? 'Linux only' : null);
}
