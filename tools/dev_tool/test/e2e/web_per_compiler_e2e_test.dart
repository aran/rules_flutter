@Tags(['e2e', 'web'])
/// A web app whose code differs by compiler runs the right program under each.
///
/// `//int64:int64_app` has one `lib/main.dart` and two `package:int64_ids`,
/// picked by the web compiler through a `select()`: an `Int64List` under
/// dart2wasm and a `List<int>` under dart2js and DDC. It keeps the dart2js
/// fallback, which it could not if both compilers were handed the `Int64List`.
/// What the page draws names the variant that is running.
///
/// The JavaScript build a browser falls back to is `:int64_app_js_fallback`,
/// the same program with Chrome left out of the WebAssembly allow-list.
library;

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';

/// The app under test.
const _app = E2eApp('web_example');

/// What the dart2wasm build draws: the largest signed 64-bit integer, read out
/// of an `Int64List`.
const _wasm = 'Int64List max: 9223372036854775807';

/// What the JavaScript builds draw: the largest integer JavaScript represents
/// exactly, read out of a `List<int>`.
const _js = 'List<int> max: 9007199254740991';

void main() {
  final workspace = _app.moduleRoot;

  test(
    '--wasm runs the dart2wasm program: the Int64List variant',
    () async {
      final dt = await startDevTool(
        workspace: workspace,
        target: '//int64:int64_app',
        device: 'chrome',
        extraArgs: const ['--wasm', '--web-run-headless'],
      );
      await dt.waitForEvent('app.started', timeout: const Duration(minutes: 8));
      await dt.waitForHttpControl();
      final tree = await _treeContaining(dt, dt.appId!, _wasm);
      expect(tree, contains(_wasm));
      expect(tree, isNot(contains(_js)));
      await dt.nativeScreenshotWhenOnScreen(dt.appId!);
      await dt.sendCommand(1, 'daemon.shutdown');
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );

  test(
    '--no-wasm runs the DDC program, which is dart2js\'s: the List<int> variant',
    () async {
      final dt = await startDevTool(
        workspace: workspace,
        target: '//int64:int64_app',
        device: 'chrome',
        extraArgs: const ['--no-wasm', '--web-run-headless'],
      );
      await dt.waitForEvent('app.started', timeout: const Duration(minutes: 8));
      await dt.waitForEvent(
        'app.debugPort',
        timeout: const Duration(minutes: 2),
      );
      await dt.waitForHttpControl();
      final tree = await _treeContaining(dt, dt.appId!, _js);
      expect(tree, contains(_js));
      expect(tree, isNot(contains(_wasm)));
      await dt.nativeScreenshotWhenOnScreen(dt.appId!);
      await dt.sendCommand(1, 'daemon.shutdown');
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );

  test(
    'the dart2js fallback bundle draws the List<int> variant',
    () async {
      final dt = await startDevTool(
        workspace: workspace,
        target: '//int64:int64_app_js_fallback',
        device: 'chrome',
        extraArgs: const ['--wasm', '--web-run-headless'],
      );
      await dt.waitForEvent('app.started', timeout: const Duration(minutes: 8));
      await dt.waitForHttpControl();
      final tree = await _treeContaining(dt, dt.appId!, _js);
      expect(tree, contains(_js));
      expect(tree, isNot(contains(_wasm)));
      await dt.nativeScreenshotWhenOnScreen(dt.appId!);
      await dt.sendCommand(1, 'daemon.shutdown');
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );
}

/// The widget tree once it holds [text], asked until it does.
Future<String> _treeContaining(
  DevToolProcess dt,
  String appId,
  String text,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  String last = '';
  while (DateTime.now().isBefore(deadline)) {
    final reply = await dt.httpCommand('app.dumpWidgetTree', {'appId': appId});
    last = reply['error']?.toString() ?? reply['result'].toString();
    if (last.contains(text)) return last;
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  fail('the widget tree never held "$text"; the last answer was: $last');
}
