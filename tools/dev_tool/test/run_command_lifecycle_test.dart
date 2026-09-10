/// Integration-flavoured tests that wire the hot-reload subsystem
/// end-to-end (CommandRunner + ReloadOrchestrator + SourceWatcher with a
/// real DirectoryWatcher), using fakes for Compiler and AppInstance.
///
/// The file watcher and a manual hotReload share the same
/// CommandRunner.Pool(1) and AppliedVersions. A timed-out applyKernel
/// surfaces as ReloadApplyFailed and does not wedge the queue.
import 'dart:async';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/command_runner.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/app_instance.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/applied_versions.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/package_uri_resolver.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/reload_orchestrator.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/session_reloader.dart';
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
  final PackageUriResolver resolver;
  final AppliedVersions applied;
  final FakeCompiler compiler;
  final FakeAppInstance app;

  /// Rebuilt by [seedApplied]: the orchestrator's constructor copies the
  /// shared baseline per app, so it must be constructed after seeding, the
  /// way the assembler orders it in production.
  late ReloadOrchestrator orchestrator;

  final CommandRunner runner;

  _Harness._({
    required this.tmp,
    required this.workspace,
    required this.resolver,
    required this.applied,
    required this.compiler,
    required this.app,
    required this.runner,
  }) {
    _wireOrchestrator();
    runner.register('app.hotReload', (params) async {
      final declared =
          (params['invalidatedFiles'] as List?)?.cast<String>().toSet() ??
          <String>{};
      // The no-appId shape: every app the orchestrator drives is targeted.
      final outcome = await orchestrator.reload(
        declared: declared,
        targets: orchestrator.apps,
      );
      return {'outcome': outcome.runtimeType.toString()};
    });
  }

  void _wireOrchestrator() {
    orchestrator = ReloadOrchestrator(
      workspace: workspace,
      units: [
        SessionReloader(
          id: app.id,
          compiler: compiler,
          applied: AppliedVersions.from(applied),
          app: app,
        ),
      ],
      entrypoint: 'package:app/main.dart',
    );
  }

  static Future<_Harness> create() async {
    final tmp = await Directory.systemTemp.createTemp('lifecycle_test_');
    Directory(p.join(tmp.path, 'lib')).createSync();
    final resolver = PackageUriResolver(
      workspaceRoot: tmp.path,
      sourcePackages: const [(name: 'app', libRoot: '')],
    );
    final workspace = Workspace(resolver: resolver);
    return _Harness._(
      tmp: tmp,
      workspace: workspace,
      resolver: resolver,
      applied: AppliedVersions(),
      compiler: FakeCompiler(),
      app: FakeAppInstance(id: 'app1'),
      runner: CommandRunner(),
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
    _wireOrchestrator();
  }
}

void main() {
  group('RunCommand lifecycle', () {
    test(
      'a manual hotReload after a clean reload returns ReloadNoChange',
      () async {
        final h = await _Harness.create();
        try {
          h.writeFile('main.dart', 'v1');
          h.seedApplied();

          // First call after an edit.
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
      },
    );

    test(
      'Bug A repro: a manual reload after a watcher-driven reload still picks up later edits',
      () async {
        // Two reloads come in for the same file at different versions.
        // With per-file AppliedVersions and Pool(1) serialization, the
        // second observes its own distinct `Version`.
        final h = await _Harness.create();
        try {
          h.writeFile('main.dart', 'v1');
          h.seedApplied();

          // Watcher's reload (passes explicit invalidatedFiles).
          h.writeFile('main.dart', 'v2 longer');
          final watcherCall = await h.runner.run('app.hotReload', {
            'invalidatedFiles': ['package:app/main.dart'],
          });
          expect(watcherCall['outcome'], 'ReloadApplied');

          // User edits again.
          h.writeFile('main.dart', 'v3 longer still much');

          // Manual reload (no explicit files). Must observe the new
          // `Version` and recompile — not return ReloadNoChange.
          final manual = await h.runner.run('app.hotReload', {});
          expect(
            manual['outcome'],
            'ReloadApplied',
            reason: 'second edit must not be hidden by the watcher reload',
          );
        } finally {
          await h.dispose();
        }
      },
    );

    test(
      'a watcher-driven reload while another is in-flight runs sequentially via Pool(1)',
      () async {
        final h = await _Harness.create();
        try {
          h.writeFile('main.dart', 'v1');
          h.seedApplied();

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
      },
    );

    test(
      'Bug C repro: an AppInstance timeout surfaces as ReloadApplyFailed and does not wedge the pool',
      () async {
        final h = await _Harness.create();
        try {
          h.writeFile('main.dart', 'v1');
          h.seedApplied();

          h.writeFile('main.dart', 'v2 longer');

          h.app.nextOutcome = const ApplyTimedOut();
          final r1 = await h.runner.run('app.hotReload', {});
          expect(r1['outcome'], 'ReloadApplyFailed');

          // Pool is still healthy: another command runs immediately.
          h.app.nextOutcome = const Applied();
          final r2 = await h.runner
              .run('app.hotReload', {})
              .timeout(
                const Duration(seconds: 2),
                onTimeout: () => throw StateError('Pool wedged'),
              );
          // FS hasn't moved; the previous reload didn't advance applied
          // versions (because of ApplyTimedOut); so this re-tries.
          expect(r2['outcome'], 'ReloadApplied');
        } finally {
          await h.dispose();
        }
      },
    );

    test(
      'a real DirectoryWatcher firing on a tmp file results in orchestrator.reload running once',
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
              'invalidatedFiles': [
                for (final p in change.paths)
                  if (h.resolver.toPackageUri(p) case final uri?) uri,
              ],
            });
            reloadResults.add(result);
            if (!ranCompleter.isCompleted) ranCompleter.complete();
          });

          // Nothing to wait for here. `SourceWatcher.start` awaits
          // `DirectoryWatcher.ready`, whose contract is that setup is finished
          // and events are being delivered — package:watcher discards every
          // event it sees before that point, which is what "primed" means. A
          // sleep layered on top of an already-awaited happens-before is a guess
          // about how long someone else's setup takes, and the guess is what
          // breaks under load, not the watcher.
          h.writeFile('main.dart', 'v2 longer');

          await ranCompleter.future.timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              throw StateError(
                'watcher did not fire within 5s of writing the file',
              );
            },
          );
          await sub.cancel();
          await watcher.stop();

          expect(reloadResults, hasLength(1));
          expect(reloadResults.first['outcome'], 'ReloadApplied');
        } finally {
          await h.dispose();
        }
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );
  });
}
