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
const _minNonBlankBytes = 4 * 1024;

void main() {
  group(
    'agent extensions e2e',
    () {
      test('drives hello_world_macos through tap + enterText + getText',
          () async {
        final dt = await startDevTool(
          workspace: e2eWorkspace('hello_world'),
          target: ':hello_world_macos',
          device: 'macos',
        );

        try {
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
          expect(ready['error'], isNull,
              reason: 'agent_test_button: ${ready['error']}');

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
            reason: 'widget tree dump should contain ValueKey agent_test_button',
          );

          var label = await dt.httpCommand('app.getText', {
            'appId': appId,
            'key': 'agent_test_label',
          });
          expect(label['error'], isNull,
              reason: 'app.getText (label, t0): ${label['error']}');
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
          expect(beforeBytes.length, greaterThanOrEqualTo(_minNonBlankBytes));

          final tap = await dt.httpCommand('app.tap', {
            'appId': appId,
            'key': 'agent_test_button',
          });
          expect(tap['error'], isNull,
              reason: 'app.tap should not error: ${tap['error']}');
          expect(
            tap['result']?['tappedAt'],
            isNotNull,
            reason: 'app.tap response should include tappedAt {x, y}',
          );

          label = await dt.httpCommand('app.getText', {
            'appId': appId,
            'key': 'agent_test_label',
          });
          expect(label['error'], isNull,
              reason: 'app.getText (label, t1): ${label['error']}');
          expect(
            label['result']?['text'],
            'count: 1',
            reason: 'agent_test_label should be "count: 1" after one tap',
          );

          final focusTap = await dt.httpCommand('app.tap', {
            'appId': appId,
            'key': 'agent_test_field',
          });
          expect(focusTap['error'], isNull,
              reason: 'tap echo field: ${focusTap['error']}');

          final enter = await dt.httpCommand('app.enterText', {
            'appId': appId,
            'text': 'agent says hi',
          });
          expect(enter['error'], isNull,
              reason: 'app.enterText: ${enter['error']}');

          final echo = await dt.httpCommand('app.getText', {
            'appId': appId,
            'key': 'agent_test_echo',
          });
          expect(echo['error'], isNull,
              reason: 'app.getText (echo): ${echo['error']}');
          expect(
            echo['result']?['text'],
            'echo: agent says hi',
            reason: 'echo label should reflect the entered text',
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
          expect(waitAbs['error'], isNull,
              reason: 'waitForAbsent: ${waitAbs['error']}');

          await dt.httpCommand('app.longPress', {
            'appId': appId,
            'key': 'agent_gesture_box',
          });
          var gestures = await dt.httpCommand('app.getText', {
            'appId': appId,
            'key': 'agent_gesture_label',
          });
          expect(gestures['result']?['text'], 'gestures: lp=1 dt=0',
              reason: 'longPress should increment lp');

          await dt.httpCommand('app.doubleTap', {
            'appId': appId,
            'key': 'agent_gesture_box',
          });
          gestures = await dt.httpCommand('app.getText', {
            'appId': appId,
            'key': 'agent_gesture_label',
          });
          expect(gestures['result']?['text'], 'gestures: lp=1 dt=1',
              reason: 'doubleTap should increment dt');

          // Pre-state: ListView shows items 0..3; item 30 is offscreen.
          // After scrollIntoView, item 30's rect must lie within the list's
          // visible bounds.
          final listRect = await dt.httpCommand('app.getRect', {
            'appId': appId,
            'key': 'agent_test_list',
          });
          final listTop = (listRect['result'] as Map)['y'] as num;
          final listBottom = listTop + ((listRect['result'] as Map)['height'] as num);

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
          expect(item30['error'], isNull,
              reason: 'after scrollIntoView, item 30 must exist: '
                  '${item30['error']}');
          final item30y = (item30['result'] as Map)['y'] as num;
          expect(item30y >= listTop && item30y <= listBottom, isTrue,
              reason: 'item 30 should be inside the list bounds '
                  '$listTop..$listBottom (got y=$item30y)');

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
            expect(postY != preY, isTrue,
                reason: 'drag should change the list scroll: pre=$preY post=$postY');
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
          expect(detailReady['error'], isNull,
              reason: 'detail page should appear: ${detailReady['error']}');
          final detail = await dt.httpCommand('app.getText', {
            'appId': appId,
            'key': 'agent_nav_detail',
          });
          expect(detail['result']?['text'], 'detail page');

          final back = await dt.httpCommand('app.pageBack', {
            'appId': appId,
          });
          expect(back['error'], isNull,
              reason: 'pageBack: ${back['error']}');
          expect(back['result']?['popped'], isTrue,
              reason: 'pageBack should pop the route');
          final detailGone = await dt.httpCommand('app.waitForAbsent', {
            'appId': appId,
            'key': 'agent_nav_detail',
            'timeoutMs': '5000',
          });
          expect(detailGone['error'], isNull,
              reason: 'detail page should disappear after pageBack: '
                  '${detailGone['error']}');

          final afterPath = '${Directory.systemTemp.path}/agent_e2e_after.png';
          await dt.httpScreenshotToFile(appId, afterPath);
          final afterBytes = File(afterPath).readAsBytesSync();
          expect(afterBytes.sublist(0, 4), equals(_pngSignature));
          expect(afterBytes, isNot(equals(beforeBytes)),
              reason: 'screenshot should change after tap + enterText');

          File(beforePath).deleteSync();
          File(afterPath).deleteSync();
        } finally {
          await dt.dispose();
        }
      },
          timeout: const Timeout(Duration(minutes: 3)));
    },
    skip: !Platform.isMacOS ? 'macOS only' : null,
  );
}
