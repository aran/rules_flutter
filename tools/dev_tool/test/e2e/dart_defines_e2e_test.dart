@Tags(['e2e', 'macos'])
library;

import 'dart:io';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';
import 'editable_workspace.dart';

/// End-to-end: `flutter_bazel run --dart-define` reaches the app AND
/// survives a hot reload.
///
/// The macos_example UI renders `String.fromEnvironment('E2E_MESSAGE')` in a
/// keyed Text. The define value deliberately contains a comma — the
/// repeatable extra_dart_defines build setting must not split it. After the
/// initial assertion, the test edits main.dart and hot reloads: the
/// recompiled library must still see the define (the dev tool replays the
/// dev config's dartDefines as -D on its resident frontend_server; without
/// that the reloaded text renders an empty define).
void main() {
  // [extraArgs] are the flags that carry the define; [message] is the value
  // they put in `E2E_MESSAGE`.
  Future<void> rendersAndSurvivesReload(
    List<String> extraArgs,
    String message,
  ) async {
    final ws = await editableWorkspace('macos_example');
    final appMain = ws.file('lib/main.dart');
    final appMainOrig = appMain.readAsStringSync();
    expect(
      appMainOrig,
      contains(" v1'"),
      reason: 'fixture marker present in macos_example main.dart',
    );

    final dt = await startDevTool(
      workspace: ws.root,
      target: ':app',
      device: 'macos',
      extraArgs: extraArgs,
    );
    final start = await dt.waitForEvent(
      'app.start',
      timeout: const Duration(seconds: 240),
    );
    final appId = start['params']?['appId'] as String? ?? dt.appId!;
    await dt.waitForHttpControl(timeout: const Duration(seconds: 60));

    final ready = await dt.httpCommand('app.waitFor', {
      'appId': appId,
      'key': 'e2e_define_label',
      'timeoutMs': '15000',
    });
    expect(
      ready['error'],
      isNull,
      reason: 'e2e_define_label: ${ready['error']}',
    );

    // Initial build: define flows bazel flag → kernel -D → runtime.
    var label = await dt.httpCommand('app.getText', {
      'appId': appId,
      'key': 'e2e_define_label',
    });
    expect(
      label['error'],
      isNull,
      reason: 'app.getText: ${label['error']}',
    );
    expect(
      label['result']?['text'],
      '$message v1',
      reason: 'initial build must carry the --dart-define, comma intact',
    );

    // Hot reload with an edited source: the recompiled library must keep
    // the define. 'v2' proves the reload actually applied; the prefix
    // proves the frontend_server compiled with -DE2E_MESSAGE=defines,live.
    appMain.writeAsStringSync(appMainOrig.replaceFirst(" v1'", " v2'"));
    final reload = await dt.sendCommand(
      1,
      'app.hotReload',
      params: {'appId': appId},
    );
    expect(
      reload['error'],
      isNull,
      reason: 'app.hotReload: ${reload['error']}',
    );
    expect(
      reload['result']?['runningCode'],
      'updated',
      reason: 'app.hotReload must change the running code: ${reload['result']}',
    );

    label = await dt.httpCommand('app.getText', {
      'appId': appId,
      'key': 'e2e_define_label',
    });
    expect(
      label['error'],
      isNull,
      reason: 'app.getText after reload: ${label['error']}',
    );
    expect(
      label['result']?['text'],
      '$message v2',
      reason: 'hot reload must apply the edit AND keep the dart-define',
    );

    // A restart rebuilds with the run's flags too; a v3 edit that renders with
    // the same prefix shows the restart saw the same configuration.
    appMain.writeAsStringSync(appMainOrig.replaceFirst(" v1'", " v3'"));
    final restart = await dt.httpCommand('app.restart', {
      'appId': appId,
      'fullRestart': true,
    });
    expect(
      restart['error'],
      isNull,
      reason: 'app.restart: ${restart['error']}',
    );
    label = await dt.httpCommand('app.getText', {
      'appId': appId,
      'key': 'e2e_define_label',
    });
    expect(
      label['error'],
      isNull,
      reason: 'app.getText after restart: ${label['error']}',
    );
    expect(
      label['result']?['text'],
      '$message v3',
      reason: 'hot restart must apply the edit AND keep the dart-define',
    );
  }

  group('dart-define e2e', () {
    test(
      '--dart-define renders and survives hot reload',
      () => rendersAndSurvivesReload([
        '--dart-define',
        'E2E_MESSAGE=defines,live',
      ], 'defines,live'),
      timeout: const Timeout(Duration(minutes: 5)),
      skip: !Platform.isMacOS ? 'macOS only' : null,
    );

    // The define comes from `build:e2e_define` in the workspace's .bazelrc,
    // so it reaches the app only if `--config` reaches the launch build.
    test(
      '--config reaches the build and survives hot reload',
      () => rendersAndSurvivesReload([
        '--config',
        'e2e_define',
      ], 'from,config'),
      timeout: const Timeout(Duration(minutes: 5)),
      skip: !Platform.isMacOS ? 'macOS only' : null,
    );
  });
}
