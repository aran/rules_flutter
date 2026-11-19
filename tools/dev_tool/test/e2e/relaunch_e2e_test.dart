@Tags(['e2e'])
/// The control channel must survive the restart branch that relaunches the
/// app process.
///
/// A hot restart cannot replace a `dlopen`ed native library, so `app.restart`
/// rebuilds and — when the bundle's loose native libraries changed — kills the
/// running process and launches the rebuilt one. A session loop that reads that
/// deliberate kill as the app exiting closes the HTTP control channel, so the
/// driver gets `{"relaunched":true}` and then connection-refused, with the
/// relaunched app alive and no second banner to find it by. Nothing short of
/// driving a real native-library change exercises that branch, which is why
/// this test edits C source rather than Dart.
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';
import 'editable_workspace.dart';

/// The app under test.
const _app = E2eApp('ffi_example');

/// A platform this test drives: where the app runs and what its launch is
/// called, and the output group of the bundle parts its restart builds.
typedef _Platform = ({String device, String target, String partsGroup});

const _platforms = <_Platform>[
  (
    device: 'macos',
    target: ':ffi_macos',
    partsGroup: 'flutter_macos_bundle_parts',
  ),
  (
    device: 'ios-simulator',
    target: ':ffi_ios',
    partsGroup: 'flutter_ios_bundle_parts',
  ),
  (
    device: 'linux',
    target: ':ffi_linux',
    partsGroup: 'flutter_linux_bundle_parts',
  ),
  (
    device: 'windows',
    target: ':ffi_windows',
    partsGroup: 'flutter_windows_bundle_parts',
  ),
];

