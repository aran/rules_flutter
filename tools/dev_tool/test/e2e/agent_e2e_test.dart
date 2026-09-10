@Tags(['e2e'])
/// End-to-end test for the AI-agent extension surface.
///
/// Drives the full stack: launches `:hello_world_macos` via dev_tool, dumps
/// the widget tree to discover ValueKey'd widgets, exercises every
/// `app.*` command (tap, longPress, doubleTap, drag, scrollIntoView,
/// enterText, getText, getRect, waitFor, waitForAbsent, pageBack), and
/// confirms a pre/post screenshot byte-diff.
library;

import 'dart:io';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';

const _pngSignature = <int>[0x89, 0x50, 0x4E, 0x47];

void main() {
  group(
    'agent extensions e2e',
    () {
      test(
        'drives hello_world_macos through tap + enterText + getText',
        () async {
          final dt = await startDevTool(
            workspace: e2eWorkspace('hello_world'),
            target: ':hello_world_macos',
            device: 'macos',
          );

          await dt.waitForEvent('app.started');
          await dt.waitForHttpControl();
          final appId = dt.appId;
          expect(appId, isNotNull, reason: 'appId from app.start event');

          // The agent extensions register on the very first frame (the
          // wrapper main calls WidgetsFlutterBinding.ensureInitialized →
          // registerExtension → user main → runApp). Wait for the keyed
          // button to be in the tree before any inspection — that proves
          // the wrapper executed and the user's tree is built.
          final ready = await dt.httpCommand('app.waitFor', {
            'appId': appId!,
            'key': 'agent_test_button',
            'timeoutMs': '15000',
          });
          expect(
            ready['error'],
            isNull,
            reason: 'agent_test_button: ${ready['error']}',
          );

          final dump = await dt.httpCommand('app.dumpWidgetTree', {
            'appId': appId,
          });
          expect(
            dump['error'],
            isNull,
            reason: 'app.dumpWidgetTree should not error: ${dump['error']}',
          );
          expect(
            dump['result'].toString(),
            contains('agent_test_button'),
            reason:
                'widget tree dump should contain ValueKey agent_test_button',
          );

          var label = await dt.httpCommand('app.getText', {
            'appId': appId,
            'key': 'agent_test_label',
          });
          expect(
            label['error'],
            isNull,
            reason: 'app.getText (label, t0): ${label['error']}',
          );
          expect(
            label['result']?['text'],
            'count: 0',
            reason: 'agent_test_label should start at "count: 0"',
          );

          final beforePath =
              '${Directory.systemTemp.path}/agent_e2e_before.png';
          await dt.httpScreenshotToFile(appId, beforePath);
          final beforeBytes = File(beforePath).readAsBytesSync();
          expect(beforeBytes.sublist(0, 4), equals(_pngSignature));
          // Pixels, not byte count — see expectRendered.
          expectRendered(beforeBytes, what: 'the pre-tap agent screenshot');

          final tap = await dt.httpCommand('app.tap', {
            'appId': appId,
            'key': 'agent_test_button',
          });
          expect(
            tap['error'],
            isNull,
            reason: 'app.tap should not error: ${tap['error']}',
          );
          expect(
            tap['result']?['tappedAt'],
            isNotNull,
            reason: 'app.tap response should include tappedAt {x, y}',
          );

          label = await dt.httpCommand('app.getText', {
            'appId': appId,
            'key': 'agent_test_label',
          });
          expect(
            label['error'],
            isNull,
            reason: 'app.getText (label, t1): ${label['error']}',
          );
          expect(
            label['result']?['text'],
            'count: 1',
            reason: 'agent_test_label should be "count: 1" after one tap',
          );

          final focusTap = await dt.httpCommand('app.tap', {
            'appId': appId,
            'key': 'agent_test_field',
          });
          expect(
            focusTap['error'],
            isNull,
            reason: 'tap echo field: ${focusTap['error']}',
          );

          final enter = await dt.httpCommand('app.enterText', {
            'appId': appId,
            'text': 'agent says hi',
          });
          expect(
            enter['error'],
            isNull,
            reason: 'app.enterText: ${enter['error']}',
          );

          final echo = await dt.httpCommand('app.getText', {
            'appId': appId,
            'key': 'agent_test_echo',
          });
          expect(
            echo['error'],
            isNull,
            reason: 'app.getText (echo): ${echo['error']}',
          );
          expect(
            echo['result']?['text'],
            'echo: agent says hi',
            reason: 'echo label should reflect the entered text',
          );

          // getText reaches the whole subtree, not one level of it. The key
          // here is on the ElevatedButton — where an app author puts it — and
          // its label sits several elements below, so a one-level scan answers
          // "no Text widget under ValueKey(agent_test_button)" for a key
          // tap/waitFor/getRect all accept.
          final nested = await dt.httpCommand('app.getText', {
            'appId': appId,
            'key': 'agent_test_button',
          });
          expect(
            nested['error'],
            isNull,
            reason: 'getText on a container: ${nested['error']}',
          );
          expect(nested['result']?['text'], 'Increment (agent)');
          expect(
            nested['result']?['texts'],
            ['Increment (agent)'],
            reason: 'every match reports the full list, not just the first',
          );

          // enterText acts on its selector: no tap first, and the response
          // says which field it typed into.
          final typed = await dt.httpCommand('app.enterText', {
            'appId': appId,
            'key': 'agent_test_field',
            'text': 'selected without tapping',
          });
          expect(
            typed['error'],
            isNull,
            reason: 'app.enterText by key: ${typed['error']}',
          );
          expect(typed['result']?['into'], 'ValueKey(agent_test_field)');
          final typedEcho = await dt.httpCommand('app.getText', {
            'appId': appId,
            'key': 'agent_test_echo',
          });
          expect(
            typedEcho['result']?['text'],
            'echo: selected without tapping',
          );

          // A selector that matches something that is not a field says so,
          // naming the selector the caller passed.
          final notAField = await dt.httpCommand('app.enterText', {
            'appId': appId,
            'key': 'agent_test_label',
            'text': 'nowhere',
          });
          expect(
            notAField['error']?.toString(),
            contains(
              'no EditableText in the subtree of '
              'ValueKey(agent_test_label)',
            ),
          );

          final rect = await dt.httpCommand('app.getRect', {
            'appId': appId,
            'key': 'agent_test_button',
          });
          expect(rect['error'], isNull, reason: 'getRect: ${rect['error']}');
          final r = rect['result'] as Map<String, dynamic>;
          expect(r['width'], isA<num>());
          expect(r['height'], isA<num>());
          expect((r['width'] as num) > 0, isTrue);
          expect((r['height'] as num) > 0, isTrue);

          // Finder vocabulary (flutter_driver parity): resolve widgets by
          // text / type / tooltip / semanticsLabel, not just ValueKey.
          final byText = await dt.httpCommand('app.getRect', {
            'appId': appId,
            'text': 'Increment (agent)',
          });
          expect(
            byText['error'],
            isNull,
            reason: 'getRect by text: ${byText['error']}',
          );

          final byType = await dt.httpCommand('app.getRect', {
            'appId': appId,
            'type': 'FloatingActionButton',
          });
          expect(
            byType['error'],
            isNull,
            reason: 'getRect by type: ${byType['error']}',
          );

          final byTooltip = await dt.httpCommand('app.getRect', {
            'appId': appId,
            'tooltip': 'Increment',
          });
          expect(
            byTooltip['error'],
            isNull,
            reason: 'getRect by tooltip: ${byTooltip['error']}',
          );

          final bySemantics = await dt.httpCommand('app.getRect', {
            'appId': appId,
            'semanticsLabel': 'You have pushed the button this many times:',
          });
          expect(
            bySemantics['error'],
            isNull,
            reason: 'getRect by semanticsLabel: ${bySemantics['error']}',
          );

          // Selector validation: none and ambiguous both error clearly.
          final noSelector = await dt.httpCommand('app.getRect', {
            'appId': appId,
          });
          expect(
            noSelector['error']?.toString(),
            contains('missing selector'),
            reason: 'getRect with no selector should error clearly',
          );
          final ambiguous = await dt.httpCommand('app.getRect', {
            'appId': appId,
            'key': 'agent_test_button',
            'text': 'whatever',
          });
          expect(
            ambiguous['error']?.toString(),
            contains('ambiguous selector'),
            reason: 'getRect with two selectors should error clearly',
          );

          // tap-by-text actuates the same button as tap-by-key.
          final beforeByText = await dt.httpCommand('app.getText', {
            'appId': appId,
            'key': 'agent_test_label',
          });
          await dt.httpCommand('app.tap', {
            'appId': appId,
            'text': 'Increment (agent)',
          });
          final afterByText = await dt.httpCommand('app.getText', {
            'appId': appId,
            'key': 'agent_test_label',
          });
          expect(
            afterByText['result']?['text'],
            isNot(beforeByText['result']?['text']),
            reason: 'tap by text should change the counter label',
          );

          final wait = await dt.httpCommand('app.waitFor', {
            'appId': appId,
            'key': 'agent_test_button',
            'timeoutMs': '1000',
          });
          expect(wait['error'], isNull, reason: 'waitFor: ${wait['error']}');

          final waitAbs = await dt.httpCommand('app.waitForAbsent', {
            'appId': appId,
            'key': 'definitely_not_there',
            'timeoutMs': '1000',
          });
          expect(
            waitAbs['error'],
            isNull,
            reason: 'waitForAbsent: ${waitAbs['error']}',
          );

          await dt.httpCommand('app.longPress', {
            'appId': appId,
            'key': 'agent_gesture_box',
          });
          var gestures = await dt.httpCommand('app.getText', {
            'appId': appId,
            'key': 'agent_gesture_label',
          });
          expect(
            gestures['result']?['text'],
            'gestures: lp=1 dt=0',
            reason: 'longPress should increment lp',
          );

          await dt.httpCommand('app.doubleTap', {
            'appId': appId,
            'key': 'agent_gesture_box',
          });
          gestures = await dt.httpCommand('app.getText', {
            'appId': appId,
            'key': 'agent_gesture_label',
          });
          expect(
            gestures['result']?['text'],
            'gestures: lp=1 dt=1',
            reason: 'doubleTap should increment dt',
          );

          // Pre-state: ListView shows items 0..3; item 30 is offscreen.
          // After scrollIntoView, item 30's rect must lie within the list's
          // visible bounds.
          final listRect = await dt.httpCommand('app.getRect', {
            'appId': appId,
            'key': 'agent_test_list',
          });
          final listTop = (listRect['result'] as Map)['y'] as num;
          final listBottom =
              listTop + ((listRect['result'] as Map)['height'] as num);

          await dt.httpCommand('app.scrollIntoView', {
            'appId': appId,
            'key': 'agent_test_list_item_30',
            'scrollableKey': 'agent_test_list',
            'dy': '-60',
          });
          final item30 = await dt.httpCommand('app.getRect', {
            'appId': appId,
            'key': 'agent_test_list_item_30',
          });
          expect(
            item30['error'],
            isNull,
            reason:
                'after scrollIntoView, item 30 must exist: '
                '${item30['error']}',
          );
          final item30y = (item30['result'] as Map)['y'] as num;
          expect(
            item30y >= listTop && item30y <= listBottom,
            isTrue,
            reason:
                'item 30 should be inside the list bounds '
                '$listTop..$listBottom (got y=$item30y)',
          );

          final preDragItem = await dt.httpCommand('app.getRect', {
            'appId': appId,
            'key': 'agent_test_list_item_30',
          });
          final preY = (preDragItem['result'] as Map)['y'] as num;
          await dt.httpCommand('app.drag', {
            'appId': appId,
            'key': 'agent_test_list',
            'dx': '0',
            'dy': '-50',
            'durationMs': '200',
          });
          final postDragItem = await dt.httpCommand('app.getRect', {
            'appId': appId,
            'key': 'agent_test_list_item_30',
          });
          // Item 30 may scroll off-screen entirely (getRect errors) or just
          // shift y — either is evidence the drag took effect.
          if (postDragItem['error'] == null) {
            final postY = (postDragItem['result'] as Map)['y'] as num;
            expect(
              postY != preY,
              isTrue,
              reason:
                  'drag should change the list scroll: pre=$preY post=$postY',
            );
          }

          await dt.httpCommand('app.tap', {
            'appId': appId,
            'key': 'agent_nav_button',
          });
          final detailReady = await dt.httpCommand('app.waitFor', {
            'appId': appId,
            'key': 'agent_nav_detail',
            'timeoutMs': '5000',
          });
          expect(
            detailReady['error'],
            isNull,
            reason: 'detail page should appear: ${detailReady['error']}',
          );
          final detail = await dt.httpCommand('app.getText', {
            'appId': appId,
            'key': 'agent_nav_detail',
          });
          expect(detail['result']?['text'], 'detail page');

          final back = await dt.httpCommand('app.pageBack', {
            'appId': appId,
          });
          expect(back['error'], isNull, reason: 'pageBack: ${back['error']}');
          expect(
            back['result']?['popped'],
            isTrue,
            reason: 'pageBack should pop the route',
          );
          final detailGone = await dt.httpCommand('app.waitForAbsent', {
            'appId': appId,
            'key': 'agent_nav_detail',
            'timeoutMs': '5000',
          });
          expect(
            detailGone['error'],
            isNull,
            reason:
                'detail page should disappear after pageBack: '
                '${detailGone['error']}',
          );

          final afterPath = '${Directory.systemTemp.path}/agent_e2e_after.png';
          await dt.httpScreenshotToFile(appId, afterPath);
          final afterBytes = File(afterPath).readAsBytesSync();
          expect(afterBytes.sublist(0, 4), equals(_pngSignature));
          expect(
            afterBytes,
            isNot(equals(beforeBytes)),
            reason: 'screenshot should change after tap + enterText',
          );

          File(beforePath).deleteSync();
          File(afterPath).deleteSync();

          // The agent surface must survive a hot restart. The extensions are
          // registered by the engine's pre-main plugin-registrant hook, which
          // fires on every root-isolate launch — including the restarted
          // (dev-tool-compiled) dill. Registration from a build-generated
          // wrapper main would not: the restart dill lacks it, and every
          // ext.rules_flutter.* call would answer "Unknown method".
          final restart = await dt.sendCommand(
            9,
            'app.restart',
            params: {
              'appId': appId,
            },
          );
          expect(
            restart['error'],
            isNull,
            reason: 'app.restart: ${restart['error']}',
          );
          // Asked once, with no poll loop: the command waits for the extension
          // to be registered on the restarted isolate, so a retry here would
          // only hide a gap in that wait.
          final postRestart = await dt.httpCommand('app.getText', {
            'appId': appId,
            'key': 'agent_test_label',
          });
          expect(
            postRestart['error'],
            isNull,
            reason:
                'app.getText must work after hot restart: '
                '${postRestart['error']}',
          );
          expect(
            postRestart['result']?['text'],
            'count: 0',
            reason: 'restart resets the counter state',
          );
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );

      // An agent driving an app whose window is not visible must still get an
      // answer. No assertion below depends on whether the embedder keeps
      // producing frames while minimized: a minimized window exercises the
      // occlusion path through AppKit, `app.tap` must return within a bound,
      // and the tap must actually be delivered.
      //
      // Keep "occluded" in the name — `docs/TESTING.md` and `tool/e2e.dart`
      // both use `--plain-name="occluded"` as their worked example, and a
      // rename would silently select nothing.
      test(
        'app.tap does not hang when the window is occluded',
        () async {
          final dt = await startDevTool(
            workspace: e2eWorkspace('hello_world'),
            target: ':hello_world_macos',
            device: 'macos',
          );
          await dt.waitForEvent('app.started');
          await dt.waitForHttpControl();
          final appId = dt.appId!;
          await dt.httpCommand('app.waitFor', {
            'appId': appId,
            'key': 'agent_test_button',
            'timeoutMs': '15000',
          });

          // Minimize the app window: the state an agent finds an app in when a
          // human has put it away. Needs OS-level window control, which macOS
          // gates behind permissions granted to the process running the tests;
          // skip when they are missing, since without them the app never
          // reaches the state under test. `_setMinimized` has already put the
          // specific reason on stderr.
          if (!await _setMinimized(true)) {
            markTestSkipped(
              'could not minimize the window — see the '
              '"agent_e2e: could not set AXMinimized" line on stderr for '
              'whether osascript refused (grant Accessibility) or never '
              'answered (grant Automation)',
            );
            return;
          }

          try {
            // Read-only finders work against a window nobody can see: they walk
            // the element tree, which a minimized window still has.
            final rect = await dt.httpCommand('app.getRect', {
              'appId': appId,
              'key': 'agent_test_button',
            });
            expect(
              rect['error'],
              isNull,
              reason: 'getRect should work while occluded: ${rect['error']}',
            );

            // The guard: the interaction must RETURN. Whichever way `_settle`
            // goes — the ordinary wait-for-frame, a short-circuit if
            // `framesEnabled` goes false, or its bounded timeout — all three
            // are non-hangs, and the bound below admits all three without
            // asserting which one ran. An unbounded await anywhere in that path
            // blocks until the test timeout instead.
            final sw = Stopwatch()..start();
            final tap = await dt.httpCommand('app.tap', {
              'appId': appId,
              'key': 'agent_test_button',
              'timeoutMs': '2000',
            });
            sw.stop();
            expect(
              sw.elapsed,
              lessThan(const Duration(seconds: 10)),
              reason: 'app.tap must not hang while the window is occluded',
            );
            expect(tap, isNotNull, reason: 'app.tap must return a response');
          } finally {
            await _setMinimized(false);
          }

          // The tap was really delivered, not merely acknowledged: `onPressed`
          // fires synchronously on the pointer event, so the counter is already
          // 1 in state, and the restored window's next frame shows it. This is
          // the half that keeps the assertion above from passing on a `app.tap`
          // that returned promptly by doing nothing. Poll to absorb the
          // post-restore frame latency.
          String? labelText;
          final deadline = DateTime.now().add(const Duration(seconds: 5));
          while (DateTime.now().isBefore(deadline)) {
            final label = await dt.httpCommand('app.getText', {
              'appId': appId,
              'key': 'agent_test_label',
            });
            labelText = label['result']?['text'] as String?;
            if (labelText == 'count: 1') break;
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          expect(
            labelText,
            'count: 1',
            reason:
                'the occluded tap should have incremented the counter — '
                'a prompt return with no input delivered is not a pass',
          );
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );

      /// `app.buildInfo` is how an attaching dev tool learns which build tree
      /// backs the process it just connected to. Everything here is baked at
      /// analysis time by `flutter_compile_kernel`, so this asserts the two
      /// ends agree: the rule composed the fields, and the extension serves
      /// them back unchanged.
      test(
        'reports the build configuration the rules baked in',
        () async {
          final dt = await startDevTool(
            workspace: e2eWorkspace('hello_world'),
            target: ':hello_world_macos',
            device: 'macos',
          );

          await dt.waitForEvent('app.started');
          await dt.waitForHttpControl();
          final appId = dt.appId;
          expect(appId, isNotNull, reason: 'appId from app.start event');

          final info = await dt.httpCommand('app.buildInfo', {
            'appId': appId!,
          });
          expect(
            info['error'],
            isNull,
            reason: 'app.buildInfo should not error: ${info['error']}',
          );
          final built = info['result'] as Map<String, dynamic>?;
          expect(built, isNotNull, reason: 'app.buildInfo payload: $info');

          expect(
            built!['compilationMode'],
            'dbg',
            reason: 'a dev run is a -c dbg build',
          );
          // The inner `flutter_application` the `flutter_macos_application`
          // macro generates — NOT the `:hello_world_macos` wrapper that was
          // launched. That is the point: the dev tool cqueries
          // `kind("flutter_application", deps(<wrapper>))` and cross-checks
          // the configured result against this, so a wrong `-t` is caught by
          // name rather than by rebuilding into someone else's tree.
          expect(built['label'], '@@//:hello_world_app');

          // Desktop wrappers add no flags — the app is already in the
          // top-level configuration. Mirrors `MacOSDevice.buildArgs`.
          expect(built['platformBuildArgs'], isEmpty);

          // The assets tree the app was actually built from. It must be an
          // exec-root-relative bazel-out path, because that is the form the
          // dev tool compares against `bazel cquery --output=files`.
          final assetsDir = built['assetsDir'];
          expect(assetsDir, isA<String>());
          expect(assetsDir as String, startsWith('bazel-out/'));
          expect(assetsDir, endsWith('_flutter_assets'));
          expect(
            Directory('${e2eWorkspace('hello_world')}/$assetsDir').existsSync(),
            isTrue,
            reason:
                'the reported assetsDir should resolve to a real tree '
                'under the workspace the run built in: $assetsDir',
          );

          // The record has to survive a hot restart. `flutter_compile_kernel`
          // bakes the define into the launch build, but a restart runs a dill
          // the dev tool's own frontend_server produced, and the resident
          // compiler does not replay the launch build's defines — so unless the
          // dev tool re-injects the app's record on its own compiler, this read
          // comes back as the agent's "carries no record" error. Nothing else
          // re-reads it mid-session, so this is the only place that would
          // notice.
          final restart = await dt.sendCommand(
            9,
            'app.restart',
            params: {
              'appId': appId,
            },
          );
          expect(
            restart['error'],
            isNull,
            reason: 'app.restart: ${restart['error']}',
          );

          final after = await dt.httpCommand('app.buildInfo', {
            'appId': appId,
          });
          expect(
            after['error'],
            isNull,
            reason:
                'app.buildInfo must still answer after a hot restart: '
                '${after['error']}',
          );
          // Deep equality on the parsed records, not on the JSON text: Starlark
          // `json.encode` and Dart `jsonEncode` are not required to agree byte
          // for byte, and it is the record that has to be the same one.
          expect(
            after['result'],
            equals(built),
            reason:
                'the restarted app must describe the same build it did '
                'before: was $built, now ${after['result']}',
          );
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );

      // An app that never goes idle must still be drivable. Every command waits
      // for the app to settle so a follow-up read observes the action, and a
      // perpetual `AnimationController` — a spinner, a progress indicator, a
      // hand-rolled caret — holds a transient frame callback for as long as it
      // runs, so without a way out every `app.*` call spends its whole
      // `timeoutMs` and fails from the second command onward.
      //
      // `E2E_NEVER_SETTLES` puts a `CircularProgressIndicator` on screen, which
      // is that state exactly.
      test(
        'an app that never goes idle says so, and can still be driven',
        () async {
          final dt = await startDevTool(
            workspace: e2eWorkspace('hello_world'),
            target: ':hello_world_macos',
            device: 'macos',
            extraArgs: ['--dart-define', 'E2E_NEVER_SETTLES=true'],
          );

          await dt.waitForEvent('app.started');
          await dt.waitForHttpControl();
          final appId = dt.appId!;
          // `settle: false` on the readiness wait too: this app never settles,
          // so the wait that proves the tree is built cannot settle either.
          final ready = await dt.httpCommand('app.waitFor', {
            'appId': appId,
            'key': 'agent_never_settles',
            'timeoutMs': '15000',
            'settle': 'false',
          });
          expect(ready['error'], isNull, reason: 'waitFor: ${ready['error']}');

          Future<String?> label() async =>
              (await dt.httpCommand('app.getText', {
                    'appId': appId,
                    'key': 'agent_test_label',
                    'settle': 'false',
                  }))['result']?['text']
                  as String?;

          expect(await label(), 'count: 0');

          // The default path still refuses — the guarantee is real and this
          // app cannot give it — but the refusal names the count, which is
          // what separates "something is animating" from "the app was
          // backgrounded and no frame came", and names the way out.
          final timedOut = await dt.httpCommand('app.tap', {
            'appId': appId,
            'key': 'agent_test_button',
            'timeoutMs': '3000',
          });
          expect(
            timedOut['error'],
            allOf(
              contains('still in flight'),
              contains('"settle": "false"'),
            ),
            reason: 'timeout must name what it waited on: ${timedOut['error']}',
          );

          // The refusal is about the *wait*, not the action: the input was
          // dispatched before it. A caller that retried on this error would
          // tap twice, so the error has to be read as "I cannot promise the
          // result is observable yet", never as "nothing happened".
          expect(
            await label(),
            'count: 1',
            reason: 'a settle that timed out must not un-tap the button',
          );

          // And the way out works. flutter_driver calls this
          // `runUnsynchronized`.
          final tap = await dt.httpCommand('app.tap', {
            'appId': appId,
            'key': 'agent_test_button',
            'settle': 'false',
          });
          expect(tap['error'], isNull, reason: 'tap: ${tap['error']}');

          // Read back through `app.waitFor`, not a bare `getText`. Skipping
          // the settle gives up the one thing it guarantees — that the frame
          // carrying the result has rendered before the response returns — so
          // an immediate read races the rebuild and sees `count: 1` about as
          // often as not. Waiting for the value is how a caller resynchronises,
          // and this is the workflow the timeout's own message sends them to.
          final settled = await dt.httpCommand('app.waitFor', {
            'appId': appId,
            'text': 'count: 2',
            'timeoutMs': '10000',
            'settle': 'false',
          });
          expect(
            settled['error'],
            isNull,
            reason:
                'the unsynchronised tap must still have landed: '
                '${settled['error']} (label reads ${await label()})',
          );

          // A value that is neither is refused rather than read as one of
          // them: a typo here picks the opposite behaviour.
          final typo = await dt.httpCommand('app.tap', {
            'appId': appId,
            'key': 'agent_test_button',
            'settle': 'flase',
          });
          expect(
            typo['error'],
            contains('settle must be "true" or "false"'),
          );

          await dt.sendCommand(1, 'daemon.shutdown');
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );

      // Being in the tree is not being reachable. A child of a scroll view
      // that is scrolled past is laid out at coordinates outside the viewport;
      // a `ValueKey` still finds it and it still has a rect, so a dispatch at
      // that rect's centre answers `{"tappedAt": …}` having hit nothing at all.
      // A success for an event nobody received is the worst answer this surface
      // can give.
      //
      // `E2E_CLIPPED_TOOLBAR` puts eight buttons in a 200px-wide horizontal
      // scroll view, so the last one sits past the right edge of the window.
      test(
        'a tap that would reach nothing is refused, not reported as done',
        () async {
          final dt = await startDevTool(
            workspace: e2eWorkspace('hello_world'),
            target: ':hello_world_macos',
            device: 'macos',
            extraArgs: ['--dart-define', 'E2E_CLIPPED_TOOLBAR=true'],
          );

          await dt.waitForEvent('app.started');
          await dt.waitForHttpControl();
          final appId = dt.appId!;
          final ready = await dt.httpCommand('app.waitFor', {
            'appId': appId,
            'key': 'toolbar_0',
            'timeoutMs': '15000',
          });
          expect(ready['error'], isNull, reason: 'waitFor: ${ready['error']}');

          Future<String?> label() async =>
              (await dt.httpCommand('app.getText', {
                    'appId': appId,
                    'key': 'agent_test_label',
                  }))['result']?['text']
                  as String?;

          // The one on screen taps normally.
          final near = await dt.httpCommand('app.tap', {
            'appId': appId,
            'key': 'toolbar_0',
          });
          expect(near['error'], isNull, reason: 'near tap: ${near['error']}');
          expect(await label(), 'count: 1');

          // The clipped one is refused — and the refusal says which of the two
          // reasons it is, because "off-screen" and "something is on top of
          // it" send the caller somewhere different.
          final far = await dt.httpCommand('app.tap', {
            'appId': appId,
            'key': 'toolbar_7',
          });
          expect(
            far['error'],
            allOf(
              contains('does not reach it'),
              contains('outside the view'),
              contains('app.scrollIntoView'),
            ),
            reason: 'far tap: ${far['error']}',
          );

          // The other branch: on screen, and covered. A reported coordinate
          // that lands in a different pane is this case, not the off-screen
          // one, and it wants a different remedy — telling someone to scroll a
          // widget already in view sends them nowhere.
          final covered = await dt.httpCommand('app.tap', {
            'appId': appId,
            'key': 'covered_button',
          });
          expect(
            covered['error'],
            allOf(
              contains('something else is on top of it'),
              contains('Dismiss or move whatever covers it'),
              isNot(contains('app.scrollIntoView')),
            ),
            reason: 'covered tap: ${covered['error']}',
          );
          expect(
            await label(),
            'count: 1',
            reason: 'a refused tap must not have been dispatched',
          );
          expect(
            await label(),
            'count: 1',
            reason: 'a refused tap must not have been dispatched',
          );

          // And the way through is the one the message names. `reachable`
          // answers the question `iterations` could not: a caller reading
          // `iterations: 0` as "nothing to do" has misread a scroll that
          // happened.
          final scrolled = await dt.httpCommand('app.scrollIntoView', {
            'appId': appId,
            'key': 'toolbar_7',
          });
          expect(
            scrolled['error'],
            isNull,
            reason: 'scrollIntoView: ${scrolled['error']}',
          );
          expect(scrolled['result']?['reachable'], isTrue);

          final afterScroll = await dt.httpCommand('app.tap', {
            'appId': appId,
            'key': 'toolbar_7',
          });
          expect(
            afterScroll['error'],
            isNull,
            reason: 'tap after scroll: ${afterScroll['error']}',
          );
          expect(await label(), 'count: 2');

          // The escape hatch still dispatches, for a caller who means it —
          // upstream's `warnIfMissed: false`, made explicit rather than
          // silent. The tap lands nowhere, which is the point.
          await dt.httpCommand('app.scrollIntoView', {
            'appId': appId,
            'key': 'toolbar_0',
          });
          final forced = await dt.httpCommand('app.tap', {
            'appId': appId,
            'key': 'toolbar_7',
            'requireHit': 'false',
          });
          expect(
            forced['error'],
            isNull,
            reason: 'requireHit=false: ${forced['error']}',
          );
          expect(
            await label(),
            'count: 2',
            reason: 'the forced tap reached nothing, as asked',
          );

          await dt.sendCommand(1, 'daemon.shutdown');
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );

      // A capture is a moment, and the moment a driver wants is the one after
      // its last command painted. An endpoint that does not wait hands back the
      // frame from before the `app.tap` that preceded it, and a stale picture
      // reads exactly like a feature that did not work.
      test(
        'a screenshot shows the command that came before it',
        () async {
          final dt = await startDevTool(
            workspace: e2eWorkspace('hello_world'),
            target: ':hello_world_macos',
            device: 'macos',
          );

          await dt.waitForEvent('app.started');
          await dt.waitForHttpControl();
          final appId = dt.appId!;
          final ready = await dt.httpCommand('app.waitFor', {
            'appId': appId,
            'key': 'agent_test_button',
            'timeoutMs': '15000',
          });
          expect(ready['error'], isNull, reason: 'waitFor: ${ready['error']}');

          // The wait is a command of its own, because a caller sometimes needs
          // it between two of theirs.
          final settleCmd = await dt.httpCommand('app.settle', {
            'appId': appId,
          });
          expect(settleCmd['result']?['settled'], isTrue);

          // Polled rather than taken once: ScreenCaptureKit cannot enumerate
          // the window until it is on screen, and nothing announces that.
          await dt.nativeScreenshotWhenOnScreen(appId);
          final before = await dt.httpNativeScreenshotReply(appId);
          expect(before.settled, 'yes');

          final tap = await dt.httpCommand('app.tap', {
            'appId': appId,
            'key': 'agent_test_button',
          });
          expect(tap['error'], isNull, reason: 'tap: ${tap['error']}');

          // Immediately, with no settle of the test's own — that is the
          // endpoint's job. The counter is the only thing on this screen that
          // moves, so an identical image means the capture predates the tap.
          final after = await dt.httpNativeScreenshotReply(appId);
          expect(after.settled, 'yes');
          expect(
            after.bytes,
            isNot(equals(before.bytes)),
            reason:
                'the capture must include the tap that preceded it; identical '
                'bytes mean it returned the frame from before',
          );

          // Opting out says so rather than quietly doing it, because "I did
          // not wait" is the difference between a picture and evidence.
          final unsettled = await dt.httpNativeScreenshotReply(
            appId,
            settle: false,
          );
          expect(unsettled.settled, 'skipped');
          expect(unsettled.detail, contains('asked not to wait'));

          await dt.sendCommand(1, 'daemon.shutdown');
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );
    },
    skip: !Platform.isMacOS ? 'macOS only' : null,
  );

  /// The same surface on `-d chrome`.
  ///
  /// It arrives by a different road. Native compiles the agent into the app's
  /// kernel and lets the engine's pre-main plugin-registrant hook call it; the
  /// web bundle cannot, because dart2wasm/dart2js stub out `registerExtension`
  /// entirely. So the build stages the source and the dev tool's synthetic
  /// entrypoint registers it on the way in, before `bootstrapEngine`.
  ///
  /// The timing is the part worth guarding. DWDS rewrites the bootstrap's
  /// `child.main()` into `window.$dartRunMain`, so no app Dart code runs until
  /// its injected client connects — seconds after `app.started`. Every command
  /// below is issued the moment the run says it is up, which is exactly when an
  /// agent would issue it, and is the window in which no extension is
  /// registered yet.
  group('agent extensions e2e (web)', () {
    test(
      'drives a -d chrome run through getText, tap and restart',
      () async {
        final dt = await startDevTool(
          workspace: e2eWorkspace('web_example'),
          // `:app_wasm` and not `:app_js`: the latter carries a `base_href` the
          // dev server does not serve from, so the page never reaches DWDS.
          target: ':app_wasm',
          device: 'chrome',
        );

        await dt.waitForEvent(
          'app.start',
          timeout: const Duration(seconds: 240),
        );
        final appId = dt.appId!;
        await dt.waitForHttpControl(timeout: const Duration(seconds: 120));

        // Deliberately not waiting for `dwds_vm_service` first: the point is that
        // a command issued into the startup window waits the window out instead
        // of failing, so the only barrier here is the control channel itself.
        // This first command therefore covers the whole window — no VM service
        // yet, then no extensions, then no widget tree — in one call. It waits on
        // the label's *text* rather than its key: the key is in the tree from the
        // first build, while the text arrives with the asset the `FutureBuilder`
        // is still loading.
        final ready = await dt.httpCommand('app.waitFor', {
          'appId': appId,
          'text': 'web asset v1',
          'timeoutMs': '30000',
        });
        expect(
          ready['error'],
          isNull,
          reason: 'app.waitFor at t=0 on web: ${ready['error']}',
        );

        final label = await dt.httpCommand('app.getText', {
          'appId': appId,
          'key': 'e2e_asset_label',
        });
        expect(
          label['error'],
          isNull,
          reason: 'app.getText on web: ${label['error']}',
        );
        expect(
          label['result']?['text'],
          'web asset v1',
          reason: 'the whole response: $label',
        );

        // The framework's own extensions are in the same window, and
        // dumpWidgetTree is the one agent command that goes to an inspector RPC
        // rather than `ext.rules_flutter.*`.
        final dump = await dt.httpCommand('app.dumpWidgetTree', {
          'appId': appId,
        });
        expect(
          dump['error'],
          isNull,
          reason: 'app.dumpWidgetTree on web: ${dump['error']}',
        );
        expect(dump['result'].toString(), contains('e2e_asset_label'));

        // A gesture, so the surface is exercised for more than reads. The
        // counter has no key of its own; the FAB is addressable by tooltip.
        final tap = await dt.httpCommand('app.tap', {
          'appId': appId,
          'tooltip': 'Increment',
        });
        expect(tap['error'], isNull, reason: 'app.tap on web: ${tap['error']}');
        final counted = await dt.httpCommand('app.getText', {
          'appId': appId,
          'type': 'Scaffold',
        });
        expect(
          counted['result']?['texts'],
          contains('1'),
          reason: 'the tap should have incremented the counter',
        );

        // A restart reopens the window: DDC's `hotRestart` resets the SDK's lazy
        // `_extensions` map, so the regenerated entrypoint has to register again
        // — against an isolate with a new id. Both halves are covered by asking
        // straight afterwards, with no poll loop to hide a gap.
        final restart = await dt.sendCommand(
          9,
          'app.restart',
          params: {'appId': appId},
        );
        expect(
          restart['error'],
          isNull,
          reason: 'app.restart on web: ${restart['error']}',
        );

        final rebuilt = await dt.httpCommand('app.waitFor', {
          'appId': appId,
          'text': 'web asset v1',
          'timeoutMs': '30000',
        });
        expect(
          rebuilt['error'],
          isNull,
          reason: 'app.waitFor after a web restart: ${rebuilt['error']}',
        );

        final postRestart = await dt.httpCommand('app.getText', {
          'appId': appId,
          'key': 'e2e_asset_label',
        });
        expect(
          postRestart['error'],
          isNull,
          reason: 'app.getText after a web restart: ${postRestart['error']}',
        );
        expect(postRestart['result']?['text'], 'web asset v1');
      },
      timeout: const Timeout(Duration(minutes: 6)),
    );
  });
}

/// How long the window-control AppleScript gets to answer.
///
/// Setting one attribute on one window is sub-second work when the permissions
/// are in place — this is a bound on the *unanswerable* case, not an expected
/// wait, and a healthy call returns the moment it is done rather than sitting
/// out the bound.
const _osascriptBound = Duration(seconds: 10);

/// Minimize/restore the `:hello_world_macos` window (bundle `app_name`
/// "Hello World") via AppleScript.
///
/// Returns false when the window cannot be addressed, so callers can skip. Two
/// different things produce that answer and both must, because neither leaves
/// the test able to get the window off screen — the state it exists to drive:
///
///   * a refusal — no Accessibility permission for the invoking process, which
///     `osascript` reports promptly as `not allowed assistive access (-1719)`;
///   * silence — an undecided Automation (AppleEvents) TCC, where the send
///     blocks in the consent machinery and never returns at all.
///
/// The second is why this is bounded rather than a plain [Process.run]; see
/// [runBounded].
Future<bool> _setMinimized(bool value) async {
  final result = await runBounded(
    'osascript',
    [
      '-e',
      'tell application "System Events" to tell process "Hello World" '
          'to set value of attribute "AXMinimized" of window 1 to $value',
    ],
    timeout: _osascriptBound,
  );
  if (!result.succeeded) {
    // Named on stderr either way: a skip that says nothing hides a fixable
    // problem. `timed out` and `exit 1: …` are different diagnoses with
    // different fixes (grant Automation vs grant Accessibility).
    stderr.writeln('agent_e2e: could not set AXMinimized=$value — $result');
  }
  return result.succeeded;
}
