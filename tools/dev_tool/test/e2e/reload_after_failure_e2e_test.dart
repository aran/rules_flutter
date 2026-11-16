@Tags(['e2e', 'macos'])
library;

import 'dart:io';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';
import 'editable_workspace.dart';

/// End-to-end: a session survives a failed hot reload.
///
/// Every assertion here is about a command ANSWERING. The reload in the middle
/// is *expected* to report failure — the app really is broken by then — and
/// that is not what this covers. What it covers is that it answers at all, and
/// that a restart afterwards still recovers the session. An unread `reject`
/// response desynchronises the compiler pipe, and every command behind it then
/// queues on the `Pool(1)` permit with no error and no output.
///
/// Driven against the codegen app because its reload path is the widest one: a
/// bazel build for regenerated sources, then the resident compiler.
///
/// The restart-then-`app.waitFor` pair at the end carries a second guard: this
/// is the only automated run in which a SOURCE-ASSEMBLED app is hot-restarted.
/// That is the one configuration where the dev compiler's `file://` `--source`
/// for the generated plugin registrant meets a mounted multi-root file system
/// (see the `dartPluginRegistrantUri:` comment in
/// `native_pipeline_assembler.dart`), and only extensions that registrant
/// brought up can answer an `app.*` command in the fresh isolate. Weakening
/// that assertion to something the framework answers on its own would silently
/// drop the coverage.
/// A reload of this app runs a bazel build (regenerated sources, then the
/// bundle's cquery) before it compiles, so under a loaded machine it
/// legitimately takes longer than the harness's 60s default. A reload that is
/// really wedged still fails, at three minutes.
const _reloadTimeout = Duration(minutes: 3);

void main() {
  group('reload after failure e2e', () {
    test(
      'a failed reload does not wedge the commands after it',
      () async {
        final ws = await editableWorkspace('codegen');
        final user = ws.file('lib/user.dart');
        final settings = ws.file('dep_part/lib/settings.dart');
        final userOrig = user.readAsStringSync();
        final settingsOrig = settings.readAsStringSync();
        expect(
          userOrig,
          contains('const User(this.name, this.age);'),
          reason: 'fixture marker present in codegen lib/user.dart',
        );
        // Both fixtures must start pristine, not merely contain their markers.
        // These edits are `replaceFirst`, so an edit already present — a probe
        // that died before reverting, another driver mid-run — silently yields a
        // DUPLICATE declaration and the app fails to compile for a reason that
        // has nothing to do with what is under test. Naming it beats debugging it.
        expect(
          settingsOrig,
          isNot(contains('int get probe')),
          reason:
              'codegen dep_part/lib/settings.dart still carries an edit '
              'from an earlier run; restore it before running this test',
        );
        expect(
          userOrig,
          isNot(contains('String email')),
          reason:
              'codegen lib/user.dart still carries an edit from an earlier '
              'run; restore it before running this test',
        );

        final dt = await startDevTool(
          workspace: ws.root,
          target: ':app_macos',
          device: 'macos',
        );
        final start = await dt.waitForEvent(
          'app.start',
          timeout: const Duration(minutes: 8),
        );
        final appId = start['params']?['appId'] as String? ?? dt.appId!;
        await dt.waitForHttpControl(timeout: const Duration(seconds: 90));
        // Edit only once the pipeline has assembled. `app.started` comes first
        // and the assembler then runs its own `bazel build` and the compiler's
        // first compile, so an edit made before this is read by that build as
        // part of the baseline, and a reload sent in that window waits on the
        // readiness gate for the whole assembly before it even starts its own
        // rebuild. Measured on a loaded machine (load average ~50): the pipeline
        // was ready 8s after `app.started` and a reload sent at `app.started`
        // answered 7s after that. A suite run under heavier load stretches each
        // part, and the first reload was the one that ran out of its 60s.
        await dt.waitForStderr(
          'frontend_server_ready',
          timeout: const Duration(minutes: 6),
        );

        final ready = await dt.httpCommand('app.waitFor', {
          'appId': appId,
          'text': '{name: Ada Lovelace, age: 36}',
          'timeoutMs': '30000',
        });
        expect(
          ready['error'],
          isNull,
          reason: 'the app renders its generated toJson: $ready',
        );

        // Break it. A NON-nullable field is the point: the reload applies, but
        // `const User('Ada Lovelace', 36)` was canonicalized in main() before it,
        // so the stale instance holds null for the new field and the next frame
        // throws.
        user.writeAsStringSync(
          userOrig
              .replaceFirst(
                'final int age;',
                'final int age;\n  final String email;',
              )
              .replaceFirst(
                'const User(this.name, this.age);',
                "const User(this.name, this.age, [this.email = 'ada@lovelace.dev']);",
              ),
        );
        final failed = await dt.sendCommand(
          1,
          'app.hotReload',
          params: {'appId': appId},
          timeout: _reloadTimeout,
        );
        expect(
          failed['result']?['error'],
          isNotNull,
          reason:
              'this reload is expected to fail — the app throws on the '
              'next frame. It must still ANSWER: $failed',
        );

        // Editing a different package on purpose: what is being tested is the
        // compiler's state after a rejected compile, not whether this
        // particular edit fixes anything.
        settings.writeAsStringSync(
          settingsOrig.replaceFirst(
            'final String mode;',
            'final String mode;\n  int get probe => 1;',
          ),
        );
        final afterFailure = await dt.sendCommand(
          2,
          'app.hotReload',
          params: {'appId': appId},
          timeout: _reloadTimeout,
        );
        expect(
          afterFailure,
          isNotNull,
          reason:
              'the reload after a failed reload never answered — the '
              'compiler is still holding an unread reject response',
        );

        // And the session is recoverable: a restart re-runs main(), which builds
        // a fresh User that has the new field.
        final restart = await dt.sendCommand(
          3,
          'app.restart',
          params: {'appId': appId, 'fullRestart': true},
        );
        expect(
          restart['error'],
          isNull,
          reason: 'app.restart: ${restart['error']}',
        );
        expect(
          restart['result']?['message'],
          contains('successful'),
          reason: 'a restart must recover the session: ${restart['result']}',
        );

        // The agent surface answers too, rather than sitting behind a held permit.
        // Exact equality, not a substring: `app.waitFor`'s `text` selector
        // compares the whole rendered string, so a fragment never matches.
        final text = await dt.httpCommand('app.waitFor', {
          'appId': appId,
          'text': '{name: Ada Lovelace, age: 36, email: ada@lovelace.dev}',
          'timeoutMs': '30000',
        });
        expect(
          text['error'],
          isNull,
          reason:
              'after the restart the regenerated toJson renders the new '
              'field: $text',
        );
      },
      timeout: const Timeout(Duration(minutes: 12)),
      skip: !Platform.isMacOS ? 'macOS only' : null,
    );
  });
}
