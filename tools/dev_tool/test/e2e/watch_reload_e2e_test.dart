@Tags(['e2e'])
library;

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';
import 'editable_workspace.dart';

/// Watch-mode (filesystem-watcher-driven) reload over the codegen example.
///
/// Reload CORRECTNESS is otherwise verified manually (docs/TESTING.md), but the
/// watcher path has a specific failure mode this guards: an edit to a
/// DEPENDENCY package's source must resolve to a `package:` URI through the
/// build-emitted sourcePackages → `PackageUriResolver`. A path that resolves to
/// nothing is skipped by `_watchAndReload`, and the edit then triggers no
/// reload at all — silently, which is the whole difficulty.
///
/// The dropped edit is the reachable regression, and that is what is asserted.
/// The same URI merely *mis*-keyed as `file://` still reloads, correctly:
/// `ReloadOrchestrator.reload` derives each app's pending set from its own
/// workspace snapshot (`pendingAt`) and only *adds* the watcher's declared
/// list, so a wrong hint costs nothing.
///
/// Both halves are asserted, because they fail differently. `app.reloadResult`
/// says the reload ran, whether it succeeded, and which libraries it
/// recompiled; `app.waitFor` says the app is really rendering the edit.
///
/// Not a screenshot-byte diff: a slow reload, a FAILED reload and a dead
/// watcher all read identically as "the bytes never changed", and the
/// screenshot helper's `flutter → native` fallback can register a difference
/// that has nothing to do with the edit.
void main() {
  group('watch-mode reload (codegen)', () {
    test(
      'filesystem watcher reloads app + dependency source edits',
      () async {
        final ws = await editableWorkspace('codegen');
        final appMain = ws.file('lib/main.dart');
        final depSource = ws.file('dep_lib/lib/catalog.dart');
        final appMainOrig = appMain.readAsStringSync();
        final depSourceOrig = depSource.readAsStringSync();

        final dt = await startDevTool(
          workspace: ws.root,
          target: ':app_macos',
          device: 'macos',
          watch: true,
        );
        final start = await dt.waitForEvent(
          'app.start',
          timeout: const Duration(seconds: 240),
        );
        final appId = start['params']?['appId'] as String? ?? dt.appId!;
        await dt.waitForHttpControl(timeout: const Duration(seconds: 60));

        // No settle before the first edit. The watcher is started before the app
        // launches precisely so there is no window to wait out, and the second
        // test here is the one that pins that.

        // (1) Edit the app's own source — watcher must auto-reload.
        expect(
          appMainOrig.contains("'fields:"),
          isTrue,
          reason: 'fixture marker present',
        );
        final afterApp = dt.events.length;
        appMain.writeAsStringSync(
          appMainOrig.replaceFirst("'fields:", "'WATCHED:"),
        );
        await _awaitReload(
          dt,
          after: afterApp,
          recompiled: 'package:codegen_e2e/',
        );
        await _expectRendered(dt, appId, 'WATCHED:name');

        // (2) Edit a DEPENDENCY package's source — the regression case. A dep
        // path the resolver cannot key is dropped before the pipeline sees it,
        // so no reload happens at all and `package:dep_lib/...` never appears
        // among what was recompiled.
        final afterDep = dt.events.length;
        depSource.writeAsStringSync(
          depSourceOrig.replaceFirst(
            "catalogFields.join(',')",
            "'DEP-' + catalogFields.join(',')",
          ),
        );
        await _awaitReload(dt, after: afterDep, recompiled: 'package:dep_lib/');
        await _expectRendered(dt, appId, 'WATCHED:DEP-name');

        // `--machine --watch` is the combination that can write prose into its
        // own protocol channel: a watcher-driven reload reports through a `log`
        // callback whose default is a raw `stdout.writeln`, and stdout in
        // machine mode is the JSON-RPC stream a client is parsing.
        expect(
          dt.nonProtocolStdoutLines,
          isEmpty,
          reason:
              'raw text on the machine-protocol stdout stream: '
              '${dt.nonProtocolStdoutLines}',
        );
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    // The edit above is made the moment the run is up, and that window is the
    // easy one to miss: a watcher created inside the session loop starts long
    // after `app.started`, and `DirectoryWatcher` reports nothing until its own
    // initial scan finishes on top of that. An edit in that window vanishes —
    // no reload, no message — and since `app.started` is the event a driver
    // fires on, that is the window a driver edits in.
    //
    // So this one edits the instant `app.started` arrives, and waits for the
    // reload the watcher owes it.
    test(
      'an edit made the instant app.started arrives still reloads',
      () async {
        final ws = await editableWorkspace('hello_world');
        final appMain = ws.file('lib/main.dart');
        final original = appMain.readAsStringSync();
        expect(
          original.contains("'count: \$_counter'"),
          isTrue,
          reason: 'fixture marker present',
        );

        final dt = await startDevTool(
          workspace: ws.root,
          target: ':hello_world_macos',
          device: 'macos',
          watch: true,
        );
        await dt.waitForEvent(
          'app.started',
          timeout: const Duration(seconds: 240),
        );
        // No settle, deliberately.
        final cursor = dt.events.length;
        appMain.writeAsStringSync(
          original.replaceFirst("'count: \$_counter'", "'watched: \$_counter'"),
        );

        // The reload the watcher owes for that edit. A watcher that never saw it
        // and a reload that failed share one symptom — "the label still reads
        // the old text a minute later" — and only one of them is this test's
        // subject.
        await _awaitReload(
          dt,
          after: cursor,
          recompiled: 'package:hello_world/',
        );

        await dt.waitForHttpControl(timeout: const Duration(seconds: 120));
        final appId = dt.appId;
        expect(appId, isNotNull);
        final label = await dt.httpCommand('app.waitFor', {
          'appId': appId!,
          'key': 'agent_test_label',
          'timeoutMs': '10000',
        });
        expect(label['error'], isNull);
        final text = await dt.httpCommand('app.getText', {
          'appId': appId,
          'key': 'agent_test_label',
        });
        expect(
          text['result']?['text'],
          startsWith('watched:'),
          reason: 'the watcher reloaded, so the running app must show the edit',
        );
      },
      timeout: const Timeout(Duration(minutes: 6)),
    );
  });
}

/// Wait for the watcher-driven reload of the edit just made, and require it to
/// have succeeded.
///
/// Matches the first `app.reloadResult` after [after] that either recompiled
/// something under [recompiled] or failed outright. Both clauses earn their
/// place: matching only on [recompiled] would sit out the full timeout on a
/// compile error instead of reporting it, and matching on any event at all
/// could take a trailing no-op reload left over from the previous edit — a
/// single save can reach the watcher as more than one filesystem event.
Future<void> _awaitReload(
  DevToolProcess dt, {
  required int after,
  required String recompiled,
}) async {
  final event = await dt.waitForEventWhere(
    'app.reloadResult',
    after: after,
    what: 'a watcher-driven reload that recompiled $recompiled',
    timeout: const Duration(seconds: 180),
    test: (params) {
      final result = (params['result'] as Map?) ?? const {};
      if (result['succeeded'] != true) return true;
      final files = result['filesRecompiled'];
      return files is List &&
          files.any((f) => f is String && f.startsWith(recompiled));
    },
  );
  final result = (event['params']!['result'] as Map).cast<String, dynamic>();
  expect(
    result['succeeded'],
    isTrue,
    reason: 'the watcher reloaded and it failed: ${result['error']}',
  );
  expect(
    result['filesRecompiled'],
    contains(startsWith(recompiled)),
    reason:
        'the edit must reach the compiler as a `package:` URI; one the '
        'resolver cannot key is skipped and reloads nothing',
  );
}

/// Require the running app to be displaying [text].
///
/// `app.waitFor`'s `text` selector is exact equality on the widget's own
/// string, and a miss answers with a top-level `error` and no `result` — so
/// this is a real assertion about what is on screen, not a poll that can pass
/// by finding nothing.
Future<void> _expectRendered(
  DevToolProcess dt,
  String appId,
  String text,
) async {
  final found = await dt.httpCommand('app.waitFor', {
    'appId': appId,
    'text': text,
    'timeoutMs': '15000',
  });
  expect(
    found['error'],
    isNull,
    reason: 'the reload reported success, so "$text" must be on screen',
  );
}
