@Tags(['e2e', 'ios_sim'])
import 'dart:io';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';

/// The app under test.
const _app = E2eApp('ios_example');

void main() {
  final workspace = _app.moduleRoot;

  group(
    'iOS Simulator e2e',
    () {
      test('HTTP control channel screenshot captures Flutter UI', () async {
        final dt = await startDevTool(
          workspace: workspace,
          target: ':app',
          device: 'ios-simulator',
        );

        await dt.waitForEvent('app.started');
        final http = await dt.waitForHttpControl();
        expect(http, isNotNull);
        await Future<void>.delayed(const Duration(seconds: 3));

        final outputPath = '${Directory.systemTemp.path}/ios_sim_http_e2e.png';
        await dt.httpScreenshotToFile(dt.appId!, outputPath);

        final file = File(outputPath);
        expect(file.existsSync(), isTrue);
        final bytes = file.readAsBytesSync();
        file.deleteSync();

        // The capture shows the app, and is of the screen the device says the
        // app is on. A one-screen simulator says nothing of `active`; a Duo
        // names exactly one. Either way the PNG is that screen's size: the
        // other screen of a Duo is the one that captures black, and it has a
        // different size.
        expectRendered(bytes, what: 'the iOS simulator screenshot');
        final screens = await dt.httpScreens(dt.appId!);
        final builtIn = screens.where((s) => s['type'] == 'integrated');
        final expected = builtIn.length == 1
            ? builtIn.single
            : builtIn.singleWhere((s) => s['active'] == true);
        final png = decodePngForBlankness(bytes);
        // Compared as a pair of lengths: the Duo's open posture draws in
        // landscape, so its capture is turned from the size `/screens` gives.
        List<int> sides(Object w, Object h) => [w as int, h as int]..sort();
        expect(
          sides(png.width, png.height),
          sides(expected['width'], expected['height']),
          reason:
              'the screenshot should be of ${expected['name']}, the screen '
              'the app is on; /screens says: $screens',
        );
      });
    },
    skip: !Platform.isMacOS ? 'macOS only (needs Xcode Simulator)' : null,
  );
}
