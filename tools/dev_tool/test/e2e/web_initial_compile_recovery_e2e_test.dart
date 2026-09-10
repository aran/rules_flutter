@Tags(['e2e'])
library;

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';
import 'editable_workspace.dart';

/// End-to-end: a browser run whose FIRST compile failed still gets its app.
///
/// ## What web does not share with native, and what follows from it
///
/// Native's app is already running the build it launched with, so a failed
/// first compile leaves a working app and a later hot reload has a program to
/// inject into. Here Chrome opens the module server *before* anything has
/// compiled, and what the page loads is the first compile's own output — so a
/// first compile that failed leaves the page with nothing on it.
///
/// Two consequences, both load-bearing:
///
///  * An increment has nothing to be an increment of, so `hotReload` runs the
///    restart instead. It is not merely insufficient: a `recompile` after a
///    rejected first `compile` answers with a *delta*, and a delta merged as a
///    first compile leaves the module server serving a fraction of a program
///    while believing it holds all of one.
///  * DWDS connects anyway — its client rides in the page's bootstrap, not in
///    the program — and its `hotRestart` against a page with no program answers
///    "Successful hot restart" instantly having done nothing. Only a navigation
///    makes the page fetch the program.
///
/// ## Why a driver rather than a broken fixture
///
/// A tree that is broken when the run starts never reaches the initial compile:
/// `run` builds with Bazel first, and a broken tree fails there — no server, no
/// browser, nothing to recover. The compile reads the working tree seconds
/// later, and `package_roots_stabilized` is the last line the web assembler
/// logs before it compiles, which makes it the event to edit on rather than a
/// sleep.
///
/// `--watch` on purpose, and unlike its sibling `web_restart_after_failure`:
/// the watcher is the whole point here. A developer who lands in this window
/// fixes the file and saves, and the save has to be what brings the app up —
/// not a keypress they have to know to press at a blank browser.
void main() {
  group('web initial compile failure', () {
    test(
      'a browser run whose first compile failed shows the app once fixed',
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
          original.contains('WEB_FIRST_'),
          isFalse,
          reason:
              'web_example lib/main.dart still carries an edit from an '
              'earlier run; restore it before running this test',
        );

        /// Replace [anchor] and prove the file changed.
        ///
        /// An anchor that matches nothing makes `replaceFirst` a copy, and every
        /// assertion downstream then holds against a tree nobody edited — a green
        /// run that asserts about the fixture rather than the tool.
        void rewrite(String replacement) {
          final edited = original.replaceFirst(anchor, replacement);
          if (edited == original) {
            fail(
              'the edit anchor matched nothing in ${appMain.path}, so this '
              'run would assert against an unchanged file: $anchor',
            );
          }
          appMain.writeAsStringSync(edited);
        }

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
        rewrite('const Text(WEB_FIRST_BROKEN)');

        // (1) The condition really happened, and what the caller is told about it
        // — which is the moment they decide whether the session is worth keeping.
        // `--machine` drops the human `text`, so `recoverable` is the field an
        // IDE or agent actually has; asserting the prose here would assert
        // nothing.
        final reported = await dt.waitForStderr(
          'initial_compile_failed',
          timeout: const Duration(minutes: 5),
        );
        expect(
          reported,
          contains('WEB_FIRST_BROKEN'),
          reason:
              'the compiler diagnostics have to reach the caller, or the '
              'failure names no cause: $reported',
        );
        expect(
          reported,
          contains('"recoverable":true'),
          reason: 'a session that will compile again has to say so: $reported',
        );

        // (2) The run is still alive and still launches a browser.
        await dt.waitForEvent(
          'app.started',
          timeout: const Duration(minutes: 5),
        );

        // (3) The session ANSWERS in that state, and answers about the right
        // thing. Asked explicitly rather than left to the watcher: the watcher
        // starts before web assembly, so it does see this edit and a reload is
        // already on its way. What is under test here is that the session
        // answers a command in this state, which is a different claim from the
        // watcher working — `web_watch_window_e2e_test.dart` makes the latter.
        //
        // A hot reload has nothing to be an increment of, so it must run the
        // restart — and say so, since `--machine` drops the prose and the answer
        // comes back under a verb the caller did not ask for.
        final refused = await dt.sendCommand(
          1,
          'app.hotReload',
          timeout: const Duration(minutes: 5),
        );
        expect(
          refused['result']?['succeeded'],
          isFalse,
          reason:
              'the tree is broken, so this must fail — what is under test '
              'is that it ANSWERS: ${refused['result']}',
        );
        expect(
          refused['result']?['error'],
          contains('WEB_FIRST_BROKEN'),
          reason:
              'the compiler diagnostics have to reach the caller: '
              '${refused['result']?['error']}',
        );
        expect(
          dt.stderrLines.any((l) => l.contains('reload_promoted_to_restart')),
          isTrue,
          reason: 'a reload answered as a restart has to say why',
        );

        // (4) The fix, delivered by a save. A marker of its own rather than the
        // original text: restoring `original` byte-for-byte would leave a passing
        // assertion that an attempt which never happened could also satisfy.
        final fixed = dt.events.length;
        rewrite("const Text('WEB_FIRST_RECOVERED')");

        final recovered = await dt.waitForEventWhere(
          'app.reloadResult',
          after: fixed,
          what: 'the watcher-driven attempt at the fix',
          timeout: const Duration(minutes: 5),
          test: (params) => params['result'] is Map,
        );
        final result = (recovered['params']!['result'] as Map)
            .cast<String, dynamic>();
        expect(
          result['succeeded'],
          isTrue,
          reason:
              'the attempt after the fix is the whole point, and it '
              'failed: $result',
        );

        // (5) The bar. Not "the tool answered": the browser rendering an app that
        // never existed until now, in a run that was never restarted from the
        // shell. Deliberately the first `app.*` command in this test — before the
        // fix there is no program on the page and so no agent extension to answer
        // one, which is exactly the state under test.
        await dt.waitForHttpControl(timeout: const Duration(minutes: 2));
        final appId = dt.appId;
        expect(appId, isNotNull);
        final shown = await dt.httpCommand('app.waitFor', {
          'appId': appId!,
          'text': 'WEB_FIRST_RECOVERED',
          'timeoutMs': '60000',
        });
        expect(
          shown['error'],
          isNull,
          reason: 'the browser must be showing the fix: ${shown['error']}',
        );

        await dt.sendCommand(2, 'daemon.shutdown');
      },
      timeout: const Timeout(Duration(minutes: 15)),
    );
  });
}
