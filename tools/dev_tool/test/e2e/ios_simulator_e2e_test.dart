@Tags(['e2e'])
import 'dart:io';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';

void main() {
  final workspace = e2eWorkspace('ios_example');

  group('iOS Simulator e2e', () {
    test('HTTP control channel screenshot captures Flutter UI', () async {
      final dt = await startDevTool(
        workspace: workspace,
        target: ':app',
        device: 'ios-simulator',
      );

      try {
        await dt.waitForEvent('app.started');
        final http = await dt.waitForHttpControl();
        expect(http, isNotNull);
        await Future<void>.delayed(const Duration(seconds: 3));

        final outputPath =
            '${Directory.systemTemp.path}/ios_sim_http_e2e.png';
        await dt.httpScreenshotToFile(dt.appId!, outputPath);

        final file = File(outputPath);
        expect(file.existsSync(), isTrue);
        file.deleteSync();

        await dt.sendCommand(1, 'app.stop');
      } finally {
        await dt.dispose();
      }
    });
  }, skip: !Platform.isMacOS ? 'macOS only (needs Xcode Simulator)' : null);
}
