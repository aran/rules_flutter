/// An app whose `main` sits outside its package's `lib/` hot reloads and hot
/// restarts like any other.
///
/// `flutter run -t test_driver/app.dart` accepts such a `main`; so does
/// `flutter_bazel run`. It has no `package:` URI, so the build and the dev loop
/// both name it `org-dartlang-app:///test_driver/app.dart`, and the build
/// declares it — with the sibling it imports, from `srcs` — as the app's
/// sources outside every package. What this guards is the failure that shape
/// used to have: the app ran, and every edit to it was dropped, with each
/// reload answering "no changes detected" and each restart recompiling
/// nothing. On web it was refused outright in a debug build.
///
/// Both fixtures render one label from each file, so each edit is asserted by
/// the exact text it produces, through `app.waitFor`.
@Tags(['e2e'])
library;

import 'dart:io';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';
import 'editable_workspace.dart';

void main() {
  /// Start [target] in a copy of [workspace] on [device], edit both files
  /// outside `lib/` with a reload after each, then edit again and restart.
  Future<void> reloadsAndRestarts({
    required String workspace,
    required String target,
    required String device,
  }) async {
    final ws = await editableWorkspace(workspace);
    final app = ws.file('test_driver/app.dart');
    final banner = ws.file('test_driver/banner.dart');

    /// Replace [from] with [to] in [file], and prove the file changed: an
    /// anchor that matches nothing would leave every assertion below holding
    /// against a tree nobody edited.
    void rewrite(File file, String from, String to) {
      final before = file.readAsStringSync();
      final after = before.replaceFirst(from, to);
      if (after == before) {
        fail('the edit anchor "$from" matched nothing in ${file.path}');
      }
      file.writeAsStringSync(after);
    }

    final dt = await startDevTool(
      workspace: ws.root,
      target: target,
      device: device,
    );
    final start = await dt.waitForEvent(
      'app.start',
      timeout: const Duration(seconds: 300),
    );
    final appId = start['params']?['appId'] as String? ?? dt.appId!;
    await dt.waitForHttpControl(timeout: const Duration(seconds: 120));

    Future<void> shows(String text, {required String after}) async {
      final found = await dt.httpCommand('app.waitFor', {
        'appId': appId,
        'text': text,
        'timeoutMs': '60000',
      });
      expect(found['error'], isNull, reason: '"$text" after $after');
    }

    await shows('driver entrypoint v1', after: 'launch');
    await shows('driver banner v1', after: 'launch');

    Future<void> reload(String what) async {
      final reply = await dt.sendCommand(
        1,
        'app.hotReload',
        params: {'appId': appId},
        timeout: const Duration(minutes: 2),
      );
      expect(
        reply['result']?['runningCode'],
        'updated',
        reason:
            'a reload after editing $what must change the running code, '
            'not report "no changes": ${reply['result'] ?? reply['error']}',
      );
    }

    rewrite(app, 'driver entrypoint v1', 'driver entrypoint v2');
    await reload('the main outside lib/');
    await shows('driver entrypoint v2', after: 'reloading an edited main');

    rewrite(banner, 'driver banner v1', 'driver banner v2');
    await reload('a sibling of the main');
    await shows('driver banner v2', after: 'reloading an edited sibling');

    rewrite(app, 'driver entrypoint v2', 'driver entrypoint v3');
    final restart = await dt.sendCommand(
      2,
      'app.restart',
      params: {'appId': appId},
      timeout: const Duration(minutes: 4),
    );
    expect(
      restart['result']?['succeeded'],
      isTrue,
      reason: 'app.restart: ${restart['result'] ?? restart['error']}',
    );
    await shows('driver entrypoint v3', after: 'restarting');
    await shows('driver banner v2', after: 'restarting');

    await dt.sendCommand(3, 'daemon.shutdown');
  }

  group('main outside lib/', () {
    test(
      'macOS: edits to it and its sibling reload and restart',
      () => reloadsAndRestarts(
        workspace: 'macos_example',
        target: ':driver_app',
        device: 'macos',
      ),
      skip: !Platform.isMacOS ? 'macOS only' : null,
      timeout: const Timeout(Duration(minutes: 10)),
    );

    test(
      'Chrome: edits to it and its sibling reload and restart',
      () => reloadsAndRestarts(
        workspace: 'web_example',
        target: ':app_test_driver',
        device: 'chrome',
      ),
      timeout: const Timeout(Duration(minutes: 10)),
    );
  });
}
