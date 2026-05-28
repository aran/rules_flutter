@Tags(['e2e'])
import 'dart:io';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';

void main() {
  final workspace = e2eWorkspace('web_example');

  group('Web/Chrome e2e', () {
    test('WASM screenshot via HTTP control channel', () async {
      final dt = await startDevTool(
        workspace: workspace,
        target: ':app_wasm',
        device: 'chrome',
      );

      try {
        await dt.waitForEvent('app.started');
        final http = await dt.waitForHttpControl();
        expect(http, isNotNull);
        await Future<void>.delayed(const Duration(seconds: 5));

        final outputPath =
            '${Directory.systemTemp.path}/web_wasm_e2e.png';
        await dt.httpScreenshotToFile(dt.appId!, outputPath);

        final file = File(outputPath);
        expect(file.existsSync(), isTrue);
        final bytes = file.readAsBytesSync();
        expect(bytes.length, greaterThan(100));
        expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
        file.deleteSync();

        await dt.sendCommand(1, 'app.stop');
      } finally {
        await dt.dispose();
      }
    });

    test('JS screenshot via HTTP control channel', () async {
      final dt = await startDevTool(
        workspace: workspace,
        target: ':app_js',
        device: 'chrome',
      );

      try {
        await dt.waitForEvent('app.started');
        final http = await dt.waitForHttpControl();
        expect(http, isNotNull);
        await Future<void>.delayed(const Duration(seconds: 5));

        final outputPath =
            '${Directory.systemTemp.path}/web_js_e2e.png';
        await dt.httpScreenshotToFile(dt.appId!, outputPath);

        final file = File(outputPath);
        expect(file.existsSync(), isTrue);
        final bytes = file.readAsBytesSync();
        expect(bytes.length, greaterThan(100));
        expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
        file.deleteSync();

        await dt.sendCommand(1, 'app.stop');
      } finally {
        await dt.dispose();
      }
    });
  });
}
