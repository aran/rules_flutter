@Tags(['e2e'])
library;

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';
import 'editable_workspace.dart';

/// The web dev loop's startup window, from the watcher's side.
///
/// The watcher has to be started before web assembly — module server, DWDS,
/// frontend server, first DDC compile — or a save made during those seconds
/// fires no watch event at all.
///
/// The edit is never *lost* either way: the initial compile reads it if it
/// lands before the snapshot cut, and the next reload re-sends it otherwise.
/// Only the TRIGGER goes missing, so the app displays the edit whether or not
/// the watcher saw it — which is why asserting the rendered text alone would
/// pass against a watcher that started too late. The `app.reloadResult`
/// assertion is the one that carries this test.
///
/// `package_roots_stabilized` is the last line the web assembler logs before
/// it compiles, which puts the edit inside the window rather than near it —
/// the same anchor `web_initial_compile_recovery_e2e_test` uses, and for the
/// same reason: an event, not a sleep.
void main() {
  group('web watch window', () {
    test(
      'a save during web assembly still drives a reload',
      () async {
        final ws = await editableWorkspace('web_example');
        final appMain = ws.file('lib/main.dart');
        final original = appMain.readAsStringSync();
        const anchor =
            "const Text('You have pushed the button this many times:')";
        expect(
          original.contains(anchor),
          isTrue,
          reason: 'fixture marker present in web_example lib/main.dart',
        );
        expect(
          original.contains('WEB_WATCH_'),
          isFalse,
          reason:
              'web_example lib/main.dart still carries an edit from an '
              'earlier run; restore it before running this test',
        );

        final dt = await startDevTool(
          workspace: ws.root,
          target: ':app_wasm',
          device: 'chrome',
          watch: true,
        );
        // Inside the window, not near it.
        await dt.waitForStderr(
          'package_roots_stabilized',
          timeout: const Duration(minutes: 5),
        );

        final before = dt.events.length;
        // An anchor that matched nothing would make this a copy, and every
        // assertion below would then hold against a tree nobody edited.
        final edited = original.replaceFirst(
          anchor,
          "const Text('WEB_WATCH_SAVED')",
        );
        if (edited == original) {
          fail(
            'the edit anchor matched nothing in ${appMain.path}, so this run '
            'would assert against an unchanged file: $anchor',
          );
        }
        appMain.writeAsStringSync(edited);

        // THE assertion. A reload the watcher drove, carrying this app's own
        // sources — polled against a deadline generous enough that reaching it
        // means no event is coming, rather than a budget on how fast one
        // arrives.
        final event = await dt.waitForEventWhere(
          'app.reloadResult',
          after: before,
          what: 'a watcher-driven reload recompiling package:web_example/',
          timeout: const Duration(minutes: 4),
          test: (params) {
            final result = (params['result'] as Map?) ?? const {};
            if (result['succeeded'] != true) return true;
            final files = result['filesRecompiled'];
            return files is List &&
                files.any(
                  (f) => f is String && f.startsWith('package:web_example/'),
                );
          },
        );
        final result = (event['params']!['result'] as Map)
            .cast<String, dynamic>();

        // NOT asserted to have succeeded, and the reason is the point of the
        // window: at this instant Chrome has not connected, so a reload has
        // nowhere to deliver to and says so ("no browser client connected yet —
        // the recompiled code will load when one connects"). Requiring
        // success here would be requiring a page that does not exist yet.
        //
        // What matters is that the save was SEEN. Before the watcher moved
        // above web assembly there was no event at all: no reload, no
        // message, and the developer's only signal was the app quietly coming
        // up right. The delivery assertion below is what proves the reported
        // outcome is not hiding a dropped edit.
        expect(
          result,
          isNotEmpty,
          reason: 'a watcher-driven reload must report an outcome',
        );

        // And the page really is showing it. Not sufficient on its own — see
        // the note above — but a reload reported against a page that never
        // changed is exactly what this must not accept.
        final start = await dt.waitForEvent(
          'app.start',
          timeout: const Duration(minutes: 5),
        );
        final appId = start['params']?['appId'] as String? ?? dt.appId!;
        // The reload above happened before the app existed, so the agent
        // extension it is asked through is not up yet. Waited for by its own
        // events rather than guessed at.
        await dt.waitForEvent(
          'app.started',
          timeout: const Duration(minutes: 5),
        );
        await dt.waitForHttpControl(timeout: const Duration(minutes: 2));
        final found = await dt.httpCommand('app.waitFor', {
          'appId': appId,
          'text': 'WEB_WATCH_SAVED',
          'timeoutMs': '30000',
        });
        expect(
          found['error'],
          isNull,
          reason: 'the reload reported success, so the edit must be on screen',
        );
      },
      timeout: const Timeout(Duration(minutes: 8)),
    );
  });
}
