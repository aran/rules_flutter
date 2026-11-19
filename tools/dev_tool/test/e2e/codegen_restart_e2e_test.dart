@Tags(['e2e', 'ios_sim'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';
import 'editable_workspace.dart';

/// The apps under test.
const _codegen = E2eApp('codegen');
const _iosExample = E2eApp('ios_example');

/// A field inserted into a const class whose generated `part` a build-time
/// generator writes, the way freezed and json_serializable do, then
/// `app.restart`.
///
/// `app.restart` without `fullRestart: true` is a hot reload, as in
/// `flutter run`'s protocol, and the VM cannot reload this edit: the class
/// has a const instance, and a new field ahead of an old one moves the old
/// one, which the VM treats as removing it. The reload has to say so, in the
/// VM's words and with the restart that carries it; a bare "the VM rejected
/// the new kernel" leaves the user guessing at stale generated code. The
/// restart it names then runs the new field.
///
/// The class lives in a dependency package of the main repository, `dep_part`,
/// so both commands also regenerate that package's `part` first.
///
/// On the iOS simulator rather than macOS: the codegen workspace's only app is
/// a macOS one, so the test gives it an iOS runner, `flutter create`'s, taken
/// from `ios_example`.
void main() {
  test(
    'a field a reload cannot carry is refused with the reason, and a restart runs it',
    () async {
      final ws = await editableWorkspace(_codegen);
      _copyTree(
        Directory(p.join(_iosExample.root, 'ios', 'Runner')),
        ws.dir('ios/Runner'),
      );
      final build = ws.file('BUILD.bazel');
      build.writeAsStringSync(
        'load("@rules_flutter//flutter:ios.bzl", "flutter_ios_app")\n'
        '${build.readAsStringSync()}\n'
        'flutter_ios_app(\n'
        '    name = "app_ios",\n'
        '    application = ":app",\n'
        '    bundle_id = "com.rulesflutter.codegen.example",\n'
        ')\n',
      );

      final dt = await startDevTool(
        workspace: ws.root,
        target: ':app_ios',
        device: 'ios-simulator',
      );
      final start = await dt.waitForEvent(
        'app.start',
        // A cold output base builds the whole app.
        timeout: const Duration(minutes: 15),
      );
      final appId = start['params']?['appId'] as String? ?? dt.appId!;
      await dt.waitForHttpControl(timeout: const Duration(seconds: 60));
      // An edit inside the assembler's own build window is compiled into its
      // baseline, so nothing is edited before the pipeline is up.
      await dt.waitForStderr(
        'frontend_server_ready',
        timeout: const Duration(minutes: 10),
      );
      await _expectRendered(dt, appId, '{mode: dark}');

      // A field with a default, so the app's own `const Settings('dark')`
      // still compiles, declared ahead of the one the instance already has.
      final settings = ws.file('dep_part/lib/settings.dart');
      final original = settings.readAsStringSync();
      const constructor = 'const Settings(this.mode);';
      const field = 'final String mode;';
      expect(original, contains(constructor), reason: 'fixture marker');
      expect(original, contains(field), reason: 'fixture marker');
      settings.writeAsStringSync(
        original
            .replaceFirst(
              constructor,
              'const Settings(this.mode, [this.level = 3]);',
            )
            .replaceFirst(
              field,
              '/// How much.\n  final int level;\n\n  $field',
            ),
      );

      final reload = await dt.sendCommand(
        1,
        'app.restart',
        params: {'appId': appId},
        timeout: const Duration(seconds: 180),
      );
      expect(reload['error'], isNull, reason: 'app.restart: $reload');
      final refused = (reload['result'] as Map).cast<String, dynamic>();
      expect(refused['succeeded'], isFalse, reason: 'app.restart: $refused');
      expect(
        refused['error'],
        allOf(
          contains('Const class cannot remove fields'),
          contains('fullRestart: true'),
        ),
        reason: 'the refusal must carry the VM\'s reason and the remedy',
      );

      final restart = await dt.sendCommand(
        2,
        'app.restart',
        params: {'appId': appId, 'fullRestart': true},
        timeout: const Duration(seconds: 180),
      );
      expect(restart['error'], isNull, reason: 'app.restart: $restart');
      final result = (restart['result'] as Map).cast<String, dynamic>();
      expect(result['succeeded'], isTrue, reason: 'app.restart: $result');
      await _expectRendered(dt, appId, '{level: 3, mode: dark}');
    },
    timeout: const Timeout(Duration(minutes: 25)),
    skip: !Platform.isMacOS ? 'macOS only (needs Xcode Simulator)' : null,
  );
}

void _copyTree(Directory from, Directory to) {
  for (final entity in from.listSync(recursive: true, followLinks: false)) {
    final target = p.join(to.path, p.relative(entity.path, from: from.path));
    if (entity is Directory) {
      Directory(target).createSync(recursive: true);
    } else if (entity is File) {
      File(target).parent.createSync(recursive: true);
      entity.copySync(target);
    }
  }
}

/// Require the running app to be displaying [text].
Future<void> _expectRendered(
  DevToolProcess dt,
  String appId,
  String text,
) async {
  final found = await dt.httpCommand('app.waitFor', {
    'appId': appId,
    'text': text,
    'timeoutMs': '30000',
  });
  expect(found['error'], isNull, reason: '"$text" must be on screen: $found');
}