void main() {
  for (final platform in _platforms) {
    group(
      'native-library relaunch on ${platform.device}',
      () {
        test(
          'keeps the control channel, and the relaunched app answers on it',
          () async {
            final ws = await editableWorkspace(_app);
            // `mul` is bundled as a loose dylib (the `native_deps` contract), so a
            // change here is what makes the rebuilt bundle's fingerprint differ.
            final mulSource = ws.file('native/mul.c');
            final original = mulSource.readAsStringSync();
            expect(
              original,
              contains('return a * b;'),
              reason: 'fixture marker',
            );

            final dt = await startDevTool(
              workspace: ws.root,
              target: platform.target,
              device: platform.device,
              // Never pass `viaDartRun` here, whatever the default becomes: this
              // workspace is itself a pub package whose deps carry native-asset
              // build hooks, and `dart run` from its directory runs those hooks
              // before anything else — which fails on a hook.dill left by a
              // different SDK and never launches the tool.
            );
            // The launch is a full `bazel build` of a bundle with three
            // native libraries; when it does not arrive, the reason is in the dev
            // tool's own output, so say it here rather than leaving a bare
            // TimeoutException.
            try {
              await dt.waitForEvent(
                'app.started',
                timeout: const Duration(minutes: 6),
              );
            } on TimeoutException {
              fail(
                'no app.started within 6m.\nstderr:\n'
                '${dt.stderrLines.join('\n')}\n'
                'stdout (non-protocol):\n'
                '${dt.nonProtocolStdoutLines.join('\n')}',
              );
            }
            final appId = dt.appId!;
            await dt.waitForHttpControl();
            final before = await dt.httpLogs(appId);
            expect(before['launch'], 1);

            mulSource.writeAsStringSync(
              original.replaceFirst('return a * b;', 'return a * b + 1;'),
            );

            final restart = await dt.httpCommand('app.restart', {
              'appId': appId,
              'fullRestart': true,
            });
            final result = restart['result'] as Map<String, dynamic>?;
            expect(
              result,
              isNotNull,
              reason: 'app.restart: ${restart['error']}',
            );
            expect(
              result!['relaunched'],
              isTrue,
              reason: 'a changed dylib must relaunch, not hot restart: $result',
            );
            expect((result['launch'] as Map)[appId], 2);
            // The reload wire contract, on the one path that builds its own reply
            // map rather than sharing the restart one. A client reading
            // `succeeded`'s absence as false would call a working relaunch a
            // failure.
            expect(
              result['succeeded'],
              isTrue,
              reason: 'the relaunch worked, and the reply must say so outright',
            );
            // `updated`, and provably: this process is new and launched from the
            // bundle the rebuild just produced.
            expect(
              result['runningCode'],
              'updated',
              reason: 'a replaced process cannot be running its old code',
            );
            expect(result['error'], isNull);
            // The response is not sent until the replacement can be driven.
            expect(
              result['ready'],
              isTrue,
              reason:
                  'the relaunched app should have rendered a frame — and so '
                  'registered its service extensions — before this returned',
            );

            // The whole point: the same channel, on the same port, still answers —
            // and answers about the process that replaced the one it just killed.
            final tree = await dt.httpCommand('app.dumpWidgetTree', {
              'appId': appId,
            });
            expect(
              tree['error'],
              isNull,
              reason: 'the channel must outlive the relaunch: ${tree['error']}',
            );

            // The app rebuilt against the edited C: 3 * 4 is now reported as 13.
            final rendered = await dt.httpCommand('app.waitFor', {
              'appId': appId,
              'text': '3 + 4 = 7\n3 × 4 = 13\nsqlite3 ${_sqliteVersion(tree)}',
              'timeoutMs': '15000',
            });
            expect(
              rendered['error'],
              isNull,
              reason:
                  'the relaunched app should run the rebuilt dylib: '
                  '${rendered['error']}',
            );

            // Cursors do not survive the swap; `launch` is how a poller finds out.
            final after = await dt.httpLogs(
              appId,
              since: before['nextCursor'] as int,
            );
            expect(after['launch'], 2);
          },
          timeout: const Timeout(Duration(minutes: 8)),
        );

        // A header is not a library: it reaches the bundle only through the
        // library built from the source that includes it, so the check has to
        // follow the build rather than the files an edit touched.
        test(
          'an edit to a header a library includes relaunches',
          () async {
            final ws = await editableWorkspace(_app);
            final header = ws.file('native/add.h');
            final source = ws.file('native/add.c');
            expect(
              source.readAsStringSync(),
              contains('return a + b;'),
              reason: 'fixture marker',
            );
            // `add`'s result reads a constant its header defines, so that the
            // header is the only thing the later edit touches.
            header.writeAsStringSync(
              header.readAsStringSync().replaceFirst(
                '#include <stdint.h>',
                '#include <stdint.h>\n#define ADD_BIAS 0',
              ),
            );
            source.writeAsStringSync(
              source.readAsStringSync().replaceFirst(
                'return a + b;',
                'return a + b + ADD_BIAS;',
              ),
            );

            final dt = await startDevTool(
              workspace: ws.root,
              target: platform.target,
              device: platform.device,
            );
            await dt.waitForEvent(
              'app.started',
              timeout: const Duration(minutes: 6),
            );
            final appId = dt.appId!;
            await dt.waitForHttpControl();
            // An edit inside the assembler's own build window is compiled into its
            // baseline, so nothing is edited before the pipeline is up.
            await dt.waitForStderr('frontend_server_ready');

            header.writeAsStringSync(
              header.readAsStringSync().replaceFirst(
                '#define ADD_BIAS 0',
                '#define ADD_BIAS 1',
              ),
            );
            final restart = await dt.httpCommand('app.restart', {
              'appId': appId,
              'fullRestart': true,
            });
            final result = restart['result'] as Map<String, dynamic>?;
            expect(
              result,
              isNotNull,
              reason: 'app.restart: ${restart['error']}',
            );
            expect(
              result!['relaunched'],
              isTrue,
              reason: 'an edited header changed the library it builds: $result',
            );

            final tree = await dt.httpCommand('app.dumpWidgetTree', {
              'appId': appId,
            });
            final rendered = await dt.httpCommand('app.waitFor', {
              'appId': appId,
              'text': '3 + 4 = 8\n3 × 4 = 12\nsqlite3 ${_sqliteVersion(tree)}',
              'timeoutMs': '15000',
            });
            expect(
              rendered['error'],
              isNull,
              reason:
                  'the relaunched app should run the library rebuilt from the '
                  'edited header: ${rendered['error']}',
            );
            await dt.sendCommand(1, 'daemon.shutdown');
          },
          timeout: const Timeout(Duration(minutes: 8)),
        );

        // Finding out that no native library moved must not cost a build of the
        // bundle: its App.framework holds the app's kernel, so building it
        // recompiles the whole program for every Dart edit and re-signs the app,
        // while the restart compiles the same edit itself in a fraction of that.
        test(
          'a Dart-only edit builds nothing of the bundle and keeps the process',
          () async {
            final ws = await editableWorkspace(_app);
            final main = ws.file('lib/main.dart');
            final original = main.readAsStringSync();
            const marker = r"debugPrint('$marker (sqlite3 $sqliteVersion)');";
            expect(original, contains(marker), reason: 'fixture marker');

            final dt = await startDevTool(
              workspace: ws.root,
              target: platform.target,
              device: platform.device,
            );
            await dt.waitForEvent(
              'app.started',
              timeout: const Duration(minutes: 6),
            );
            final appId = dt.appId!;
            await dt.waitForHttpControl();
            // An edit inside the assembler's own build window is compiled into its
            // baseline, so nothing is edited before the pipeline is up.
            await dt.waitForStderr('frontend_server_ready');

            main.writeAsStringSync(
              original.replaceFirst(
                marker,
                r"debugPrint('$marker (sqlite3 $sqliteVersion) v2');",
              ),
            );
            final seen = dt.stderrLines.length;
            final restart = await dt.httpCommand('app.restart', {
              'appId': appId,
              'fullRestart': true,
            });
            final result = restart['result'] as Map<String, dynamic>?;
            expect(
              result,
              isNotNull,
              reason: 'app.restart: ${restart['error']}',
            );
            expect(
              result!['relaunched'],
              isNot(isTrue),
              reason:
                  'no native library moved, so the process must stay: $result',
            );

            // The restart ran the edited `main()`.
            await dt.waitForAppLog(RegExp(r'\(sqlite3 [^)]*\) v2'));

            final builds = [
              for (final line in dt.stderrLines.skip(seen))
                if (line.contains('"message":"bazel_command"') &&
                    line.contains('"args":["build"'))
                  line,
            ];
            expect(
              builds,
              isNotEmpty,
              reason:
                  'the restart reads the native libraries, which is a build; if '
                  'it logged none, this test is not looking at the right records',
            );
            for (final build in builds) {
              expect(
                build,
                contains(platform.partsGroup),
                reason: 'a restart built more than the bundle parts: $build',
              );
            }
            await dt.sendCommand(1, 'daemon.shutdown');
          },
          timeout: const Timeout(Duration(minutes: 8)),
        );
      },
      skip: _hostSkip(platform),
      tags: platform.device == 'ios-simulator' ? 'ios_sim' : platform.device,
    );
  }
}

/// Why [platform] cannot run on this host, or null when it can: macOS runs the
/// Apple devices, Linux the Linux one and Windows the Windows one.
String? _hostSkip(_Platform platform) {
  final runs = switch (platform.device) {
    'linux' => Platform.isLinux,
    'windows' => Platform.isWindows,
    _ => Platform.isMacOS,
  };
  return runs ? null : '${platform.device} runs on a different host OS';
}

/// The sqlite3 version the app rendered, read out of the widget-tree dump so
/// the expected label can be matched exactly without pinning a version.
String _sqliteVersion(Map<String, dynamic> tree) {
  final match = RegExp(
    r'sqlite3 ([0-9.]+)',
  ).firstMatch(tree['result'].toString());
  expect(match, isNotNull, reason: 'widget tree should show the sqlite label');
  return match!.group(1)!;
}
