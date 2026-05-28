/// Integration-flavoured tests that wire the hot-reload subsystem
/// end-to-end (CommandRunner + ReloadOrchestrator + SourceWatcher with a
/// real DirectoryWatcher), using fakes for Compiler and AppInstance.
///
/// These tests exercise the bug-A and bug-C scenarios at the integration
/// level: the file watcher and a manual hotReload share the same
/// CommandRunner.Pool(1) and AppliedVersions. A timed-out applyKernel
/// surfaces as ReloadApplyFailed and does not wedge the queue.
import 'dart:async';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/command_runner.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/app_instance.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/applied_versions.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/reload_orchestrator.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/source_watcher.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/workspace.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fakes.dart';

/// Wires CommandRunner → orchestrator → fakes the way RunCommand.execute
/// does in production.
class _Harness {
  final Directory tmp;
  final Workspace workspace;
  final AppliedVersions applied;
  final FakeCompiler compiler;
  final FakeAppInstance app;
  final ReloadOrchestrator orchestrator;
  final CommandRunner runner;

  _Harness._({
    required this.tmp,
    required this.workspace,
    required this.applied,
    required this.compiler,
    required this.app,
    required this.orchestrator,
    required this.runner,
  });

  static Future<_Harness> create() async {
    final tmp = await Directory.systemTemp.createTemp('lifecycle_test_');
    Directory(p.join(tmp.path, 'lib')).createSync();
    final workspace =
        Workspace(root: tmp.path, entrypoint: 'package:app/main.dart');
    final applied = AppliedVersions();
    final compiler = FakeCompiler();
    final app = FakeAppInstance(id: 'app1');
    final orchestrator = ReloadOrchestrator(
      workspace: workspace,
      applied: applied,
      compiler: compiler,
      apps: [app],
      entrypoint: 'package:app/main.dart',
    );
    final runner = CommandRunner();
    runner.register('app.hotReload', (params) async {
      final declared = (params['invalidatedFiles'] as List?)
              ?.cast<String>()
              .toSet() ??
          <String>{};
      final outcome = await orchestrator.reload(declared: declared);
      return {'outcome': outcome.runtimeType.toString()};
    });
    return _Harness._(
      tmp: tmp,
      workspace: workspace,
      applied: applied,
      compiler: compiler,
      app: app,
      orchestrator: orchestrator,
      runner: runner,
    );
  }

  Future<void> dispose() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  }

  void writeFile(String relPath, String content) {
    final f = File(p.join(tmp.path, 'lib', relPath));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  void seedApplied() {
    final snap = workspace.snapshot();
    applied.markApplied(snap, files: snap.fileUris.toSet());
  }
}

