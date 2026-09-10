@Tags(['e2e'])
library;

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';
import 'editable_workspace.dart';

/// End-to-end: a session whose FIRST compile failed still reloads.
///
/// One failed initial compile must not end the run's usefulness. An
/// `_assembleUnit` that shuts its compiler down and settles the readiness gate
/// unavailable makes every later reload short-circuit on that verdict, in
/// milliseconds and with no retry — so fixing the code changes nothing, nothing
/// says why, and the only way back is to kill the session and start over.
///
/// ## Why this needs a driver rather than a broken fixture
///
/// A source file that is broken when the run starts never reaches the initial
/// compile at all: `run` builds the app with Bazel first, and a broken tree
/// fails there — no app, no session, nothing to brick. The initial compile
/// reads the working tree SECONDS LATER, and what it reads is whatever is on
/// disk by then. So the break has to land inside that window, and the window
/// is real: it is the one a `bazel build` in another terminal lands in, and the
/// one a developer lands in by saving while the app is still coming up.
/// `package_roots_stabilized` is the last thing the assembler
/// logs before it compiles, which makes it the event to edit on — no sleeps,
/// no guessing how long a launch takes.
///
/// ## What is asserted, and why each part
///
///  1. The compile really did fail (`initial_compile_failed`). Without this
///     the test could pass by never reproducing the condition at all.
///  2. The session ANSWERS while it is in that state — the reload the watcher
///     owes for the breaking edit itself comes back as a failure with the
///     compiler's diagnostics, rather than the ~200ms refusal.
///  3. The fix reloads and the app renders it. This is the bar: not "the
///     process is still alive", but the edit reaching the screen of an app
///     that was launched before the failure and never restarted.
///
/// `hello_world` on purpose: no codegen, so a reload is the compiler alone
/// with no Bazel build in the loop, and the failure under test cannot be
/// confused with a build failure.
void main() {
  group('initial compile failure', () {
    test(
      'a session whose first compile failed reloads once the code is fixed',
      () async {
        final ws = await editableWorkspace('hello_world');
        final appMain = ws.file('lib/main.dart');
        final original = appMain.readAsStringSync();
        expect(
          original.contains("'count: \$_counter'"),
          isTrue,
          reason: 'fixture marker present in hello_world lib/main.dart',
        );
        expect(
          original.contains('BREAK_THE_FIRST_COMPILE'),
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
        // The assembler's last log line before it compiles. Waiting on it is
        // what puts the edit inside the window instead of near it.
        await dt.waitForStderr(
          'package_roots_stabilized',
          timeout: const Duration(minutes: 5),
        );
        final broke = dt.events.length;
        appMain.writeAsStringSync(
          original.replaceFirst(
            "'count: \$_counter'",
            "BREAK_THE_FIRST_COMPILE(\$_counter)",
          ),
        );

        // (1) The condition really happened. Also what the caller is told about
        // it, which is the moment they decide whether the session is worth
        // keeping. This runs in `--machine` mode, where the JSON logger drops
        // the human `text` — so `recoverable` is the field an IDE or agent
        // actually has, and asserting the prose here would assert nothing.
        final reported = await dt.waitForStderr(
          'initial_compile_failed',
          timeout: const Duration(minutes: 5),
        );
        expect(
          reported,
          contains('BREAK_THE_FIRST_COMPILE'),
          reason:
              'the compiler diagnostics have to reach the caller, or the '
              'failure names no cause: $reported',
        );
        expect(
          reported,
          contains('"recoverable":true'),
          reason:
              'a session that will compile again has to say so; silence '
              'here is what made this read as "hot reload is broken": '
              '$reported',
        );

        // (2) The session answers in that state. The watcher owes a reload for
        // the breaking edit itself, and it must come back as a compile failure —
        // not the instant refusal a settled gate gives, and not silence.
        final failed = await dt.waitForEventWhere(
          'app.reloadResult',
          after: broke,
          what: 'the watcher-driven reload of the breaking edit',
          timeout: const Duration(minutes: 4),
          test: (params) => params['result'] is Map,
        );
        final failedResult = (failed['params']!['result'] as Map)
            .cast<String, dynamic>();
        expect(
          failedResult['succeeded'],
          isFalse,
          reason:
              'the tree is broken, so this reload must fail — what is '
              'under test is that it ANSWERS: $failedResult',
        );

        // (3) The fix, and the bar. A marker of its own rather than the original
        // text: restoring `original` byte-for-byte would leave a passing
        // assertion that a reload which never happened could also satisfy.
        final fixed = dt.events.length;
        appMain.writeAsStringSync(
          original.replaceFirst(
            "'count: \$_counter'",
            "'recovered: \$_counter'",
          ),
        );

        final reload = await dt.waitForEventWhere(
          'app.reloadResult',
          after: fixed,
          what: 'the watcher-driven reload of the fix',
          timeout: const Duration(minutes: 4),
          test: (params) {
            final result = (params['result'] as Map?) ?? const {};
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
      timeout: const Timeout(Duration(minutes: 12)),
    );
  });
}
