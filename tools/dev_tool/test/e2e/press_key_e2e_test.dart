@Tags(['e2e'])
/// End-to-end test for `app.pressKey`, on both of its routes.
///
/// The browser route presses real keys in Chrome over the DevTools protocol;
/// the framework route, on native devices, pushes key events and the
/// platform's text-input messages through the app's own channels. Each case
/// types into a text field, deletes with Backspace, uses an editing key whose
/// action macOS only performs through a Cocoa command, and submits with Enter
/// — and checks what reached the field, not what was sent. The reply names
/// the route, and every case asserts it, so a pass on the framework route is
/// never read as coverage of real OS input.
///
/// The Chrome cases run headless. A key's effect only shows after the app
/// draws a frame, and a page in a hidden or covered window draws none —
/// measured on a Mac whose headed dev-tool Chrome reported
/// `visibilityState: hidden`: the keys landed and nothing repainted.
library;

import 'dart:io';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';

/// The fixture's submitted-text marker, `Color(0xFFFF00FF)`.
bool _isMarker(int r, int g, int b) => r > 240 && g < 20 && b > 240;

void main() {
  /// Press [key] and return the reply, failing on a refusal.
  Future<Map<String, dynamic>> press(
    DevToolProcess dt,
    String appId,
    String key, {
    required String route,
  }) async {
    final reply = await dt.httpCommand('app.pressKey', {
      'appId': appId,
      'key': key,
    });
    expect(reply['error'], isNull, reason: 'app.pressKey "$key": $reply');
    final result = reply['result'] as Map<String, dynamic>;
    expect(result['route'], route, reason: 'app.pressKey "$key": $result');
    expect(result['key'], key);
    return result;
  }

  Future<String?> textOf(DevToolProcess dt, String appId, String key) async {
    final reply = await dt.httpCommand('app.getText', {
      'appId': appId,
      'key': key,
    });
    expect(reply['error'], isNull, reason: 'app.getText $key: $reply');
    return reply['result']?['text'] as String?;
  }

  group('app.pressKey on macOS (framework route)', () {
    test(
      'types, deletes, moves the caret through Cocoa selectors, and submits',
      () async {
        final dt = await startDevTool(
          workspace: e2eWorkspace('hello_world'),
          target: ':hello_world_macos',
          device: 'macos',
        );
        await dt.waitForEvent('app.started');
        await dt.waitForHttpControl();
        final appId = dt.appId!;
        expect(dt.commands, contains('app.pressKey'));

        final ready = await dt.httpCommand('app.waitFor', {
          'appId': appId,
          'key': 'agent_test_field',
          'timeoutMs': '15000',
        });
        expect(ready['error'], isNull, reason: '$ready');

        // An unknown key is refused by name before anything is sent.
        final ctrl = await dt.httpCommand('app.pressKey', {
          'appId': appId,
          'key': 'Ctrl+K',
        });
        expect(ctrl['error'], contains('Unknown key "Ctrl"'));
        expect(ctrl['error'], contains('Did you mean "Control"?'));

        final tap = await dt.httpCommand('app.tap', {
          'appId': appId,
          'key': 'agent_test_field',
        });
        expect(tap['error'], isNull, reason: '$tap');

        for (final key in const ['a', 'b', 'c', 'd']) {
          final typed = await press(dt, appId, key, route: 'framework');
          expect(typed['textInput'], {'inserted': key});
        }
        // Backspace, ArrowLeft and ArrowDown are left unhandled by the
        // framework on macOS so the input method can have them; the reply
        // shows they went on as the selectors AppKit would send.
        final backspace = await press(
          dt,
          appId,
          'Backspace',
          route: 'framework',
        );
        expect(backspace['handled'], isFalse);
        expect(backspace['textInput'], {
          'selectors': ['deleteBackward:'],
        });
        for (var i = 0; i < 2; i++) {
          final left = await press(dt, appId, 'ArrowLeft', route: 'framework');
          expect(left['textInput'], {
            'selectors': ['moveLeft:'],
          });
        }
        await press(dt, appId, 'X', route: 'framework');
        final down = await press(dt, appId, 'ArrowDown', route: 'framework');
        expect(down['textInput'], {
          'selectors': ['moveDown:'],
        });
        await press(dt, appId, 'Y', route: 'framework');

        // "abcd", Backspace -> "abc", two lefts -> after "a", "X" -> "aXbc",
        // ArrowDown on the last line -> the end, "Y" -> "aXbcY". A caret
        // that did not move would give "abcXY".
        expect(await textOf(dt, appId, 'agent_test_echo'), 'echo: aXbcY');

        final enter = await press(dt, appId, 'Enter', route: 'framework');
        expect(enter['textInput'], {'action': 'TextInputAction.done'});
        expect(
          await textOf(dt, appId, 'agent_test_echo'),
          'echo: aXbcY | submitted: aXbcY',
          reason: 'Enter reaches onSubmitted',
        );

        // A shortcut the framework handles never reaches the input method.
        await dt.httpCommand('app.tap', {
          'appId': appId,
          'key': 'agent_test_field',
        });
        final selectAll = await press(dt, appId, 'Meta+A', route: 'framework');
        expect(selectAll['handled'], isTrue);
        await press(dt, appId, 'z', route: 'framework');
        expect(
          await textOf(dt, appId, 'agent_test_echo'),
          'echo: z | submitted: aXbcY',
          reason: 'Meta+A selected everything, and typing replaced it',
        );

        // The apostrophe, the one key whose physical and logical debug names
        // disagree: pairing them by name pressed ⌘" instead, and the app's
        // ⌘' shortcut (bound by `LogicalKeyboardKey.quoteSingle`) never fired.
        final quote = await press(dt, appId, 'Meta+Quote', route: 'framework');
        expect(quote['handled'], isTrue, reason: '$quote');
        expect(
          await textOf(dt, appId, 'agent_test_echo'),
          "echo: z | submitted: aXbcY | shortcut: ⌘'",
          reason:
              "Meta+Quote reaches a shortcut bound to ⌘', and types nothing",
        );

        // The echo line is a `Text.rich`. `getText` read it above; `waitFor`
        // by the same string has to find it too.
        final found = await dt.httpCommand('app.waitFor', {
          'appId': appId,
          'text': "echo: z | submitted: aXbcY | shortcut: ⌘'",
          'timeoutMs': '5000',
        });
        expect(found['error'], isNull, reason: 'waitFor a Text.rich: $found');

        await dt.sendCommand(1, 'daemon.shutdown');
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );
  }, skip: !Platform.isMacOS ? 'macOS only' : null);

  group('app.pressKey in Chrome (browser route)', () {
    test(
      'on the DDC dev loop: types, deletes, Control+K, Enter submits',
      () async {
        final dt = await startDevTool(
          workspace: e2eWorkspace('web_example'),
          target: ':app_wasm',
          device: 'chrome',
          extraArgs: const ['--web-run-headless'],
        );
        await dt.waitForEvent(
          'app.start',
          timeout: const Duration(seconds: 240),
        );
        final appId = dt.appId!;
        await dt.waitForHttpControl(timeout: const Duration(seconds: 120));
        final ready = await dt.httpCommand('app.waitFor', {
          'appId': appId,
          'key': 'keys_field',
          'timeoutMs': '30000',
        });
        expect(ready['error'], isNull, reason: '$ready');

        // Keys go to whatever has the browser's focus; with no field focused
        // the reply says the typed text reached nothing.
        final stray = await press(dt, appId, 'q', route: 'browser');
        expect(stray['warning'], contains('not in a text field'));
        expect(await textOf(dt, appId, 'keys_field'), '');

        // A framework tap focuses the field, and Flutter's web engine then
        // gives its <input> the browser's focus.
        final tap = await dt.httpCommand('app.tap', {
          'appId': appId,
          'key': 'keys_field',
        });
        expect(tap['error'], isNull, reason: '$tap');

        for (final key in const ['a', 'b', 'c', 'd', 'e']) {
          final typed = await press(dt, appId, key, route: 'browser');
          expect(typed['focus'], endsWith('input'), reason: '$typed');
          expect(typed['settled'], 'yes', reason: '$typed');
        }
        await press(dt, appId, 'Backspace', route: 'browser');
        await press(dt, appId, 'ArrowLeft', route: 'browser');
        await press(dt, appId, 'ArrowLeft', route: 'browser');
        final kill = await press(dt, appId, 'Control+K', route: 'browser');
        if (Platform.isMacOS) {
          // Without the Cocoa command a Mac browser deletes nothing.
          final keyDown = (kill['sent'] as List).firstWhere(
            (e) => (e as Map)['code'] == 'KeyK' && e['type'] != 'keyUp',
          );
          expect((keyDown as Map)['commands'], ['deleteToEndOfParagraph']);
        }
        // "abcde", Backspace -> "abcd", two lefts -> after "ab", Control+K
        // -> "ab". A missed Backspace gives "abc"; a caret that did not move,
        // or a Control+K that did nothing, gives "abcd".
        expect(await textOf(dt, appId, 'keys_field'), 'ab');

        await press(dt, appId, 'Enter', route: 'browser');
        expect(await textOf(dt, appId, 'keys_submitted'), 'submitted: ab');

        await dt.sendCommand(1, 'daemon.shutdown');
      },
      timeout: const Timeout(Duration(minutes: 6)),
    );

    test(
      'on --wasm, with no VM service: advertised, and read off a screenshot',
      () async {
        final dt = await startDevTool(
          workspace: e2eWorkspace('web_example'),
          target: ':app_wasm',
          device: 'chrome',
          extraArgs: const ['--wasm', '--web-run-headless'],
        );
        await dt.waitForEvent(
          'app.started',
          timeout: const Duration(minutes: 4),
        );
        final appId = dt.appId!;
        await dt.waitForHttpControl();

        // The one app.* command such a run has: the rest need a VM service.
        expect(dt.commands, contains('app.pressKey'));
        expect(dt.commands, isNot(contains('app.getText')));

        // Drawn before the first key, so Tab lands in the app rather than in
        // a page still loading. Polled for pixels, not for an answer: the
        // browser captures a page that has not painted as readily as one that
        // has, and a first run of this test raced exactly that.
        var before = await dt.nativeScreenshotWhenOnScreen(appId);
        final painted = DateTime.now().add(const Duration(seconds: 60));
        while (decodePngForBlankness(before).isUniform &&
            DateTime.now().isBefore(painted)) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          before = await dt.httpNativeScreenshot(appId);
        }
        expectRendered(before, what: 'the --wasm app before any key');
        expect(countColourRuns(before, _isMarker), 0);

        // Keyboard only — no coordinate click: Tab moves the framework's
        // focus into the field, and the engine's <input> takes the browser's.
        Map<String, dynamic>? probe;
        for (var i = 0; i < 5; i++) {
          await press(dt, appId, 'Tab', route: 'browser');
          // Shift alone types nothing; its reply says where focus is.
          probe = await press(dt, appId, 'Shift', route: 'browser');
          if ('${probe['focus']}'.endsWith('input')) break;
        }
        expect(probe?['focus'], endsWith('input'), reason: '$probe');

        for (final key in const [
          'a',
          'b',
          'c',
          'd',
          'e',
          'Backspace',
          'ArrowLeft',
          'ArrowLeft',
          'Control+K',
          'Enter',
        ]) {
          final result = await press(dt, appId, key, route: 'browser');
          expect(result['settled'], 'skipped', reason: '$result');
          expect(result['settleDetail'], contains('no VM service'));
        }

        // One marker square per submitted character: "ab" is two. A missed
        // Backspace submits "abc" (three); a Control+K or caret move that
        // did nothing submits "abcd" (four); no submit shows none.
        var squares = 0;
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (DateTime.now().isBefore(deadline)) {
          final shot = await dt.httpNativeScreenshot(appId);
          squares = countColourRuns(shot, _isMarker);
          if (squares == 2) break;
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        expect(
          squares,
          2,
          reason: 'the --wasm page should show "ab" submitted',
        );

        await dt.sendCommand(1, 'daemon.shutdown');
      },
      timeout: const Timeout(Duration(minutes: 6)),
    );
  });
}
