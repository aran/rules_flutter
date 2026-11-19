@Tags(['e2e', 'web'])
/// A web app that ships WebAssembly only (`js_fallback = False`) is developed
/// under dart2wasm, with no flag asked for.
///
/// `//int64/wasm_only:wasm_only_app` holds its numbers in an `Int64List`, which
/// only WebAssembly supports, and has no JavaScript variant of it, so it stands
/// for any app that cannot run as the JavaScript the DDC loop compiles. Under
/// the DDC loop it does not render; under the dart2wasm loop it does, which is
/// what separates the two here.
library;

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';

/// The app under test.
const _app = E2eApp('web_example');

/// What `wasm_only_app` draws: the largest signed 64-bit integer, read back out
/// of an `Int64List`.
const _rendered = 'Int64List max: 9223372036854775807';

void main() {
  final workspace = _app.moduleRoot;

  test(
    'with no flags, runs the dart2wasm loop, says so, and renders',
    () async {
      final dt = await startDevTool(
        workspace: workspace,
        target: '//int64/wasm_only:wasm_only_app',
        device: 'chrome',
        extraArgs: const ['--web-run-headless'],
      );

      // Said at startup, in the structured record a machine client reads.
      final said = await dt.waitForStderr(
        'wasm_only_target_runs_wasm',
        timeout: const Duration(minutes: 4),
      );
      expect(said, contains('no hot reload'));
      expect(said, contains('--no-wasm'));

      await dt.waitForEvent('app.started', timeout: const Duration(minutes: 6));

      // And the app is on screen: the page bridge answers, and the widget tree
      // holds the text only an `Int64List` can produce.
      final appId = dt.appId!;
      await dt.waitForHttpControl();
      final tree = await _treeContaining(dt, appId, _rendered);
      expect(tree, contains(_rendered));
      await dt.nativeScreenshotWhenOnScreen(appId);
      final shot = await dt.httpNativeScreenshotReply(appId);
      expect(shot.settled, 'yes', reason: shot.detail);

      // The dart2wasm loop leaves no VM service; the DDC loop's DWDS is what
      // announces one, so its absence is the loop, not an assumption about it.
      expect(
        dt.events.where((e) => e['event'] == 'app.debugPort'),
        isEmpty,
        reason: 'a DDC run announced a VM service',
      );

      await dt.sendCommand(1, 'daemon.shutdown');
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    '--no-wasm runs it under DDC anyway, and warns that it ships wasm only',
    () async {
      final dt = await startDevTool(
        workspace: workspace,
        target: '//int64/wasm_only:wasm_only_app',
        device: 'chrome',
        extraArgs: const ['--no-wasm', '--web-run-headless'],
      );

      final warned = await dt.waitForStderr(
        'ddc_for_wasm_only_target',
        timeout: const Duration(minutes: 4),
      );
      expect(warned, contains('WebAssembly only'));
      expect(warned, contains('Int64List'));

      // It is the DDC loop, and the app is not the program it ships: DDC
      // compiles JavaScript, which cannot hold the largest 64-bit integer, so
      // the first compile is refused. That refusal is the failure the default
      // loop spares an app like this.
      final failed = await dt.waitForStderr(
        'initial_compile_failed',
        timeout: const Duration(minutes: 6),
      );
      expect(failed, contains('0x7FFFFFFFFFFFFFFF'));
      expect(failed, contains("can't be represented exactly in JavaScript"));

      await dt.sendCommand(1, 'daemon.shutdown');
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

/// The widget tree once it holds [text], asked until it does.
///
/// `app.started` is the page loading; the first frame follows it.
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
