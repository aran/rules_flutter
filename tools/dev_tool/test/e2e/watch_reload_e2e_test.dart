@Tags(['e2e'])
library;

import 'dart:io';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';

/// Watch-mode (filesystem-watcher-driven) reload over the codegen example.
///
/// Reload CORRECTNESS is otherwise verified manually (docs/TESTING.md), but the
/// watcher path has a specific failure mode this guards: an edit to a
/// DEPENDENCY package's source must be keyed by its `package:` URI (via the
/// build-emitted sourcePackages → PackageUriResolver), not a bogus `file://`
/// URI that the frontend_server silently drops. We assert the rendered output
/// actually changes after a watcher-triggered reload of (1) the app's own
/// source and (2) a dependency package's source.
void main() {
  group('watch-mode reload (codegen)', () {
    test('filesystem watcher reloads app + dependency source edits', () async {
      final ws = e2eWorkspace('codegen');
      final appMain = File('$ws/lib/main.dart');
      final depSource = File('$ws/dep_lib/lib/catalog.dart');
      final appMainOrig = appMain.readAsStringSync();
      final depSourceOrig = depSource.readAsStringSync();

      final dt = await startDevTool(
        workspace: ws,
        target: ':app_macos',
        device: 'macos',
        watch: true,
      );
      addTearDown(() async {
        appMain.writeAsStringSync(appMainOrig);
        depSource.writeAsStringSync(depSourceOrig);
        await dt.dispose();
      });

      final start = await dt.waitForEvent('app.start',
          timeout: const Duration(seconds: 240));
      final appId = start['params']?['appId'] as String? ?? dt.appId!;
      await dt.waitForHttpControl(timeout: const Duration(seconds: 60));
      // Let the first frame render and the watcher settle past its debounce.
      await Future<void>.delayed(const Duration(seconds: 4));

      Future<List<int>> shot() => dt.httpScreenshot(appId);
      final baseline = await shot();
      expect(baseline.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);

      // (1) Edit the app's own source — watcher must auto-reload.
      expect(appMainOrig.contains("'fields:"), isTrue,
          reason: 'fixture marker present');
      appMain.writeAsStringSync(
          appMainOrig.replaceFirst("'fields:", "'WATCHED:"));
      final afterApp = await _awaitChangedShot(shot, baseline);
      expect(afterApp, isNotNull,
          reason: 'app source edit should trigger a watcher reload that '
              'changes the rendered output');

      // (2) Edit a DEPENDENCY package's source — the regression case.
      depSource.writeAsStringSync(depSourceOrig.replaceFirst(
          "catalogFields.join(',')", "'DEP-' + catalogFields.join(',')"));
      final afterDep = await _awaitChangedShot(shot, afterApp!);
      expect(afterDep, isNotNull,
          reason: 'dependency source edit must be keyed package:dep_lib/... by '
              'the resolver and reload — not silently dropped');
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}

/// Polls screenshots until one differs from [previous] (the watcher's debounce
/// + recompile is async), or null after a bounded wait.
Future<List<int>?> _awaitChangedShot(
  Future<List<int>> Function() shot,
  List<int> previous,
) async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 750));
    final next = await shot();
    if (!_bytesEqual(next, previous)) return next;
  }
  return null;
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
