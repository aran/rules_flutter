@Tags(['e2e'])
library;

import 'dart:io';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';

/// End-to-end: `flutter_bazel run --dart-define` reaches the app AND
/// survives a hot reload.
///
/// The macos_example UI renders `String.fromEnvironment('E2E_MESSAGE')` in a
/// keyed Text. The define value deliberately contains a comma — the
/// repeatable extra_dart_defines build setting must not split it. After the
/// initial assertion, the test edits main.dart and hot reloads: the
/// recompiled library must still see the define (the dev tool replays the
/// dev config's dartDefines as -D on its resident frontend_server; before
/// that fix the reloaded text would render an empty define).
void main() {
  group('dart-define e2e', () {
    test('--dart-define renders and survives hot reload', () async {
      final ws = e2eWorkspace('macos_example');
      final appMain = File('$ws/lib/main.dart');
      final appMainOrig = appMain.readAsStringSync();
      expect(appMainOrig, contains(" v1'"),
          reason: 'fixture marker present in macos_example main.dart');

      final dt = await startDevTool(
        workspace: ws,
        target: ':app',
        device: 'macos',
        extraArgs: ['--dart-define', 'E2E_MESSAGE=defines,live'],
      );
      addTearDown(() async {
        appMain.writeAsStringSync(appMainOrig);
        await dt.dispose();
      });

      final start = await dt.waitForEvent('app.start',
          timeout: const Duration(seconds: 240));
      final appId = start['params']?['appId'] as String? ?? dt.appId!;
      await dt.waitForHttpControl(timeout: const Duration(seconds: 60));

      final ready = await dt.httpCommand('app.waitFor', {
        'appId': appId,
        'key': 'e2e_define_label',
        'timeoutMs': '15000',
      });
      expect(ready['error'], isNull,
          reason: 'e2e_define_label: ${ready['error']}');

      // Initial build: define flows bazel flag → kernel -D → runtime.
      var label = await dt.httpCommand('app.getText', {
        'appId': appId,
        'key': 'e2e_define_label',
      });
      expect(label['error'], isNull,
          reason: 'app.getText: ${label['error']}');
      expect(label['result']?['text'], 'defines,live v1',
          reason: 'initial build must carry the --dart-define, comma intact');

      // Hot reload with an edited source: the recompiled library must keep
      // the define. 'v2' proves the reload actually applied; the prefix
      // proves the frontend_server compiled with -DE2E_MESSAGE=defines,live.
      appMain.writeAsStringSync(appMainOrig.replaceFirst(" v1'", " v2'"));
      final reload =
          await dt.sendCommand(1, 'app.hotReload', {'appId': appId});
      expect(reload['error'], isNull,
          reason: 'app.hotReload: ${reload['error']}');

      label = await dt.httpCommand('app.getText', {
        'appId': appId,
        'key': 'e2e_define_label',
      });
      expect(label['error'], isNull,
          reason: 'app.getText after reload: ${label['error']}');
      expect(label['result']?['text'], 'defines,live v2',
          reason: 'hot reload must apply the edit AND keep the dart-define');
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
