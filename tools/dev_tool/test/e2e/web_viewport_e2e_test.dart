@Tags(['e2e', 'web'])
/// `--web-viewport` against a real Chrome: the capture has the size asked for,
/// keeps it across a hot restart, and `app.setViewport` changes it.
///
/// The override is tied to the CDP connection that set it (Chrome 154 clears it
/// when the socket closes), so a run that applied it and let the connection go
/// still reported a clean launch while every capture came back at the
/// browser's own 2400x1713. Only a capture from a live run says which.
library;

import 'dart:io';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';

/// The app under test.
const _app = E2eApp('web_example');

({int width, int height}) _pngSize(List<int> b) {
  int u32(int o) =>
      (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
  return (width: u32(16), height: u32(20));
}

void main() {
  group('web viewport e2e', () {
    Future<DevToolProcess> launch(String viewport) async {
      final dt = await startDevTool(
        workspace: _app.moduleRoot,
        // The DDC dev loop: the shape a developer's own run takes.
        target: ':app_wasm',
        device: 'chrome',
        extraArgs: ['--web-run-headless', '--web-viewport=$viewport'],
      );
      addTearDown(() => dt.sendCommand(99, 'daemon.shutdown'));
      await dt.waitForEvent('app.started');
      await dt.waitForHttpControl();
      await dt.nativeScreenshotWhenOnScreen(dt.appId!);
      return dt;
    }

    Future<({int width, int height})> capture(
      DevToolProcess dt,
      String name,
    ) async {
      final path = '${Directory.systemTemp.path}/web_viewport_e2e_$name.png';
      await dt.httpScreenshotToFile(dt.appId!, path);
      final file = File(path);
      addTearDown(() => file.existsSync() ? file.deleteSync() : null);
      return _pngSize(file.readAsBytesSync());
    }

    test(
      'a viewport with a scale captures at that size, through a restart and '
      'a resize',
      () async {
        final dt = await launch('390x844@3');
        expect(
          await capture(dt, 'scaled'),
          (width: 1170, height: 2532),
          reason: '390x844 at 3x',
        );

        final restart = await dt.sendCommand(
          7,
          'app.restart',
          params: {'appId': dt.appId, 'fullRestart': true},
        );
        expect(restart['error'], isNull, reason: 'app.restart: $restart');
        await dt.nativeScreenshotWhenOnScreen(dt.appId!);
        expect(
          await capture(dt, 'restarted'),
          (width: 1170, height: 2532),
          reason: 'the viewport survives the page reload a restart performs',
        );

        // Whole numbers, which the HTTP channel's string parameters are not.
        final resized = await dt.sendCommand(
          8,
          'app.setViewport',
          params: {'appId': dt.appId, 'width': 300, 'height': 500},
        );
        expect(resized['error'], isNull, reason: 'setViewport: $resized');
        await dt.nativeScreenshotWhenOnScreen(dt.appId!);
        expect(
          await capture(dt, 'resized'),
          (width: 900, height: 1500),
          reason: '300x500 at the run\'s 3x',
        );
      },
      timeout: const Timeout(Duration(minutes: 12)),
    );

    test(
      'a viewport without a scale captures at exactly that size',
      () async {
        final dt = await launch('390x844');
        expect(await capture(dt, 'plain'), (width: 390, height: 844));
      },
      timeout: const Timeout(Duration(minutes: 12)),
    );
  });
}
