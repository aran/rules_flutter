/// A run keeps working after the path it was launched through goes away.
///
/// The usual build-then-run form is `./bazel-bin/.../flutter_bazel run …`, and
/// that path goes through the `bazel-bin` convenience symlink — which the run's
/// own `-c dbg` app build repoints at a tree with no flutter_bazel in it. So
/// the launch path stops existing a second into every such run. Two things read
/// it lazily and broke:
///
///  * DDS reads `Platform.resolvedExecutable` for every websocket client it
///    accepts. The first read came after the repoint and threw inside DDS's
///    error zone, and every client hung: five 30-second connect attempts, then
///    "No VM service connection on macOS".
///  * The bundled helpers (the macOS screenshot tool, among others) were found
///    next to the launch path on every lookup, and so were not found at all.
///
/// Reported by frustrate; `bazel run` and a launch through the output's real
/// path were unaffected. This reproduces it without depending on how
/// `bazel-bin` happens to be pointed: the tool is launched through a symlink of
/// the test's own, deleted once the tool reports it is launching the app —
/// after the tool started, before the app's VM service exists.
@Tags(['e2e'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';

void main() {
  test(
    'macOS: a run launched through a path that then vanishes still connects',
    () async {
      // The directory holding the binary *and* its runfiles tree, linked as a
      // unit: the runfiles are found next to the path the tool was run by.
      final built = File(await ensureBuiltDevTool()).parent.path;
      final scratch = Directory.systemTemp.createTempSync('launch_path_');
      addTearDown(() => scratch.deleteSync(recursive: true));
      final link = Link(p.join(scratch.path, 'tool'))..createSync(built);

      final dt = await spawnBoundToTest(
        spawn: () async => DevToolProcess(
          await Process.start(
            p.join(link.path, p.basename(await ensureBuiltDevTool())),
            [
              'run',
              '-t',
              ':app',
              '-d',
              'macos',
              '--machine',
              '--no-devtools',
            ],
            workingDirectory: e2eWorkspace('macos_example'),
            environment: {...Platform.environment, 'LOG_FORMAT': 'json'},
          ),
        ),
        dispose: (tool) => tool.dispose(),
      );

      await dt.waitForStderr(
        '"message":"launching"',
        timeout: const Duration(minutes: 5),
      );
      link.deleteSync();

      final start = await dt.waitForEvent(
        'app.start',
        timeout: const Duration(minutes: 2),
      );
      final appId = start['params']?['appId'] as String? ?? dt.appId!;
      await dt.waitForHttpControl();

      // The VM service connection: what hung.
      final text = await dt.httpCommand('app.getText', {
        'appId': appId,
        'key': 'e2e_define_label',
        'timeoutMs': '30000',
      });
      expect(
        text['error'],
        isNull,
        reason: 'the agent surface rides the VM service connection',
      );

      // A bundled helper, resolved after the launch path is gone.
      await dt.nativeScreenshotWhenOnScreen(appId);
      final shot = await dt.httpNativeScreenshotReply(appId);
      expectRendered(shot.bytes, what: 'the app captured after the path moved');

      await dt.sendCommand(1, 'daemon.shutdown');
    },
    skip: !Platform.isMacOS ? 'macOS only' : null,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