void main() {
  group('RunCommand lifecycle', () {
    test('a manual hotReload after a clean reload returns ReloadNoChange',
        () async {
      final h = await _Harness.create();
      try {
        h.writeFile('main.dart', 'v1');
        h.seedApplied();

        // First call after an edit.
        await Future<void>.delayed(const Duration(milliseconds: 10));
        h.writeFile('main.dart', 'v2 longer');

        final r1 = await h.runner.run('app.hotReload', {});
        expect(r1['outcome'], 'ReloadApplied');

        // Immediately after, a second manual call sees no further changes.
        // Pool(1) serializes the call after r1 finishes; the orchestrator
        // re-snapshots and finds nothing new.
        final r2 = await h.runner.run('app.hotReload', {});
        expect(r2['outcome'], 'ReloadNoChange');
      } finally {
        await h.dispose();
      }
    });

    test('Bug A repro: a manual reload after a watcher-driven reload still picks up later edits',
        () async {
      // Two reloads come in for the same file at different versions.
      // With the old global-timestamp logic, the second would be hidden.
      // With per-file AppliedVersions and Pool(1) serialization, the
      // second observes its own newer mtime.
      final h = await _Harness.create();
      try {
        h.writeFile('main.dart', 'v1');
        h.seedApplied();

        // Watcher's reload (passes explicit invalidatedFiles).
        await Future<void>.delayed(const Duration(milliseconds: 10));
        h.writeFile('main.dart', 'v2 longer');
        final watcherCall = await h.runner.run('app.hotReload', {
          'invalidatedFiles': ['package:app/main.dart'],
        });
        expect(watcherCall['outcome'], 'ReloadApplied');

        // User edits again.
        await Future<void>.delayed(const Duration(milliseconds: 10));
        h.writeFile('main.dart', 'v3 longer still much');

        // Manual reload (no explicit files). Must observe the new mtime
        // and recompile — not return ReloadNoChange.
        final manual = await h.runner.run('app.hotReload', {});
        expect(manual['outcome'], 'ReloadApplied',
            reason: 'second edit must not be hidden by the watcher reload');
      } finally {
        await h.dispose();
      }
    });

    test('a watcher-driven reload while another is in-flight runs sequentially via Pool(1)',
        () async {
      final h = await _Harness.create();
      try {
        h.writeFile('main.dart', 'v1');
        h.seedApplied();

        await Future<void>.delayed(const Duration(milliseconds: 10));
        h.writeFile('main.dart', 'v2 longer');

        // Hold the first compile open via FakeCompiler.pendingResult.
        h.compiler.pendingResult = Completer<void>();
        final f1 = h.runner.run('app.hotReload', {});

        // Fire a second call before the first finishes — it queues.
        await Future<void>.delayed(Duration.zero);
        final f2 = h.runner.run('app.hotReload', {});

        // Release the first compile.
        h.compiler.pendingResult!.complete();

        final r1 = await f1;
        final r2 = await f2;
        expect(r1['outcome'], 'ReloadApplied');
        // The second call ran after the first finished and applied
        // versions had advanced; it sees nothing changed.
        expect(r2['outcome'], 'ReloadNoChange');

        // Compiler was called exactly once.
        expect(h.compiler.recompileCalls, hasLength(1));
      } finally {
        await h.dispose();
      }
    });

    test('Bug C repro: an AppInstance timeout surfaces as ReloadApplyFailed and does not wedge the pool',
        () async {
      final h = await _Harness.create();
      try {
        h.writeFile('main.dart', 'v1');
        h.seedApplied();

        await Future<void>.delayed(const Duration(milliseconds: 10));
        h.writeFile('main.dart', 'v2 longer');

        h.app.nextOutcome = const ApplyTimedOut();
        final r1 = await h.runner.run('app.hotReload', {});
        expect(r1['outcome'], 'ReloadApplyFailed');

        // Pool is still healthy: another command runs immediately.
        h.app.nextOutcome = const Applied();
        final r2 = await h.runner.run('app.hotReload', {}).timeout(
              const Duration(seconds: 2),
              onTimeout: () => throw StateError('Pool wedged'),
            );
        // FS hasn't moved; the previous reload didn't advance applied
        // versions (because of ApplyTimedOut); so this re-tries.
        expect(r2['outcome'], 'ReloadApplied');
      } finally {
        await h.dispose();
      }
    });

    test('a real DirectoryWatcher firing on a tmp file results in orchestrator.reload running once',
        () async {
      // Slower test (uses real FSEvents/inotify). Generous timeout.
      final h = await _Harness.create();
      try {
        h.writeFile('main.dart', 'v1');
        h.seedApplied();

        final watcher = SourceWatcher(
          root: h.tmp.path,
          debounce: const Duration(milliseconds: 50),
        );
        await watcher.start();

        // Subscribe before producing the change.
        final ranCompleter = Completer<void>();
        final reloadResults = <Map<String, dynamic>>[];
        final sub = watcher.changes.listen((change) async {
          final result = await h.runner.run('app.hotReload', {
            'invalidatedFiles':
                change.paths.map(h.workspace.toFrontendServerUri).toList(),
          });
          reloadResults.add(result);
          if (!ranCompleter.isCompleted) ranCompleter.complete();
        });

        // Wait for the watcher to be primed before writing — DirectoryWatcher
        // may need a tick.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        h.writeFile('main.dart', 'v2 longer');

        await ranCompleter.future
            .timeout(const Duration(seconds: 5), onTimeout: () {
          throw StateError(
              'watcher did not fire within 5s of writing the file');
        });
        await sub.cancel();
        await watcher.stop();

        expect(reloadResults, hasLength(1));
        expect(reloadResults.first['outcome'], 'ReloadApplied');
      } finally {
        await h.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 15)));
  });
}
