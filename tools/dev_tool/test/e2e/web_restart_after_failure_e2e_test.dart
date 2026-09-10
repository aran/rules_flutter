@Tags(['e2e'])
library;

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';
import 'editable_workspace.dart';

/// End-to-end: a browser session still restarts after a restart that failed.
///
/// A restart is `reset` + `recompile`, the pairing `flutter_tools` uses
/// (`devfs.dart`). A second `compile` will not do: **the `compile` verb's error
/// count is cumulative, and only `recompile` clears it**, so one failed restart
/// would be the last one that could ever succeed.
///
/// ## What each part is for
///
///  1. A clean restart first. It queues DWDS's expression probe behind the
///     failing compile that follows, which is the interleaving that reaches the
///     compiler's retained state.
///  2. The broken restart must fail **with the compiler's diagnostics in it**.
///     A bare failure would be satisfied by an error that names no cause.
///  3. The fixed restart must SUCCEED, and the page must be showing the fix.
///     This is the bar: not "the tool answered", but the browser rendering
///     source that was edited after the failure, in a session that was never
///     restarted from the shell.
///
/// `:app_wasm` is the `flutter_web_app` target, and with no `--wasm` flag it is
/// the DDC dev loop — `:app_js` carries a `base_href` the dev server does not
/// serve from, so its page never boots and DWDS never attaches (see
/// `asset_reload_e2e_test.dart`). No `--watch`: a watcher-driven `recompile`
/// clears the compiler's error list, which would mask what is under test.
void main() {
  group('web restart after failure e2e', () {
    test(
      'a browser session restarts again after a restart that failed',
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
          original.contains('WEB_RESTART_'),
          isFalse,
          reason:
              'web_example lib/main.dart still carries an edit from an '
              'earlier run; restore it before running this test',
        );

        /// Replace [anchor] and prove the file changed.
        ///
        /// An anchor that matches nothing makes `replaceFirst` a copy, and every
        /// assertion downstream then holds against a tree nobody edited — a green
        /// run that asserts about the fixture, not the tool. The check is here
        /// rather than at each call site so no edit can be added without it.
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
        );
        final start = await dt.waitForEvent(
          'app.start',
          timeout: const Duration(seconds: 300),
        );
        final appId = start['params']?['appId'] as String? ?? dt.appId!;
        await dt.waitForHttpControl(timeout: const Duration(seconds: 120));
        // `app.started` fires when Chrome launches; the page reaches DWDS later,
        // and nothing below can be asked of the app before it does.
        await dt.waitForStderr(
          'dwds_vm_service',
          timeout: const Duration(seconds: 180),
        );

        final baseline = await dt.httpCommand('app.waitFor', {
          'appId': appId,
          'text': 'You have pushed the button this many times:',
          'timeoutMs': '30000',
        });
        expect(
          baseline['error'],
          isNull,
          reason:
              'the page has to be rendering the app before any of this '
              'means anything: ${baseline['error']}',
        );

        // (1) A clean restart. Its own success is worth little; what it does is
        // put DWDS's expression probe in the queue behind the next compile.
        final clean = await dt.sendCommand(
          1,
          'app.restart',
          params: {'appId': appId},
          timeout: const Duration(minutes: 4),
        );
        expect(
          clean['result']?['succeeded'],
          isTrue,
          reason:
              'a restart of an unedited tree must succeed: '
              '${clean['result']}',
        );

        // (2) A restart of a tree that does not compile: a failure that names
        // the cause.
        rewrite('const Text(WEB_RESTART_BROKEN)');
        final broken = await dt.sendCommand(
          2,
          'app.restart',
          params: {'appId': appId},
          timeout: const Duration(minutes: 4),
        );
        expect(
          broken['result']?['succeeded'],
          isFalse,
          reason:
              'the tree does not compile, so this restart must fail: '
              '${broken['result']}',
        );
        expect(
          broken['result']?['error'],
          contains('WEB_RESTART_BROKEN'),
          reason:
              'the compiler diagnostics have to reach the caller, or the '
              'failure names no cause: ${broken['result']?['error']}',
        );

        // (3) The fix, and the bar. A marker of its own rather than the original
        // text: restoring `original` byte-for-byte would leave a passing
        // assertion that a restart which never happened could also satisfy.
        rewrite("const Text('WEB_RESTART_RECOVERED')");
        final fixed = await dt.sendCommand(
          3,
          'app.restart',
          params: {'appId': appId},
          timeout: const Duration(minutes: 4),
        );
        expect(
          fixed['result']?['succeeded'],
          isTrue,
          reason:
              'the restart after the fix is the whole point, and it '
              'failed: ${fixed['result']}',
        );

        final shown = await dt.httpCommand('app.waitFor', {
          'appId': appId,
          'text': 'WEB_RESTART_RECOVERED',
          'timeoutMs': '30000',
        });
        expect(
          shown['error'],
          isNull,
          reason:
              'the browser must be rendering the fix, not the code it '
              'booted with: ${shown['error']}',
        );

        await dt.sendCommand(4, 'daemon.shutdown');
      },
      timeout: const Timeout(Duration(minutes: 15)),
    );
  });
}
