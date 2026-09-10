@Tags(['e2e'])
library;

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';
import 'editable_workspace.dart';

/// End-to-end: a session whose LAUNCH-TIME bazel build failed still reloads.
///
/// One step earlier than `initial_compile_recovery_e2e_test.dart`, and on the
/// wider window. The assembler runs its own `bazel build` of the
/// flutter_application — the build that produces `_dev_config.json`, the dev
/// package config and the plugin registrants — before it starts any compiler,
/// and that build compiles the app's kernel too (`kernel_dill` is in the rule's
/// `DefaultInfo` under `is_debug`). A source file that does not compile fails
/// it.
///
/// That failure must not end the run's usefulness. A readiness gate settled
/// unavailable short-circuits every later reload, so fixing the code changes
/// nothing and the user is told `Could not start the frontend server` about a
/// component that is working and was never started.
///
/// ## Why this window is the likely one
///
/// The edit has to land after `run`'s own launch build and before the
/// assembler's. Between them sits an app launch: the process starts, the engine
/// comes up, the VM service answers, the agent registers, the build record is
/// read. Seconds, in a run that has already printed `app.started`. A developer
/// who saves a typo while the app is coming up lands here; the narrower window
/// after this build is what the initial-compile test covers.
///
/// `resolving_toolchain` is the last thing the assembler logs before the
/// cquery and the build, which makes it the event to edit on rather than a
/// sleep. Deliberately not the build's own `bazel_command` record: an edit
/// racing bazel's read of the file is a coin flip, and a lost flip lands in the
/// *other* recovery path — a flake that would pass the wrong test.
///
/// ## What is asserted, and why each part
///
///  1. The build really did fail, and said so as a build (`dev_build_failed`).
///     Without this the test could pass by never reproducing the condition.
///  2. `recoverable: true`. This runs in `--machine` mode, where the JSON
///     logger drops the human `text` — so this field is the whole of what an
///     IDE or agent has to decide whether the session it holds is worth
///     keeping, and asserting the prose would assert nothing.
///  3. The fix reloads and the app renders it. Not "the process is still
///     alive": the edit reaching the screen of an app launched before the
///     failure and never restarted.
///
/// `hello_world` on purpose: no codegen, so nothing else in the run puts a
/// bazel build on the reload path and the failure under test cannot be confused
/// with one.
void main() {
  group('launch-time build failure', () {
    test(
      'a session whose dev build failed reloads once the code is fixed',
      () async {
        final ws = await editableWorkspace('hello_world');
        final appMain = ws.file('lib/main.dart');
        final original = appMain.readAsStringSync();
        const anchor = "'count: \$_counter'";
        expect(
          original.contains(anchor),
          isTrue,
          reason: 'fixture marker present in hello_world lib/main.dart',
        );
        expect(
          original.contains('BREAK_THE_DEV_BUILD'),
          isFalse,
          reason:
              'hello_world lib/main.dart still carries an edit from an '
              'earlier run; restore it before running this test',
        );

        final dt = await startDevTool(
          workspace: ws.root,
          target: ':hello_world_macos',
          device: 'macos',
          watch: true,
        );

        /// Write [original] with [anchor] replaced, and fail loudly if the
        /// anchor matched nothing.
        ///
        /// Always from [original] rather than from what is on disk: each edit
        /// replaces the previous one, so an anchor consumed by the last write
        /// would match nothing in the next. That is the same silent no-op the
        /// guard exists for — every assertion below would then be made about an
        /// unchanged file, and a "passing" run would prove nothing at all.
        void edit(String replacement) {
          final after = original.replaceFirst(anchor, replacement);
          expect(
            after,
            isNot(original),
            reason:
                'the edit anchor $anchor matched nothing, so this test '
                'would have gone on asserting about an unchanged file',
          );
          appMain.writeAsStringSync(after);
        }

        // The assembler's last log line before the cquery and the build it
        // needs. Waiting on it is what puts the edit inside the window instead
        // of near it.
        await dt.waitForStderr(
          'resolving_toolchain',
          timeout: const Duration(minutes: 5),
        );
        edit('BREAK_THE_DEV_BUILD(\$_counter)');

        // (1) and (2). The condition really happened, it was reported as the
        // build failure it is, and the caller was told the session survives it.
        final reported = await dt.waitForStderr(
          'dev_build_failed',
          timeout: const Duration(minutes: 8),
        );
        expect(
          reported,
          contains('"recoverable":true'),
          reason:
              'a session that will build again has to say so; silence here '
              'is what made this read as "hot reload is broken": $reported',
        );
        expect(
          reported,
          isNot(contains('frontend server')),
          reason:
              'the compiler was never started, let alone broken — naming '
              'it sends the reader to the wrong place: $reported',
        );

        // (3) The fix, and the bar. A marker of its own rather than the original
        // text: restoring `original` byte-for-byte would leave a passing
        // assertion that a reload which never happened could also satisfy.
        final fixed = dt.events.length;
        edit("'recovered: \$_counter'");

        final reload = await dt.waitForEventWhere(
          'app.reloadResult',
          after: fixed,
          what: 'the watcher-driven reload of the fix',
          timeout: const Duration(minutes: 8),
          test: (params) {
            final result = (params['result'] as Map?) ?? const {};
            // A failure is matched too, so a run that answers with one fails at
            // the assertion below with its reason rather than at a timeout with
            // nothing.
            if (result['succeeded'] != true) return true;
            final files = result['filesRecompiled'];
            return files is List &&
                files.any(
                  (f) => f is String && f.startsWith('package:hello_world/'),
                );
          },
        );
        final result = (reload['params']!['result'] as Map)
            .cast<String, dynamic>();
        expect(
          result['succeeded'],
          isTrue,
          reason:
              'the reload after the fix is the whole point, and it '
              'failed: ${result['error']}',
        );

        // On screen, in the app that was launched before any of this and never
        // restarted. `app.waitFor` compares the widget's whole string, so this
        // cannot pass by finding nothing.
        await dt.waitForHttpControl(timeout: const Duration(minutes: 2));
        final appId = dt.appId;
        expect(appId, isNotNull);
        final shown = await dt.httpCommand('app.waitFor', {
          'appId': appId!,
          'text': 'recovered: 0',
          'timeoutMs': '30000',
        });
        expect(
          shown['result']?['error'],
          isNull,
          reason: 'the app must be rendering the fix: $shown',
        );
      },
      timeout: const Timeout(Duration(minutes: 15)),
    );
  });
}
