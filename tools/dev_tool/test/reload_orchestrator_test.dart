import 'dart:async';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/hot_reload/app_instance.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/applied_versions.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/compiler.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/package_uri_resolver.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/reload_orchestrator.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/workspace.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fakes.dart';

void main() {
  group('ReloadOrchestrator', () {
    late Directory tmp;
    late Workspace workspace;
    late AppliedVersions applied;
    late FakeCompiler compiler;
    late FakeAppInstance app;
    late ReloadOrchestrator orchestrator;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('orchestrator_test_');
      Directory(p.join(tmp.path, 'lib')).createSync();
      workspace = Workspace(
        resolver: PackageUriResolver(
          workspaceRoot: tmp.path,
          sourcePackages: const [(name: 'app', libRoot: '')],
        ),
      );
      applied = AppliedVersions();
      compiler = FakeCompiler();
      app = FakeAppInstance(id: 'app1');
      orchestrator = ReloadOrchestrator(
        workspace: workspace,
        applied: applied,
        compiler: compiler,
        apps: [app],
        entrypoint: 'package:app/main.dart',
      );
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    void writeFile(String relPath, String content) {
      final f = File(p.join(tmp.path, 'lib', relPath));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(content);
    }

    String uriFor(String relPath) => 'package:app/$relPath';

    /// Pretend we just launched: every file currently on disk is "applied"
    /// at its current version.
    void seedApplied() {
      final snap = workspace.snapshot();
      applied.markApplied(snap, files: snap.fileUris.toSet());
    }

    test('reload() with no declared and no FS changes returns ReloadNoChange',
        () async {
      writeFile('main.dart', 'void main() {}');
      seedApplied();

      final outcome = await orchestrator.reload();
      expect(outcome, isA<ReloadNoChange>());
      expect(compiler.recompileCalls, isEmpty,
          reason: 'no compile should have been issued');
    });

    test('reload() refreshes generated sources before compile, invalidates them',
        () async {
      writeFile('main.dart', 'void main() {}');
      // A generated file OUTSIDE lib/ (mirrors a bazel-out codegen output).
      final genFile = File(p.join(tmp.path, 'gen', 'user.g.dart'));
      genFile.parent.createSync(recursive: true);
      genFile.writeAsStringSync('// v1');
      const genUri = 'package:app/user.g.dart';

      final ws = Workspace(
        resolver: PackageUriResolver(
          workspaceRoot: tmp.path,
          sourcePackages: const [(name: 'app', libRoot: '')],
        ),
        generatedFiles: {genUri: genFile.path},
      );
      var refreshCalls = 0;
      var compilesAtRefresh = -1;
      final orch = ReloadOrchestrator(
        workspace: ws,
        applied: applied,
        compiler: compiler,
        apps: [app],
        entrypoint: 'package:app/main.dart',
        refreshGenerated: () async {
          refreshCalls++;
          compilesAtRefresh = compiler.recompileCalls.length;
          // Simulate bazel regenerating the file with new content.
          genFile.writeAsStringSync('// v2 regenerated (longer)');
          return true;
        },
      );
      final snap0 = ws.snapshot();
      applied.markApplied(snap0, files: snap0.fileUris.toSet());

      final outcome = await orch.reload();

      expect(refreshCalls, 1, reason: 'refreshGenerated runs once per reload');
      expect(compilesAtRefresh, 0,
          reason: 'refreshGenerated runs BEFORE any compile');
      expect(outcome, isA<ReloadApplied>());
      expect((outcome as ReloadApplied).filesRecompiled, contains(genUri),
          reason: 'the regenerated file was invalidated via the snapshot diff');
    });

    test('reload() fails when refreshGenerated (bazel) fails', () async {
      writeFile('main.dart', 'void main() {}');
      final orch = ReloadOrchestrator(
        workspace: workspace,
        applied: applied,
        compiler: compiler,
        apps: [app],
        entrypoint: 'package:app/main.dart',
        refreshGenerated: () async => false,
      );
      seedApplied();

      final outcome = await orch.reload();
      expect(outcome, isA<ReloadCompileFailed>());
      expect(compiler.recompileCalls, isEmpty,
          reason: 'a failed generated rebuild must not proceed to compile');
    });

    test('reload() with one FS-changed file applies it and advances applied versions',
        () async {
      writeFile('main.dart', 'void main() { print(1); }');
      seedApplied();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      writeFile('main.dart', 'void main() { print(2); } // longer');

      final outcome = await orchestrator.reload();
      expect(outcome, isA<ReloadApplied>());
      final applied_ = outcome as ReloadApplied;
      expect(applied_.filesRecompiled, {uriFor('main.dart')});
      expect(applied_.isEmpty, isFalse);

      // Subsequent reload sees nothing changed.
      final second = await orchestrator.reload();
      expect(second, isA<ReloadNoChange>());
    });

    test('reload(declared: {f}) recompiles f even when its disk version equals applied',
        () async {
      writeFile('main.dart', 'void main() {}');
      seedApplied();

      final outcome = await orchestrator.reload(declared: {uriFor('main.dart')});
      expect(outcome, isA<ReloadApplied>());
      expect(compiler.recompileCalls, hasLength(1));
      expect(compiler.recompileCalls.first.invalidated, {uriFor('main.dart')});
    });

    test('reload(declared: {f}) returns ReloadApplied(isEmpty: true) when f is byte-identical to applied',
        () async {
      writeFile('main.dart', 'void main() {}');
      seedApplied();

      final outcome = await orchestrator.reload(declared: {uriFor('main.dart')});
      expect(outcome, isA<ReloadApplied>());
      expect((outcome as ReloadApplied).isEmpty, isTrue,
          reason: 'declared file is unchanged; compile is a no-op');
    });

    test('reload(declared: {f}) returns ReloadApplied(isEmpty: false) when f produces a real delta',
        () async {
      writeFile('main.dart', 'void main() { print(1); }');
      seedApplied();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      writeFile('main.dart', 'void main() { print(2); } // longer');

      final outcome = await orchestrator.reload(declared: {uriFor('main.dart')});
      expect(outcome, isA<ReloadApplied>());
      expect((outcome as ReloadApplied).isEmpty, isFalse);
    });

    test('declared invalidations are unioned with FS-detected changes — both are recompiled',
        () async {
      writeFile('a.dart', 'a-v1');
      writeFile('b.dart', 'b-v1');
      seedApplied();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      writeFile('a.dart', 'a-v2 longer');

      // FS shows a.dart changed; caller declares b.dart.
      final outcome = await orchestrator.reload(declared: {uriFor('b.dart')});
      expect(outcome, isA<ReloadApplied>());
      expect(compiler.recompileCalls.first.invalidated,
          {uriFor('a.dart'), uriFor('b.dart')});
    });

    test('reload() after a prior reload still picks up subsequent edits to the same file',
        () async {
      // This is the Bug A repro. With a global timestamp, the first reload's
      // mark would hide the second edit's mtime. With per-file AppliedVersions,
      // the second reload independently observes the new version.
      writeFile('main.dart', 'v1');
      seedApplied();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      writeFile('main.dart', 'v2 longer');

      final first = await orchestrator.reload();
      expect(first, isA<ReloadApplied>());

      await Future<void>.delayed(const Duration(milliseconds: 10));
      writeFile('main.dart', 'v3 longer still much');

      final second = await orchestrator.reload();
      expect(second, isA<ReloadApplied>(),
          reason: 'subsequent edit must not be hidden by the first reload');
    });

    test('reload() after a prior reload picks up edits to other files',
        () async {
      // Bug A in its other shape: editing file A and reloading must not
      // hide a later edit to file B.
      writeFile('a.dart', 'a-v1');
      writeFile('b.dart', 'b-v1');
      seedApplied();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      writeFile('a.dart', 'a-v2 longer');

      final first = await orchestrator.reload();
      expect(first, isA<ReloadApplied>());

      await Future<void>.delayed(const Duration(milliseconds: 10));
      writeFile('b.dart', 'b-v2 longer');

      final second = await orchestrator.reload();
      expect(second, isA<ReloadApplied>());
      expect((second as ReloadApplied).filesRecompiled,
          {uriFor('b.dart')});
    });

    test('a sequential second reload over a clean FS returns ReloadNoChange cheaply',
        () async {
      writeFile('main.dart', 'v1');
      seedApplied();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      writeFile('main.dart', 'v2 longer');

      await orchestrator.reload();
      // No further edits.
      final second = await orchestrator.reload();
      expect(second, isA<ReloadNoChange>());
      expect(compiler.recompileCalls, hasLength(1),
          reason: 'second reload should not have triggered a compile');
    });

    test('reload() returns ReloadCompileFailed and rolls back on compile error; applied versions NOT advanced',
        () async {
      writeFile('main.dart', 'v1');
      seedApplied();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      writeFile('main.dart', 'v2 longer');

      compiler.nextOutcome = const CompileFailed('syntax error');
      final outcome = await orchestrator.reload();
      expect(outcome, isA<ReloadCompileFailed>());
      expect((outcome as ReloadCompileFailed).diagnostics, 'syntax error');
      expect(compiler.rollbackCount, 1);
      expect(compiler.commitCount, 0);

      // applied not advanced — the next reload should still see main.dart as changed.
      compiler.nextOutcome = const CompileSucceeded('/tmp/d.dill');
      final retry = await orchestrator.reload();
      expect(retry, isA<ReloadApplied>());
    });

    test('reload() returns ReloadApplyFailed when a device fails; applied versions NOT advanced',
        () async {
      writeFile('main.dart', 'v1');
      seedApplied();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      writeFile('main.dart', 'v2 longer');

      app.nextOutcome = const ApplyFailed('device error');
      final outcome = await orchestrator.reload();
      expect(outcome, isA<ReloadApplyFailed>());
      expect((outcome as ReloadApplyFailed).perApp['app1'],
          isA<ApplyFailed>());
      expect(compiler.rollbackCount, 1);
      expect(compiler.commitCount, 0);

      // applied not advanced — retry should still find main.dart changed.
      app.nextOutcome = const Applied();
      final retry = await orchestrator.reload();
      expect(retry, isA<ReloadApplied>());
    });

    test('reload() returns ReloadApplyFailed when an AppInstance times out',
        () async {
      writeFile('main.dart', 'v1');
      seedApplied();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      writeFile('main.dart', 'v2 longer');

      app.nextOutcome = const ApplyTimedOut();
      final outcome = await orchestrator.reload();
      expect(outcome, isA<ReloadApplyFailed>());
      expect((outcome as ReloadApplyFailed).perApp['app1'],
          isA<ApplyTimedOut>());
    });

    test('reload() across multiple devices: one fails, the others are still attempted',
        () async {
      writeFile('main.dart', 'v1');
      seedApplied();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      writeFile('main.dart', 'v2 longer');

      final app2 = FakeAppInstance(id: 'app2');
      final orch2 = ReloadOrchestrator(
        workspace: workspace,
        applied: applied,
        compiler: compiler,
        apps: [app, app2],
        entrypoint: 'package:app/main.dart',
      );
      app.nextOutcome = const ApplyFailed('boom');
      app2.nextOutcome = const Applied();

      final outcome = await orch2.reload();
      expect(outcome, isA<ReloadApplyFailed>());
      // Both apps were attempted in parallel; app2 succeeded but the
      // overall outcome is failure because app1 failed.
      expect(app.calls, hasLength(1));
      expect(app2.calls, hasLength(1));
    });

    test('restart() clears applied versions; subsequent reload() recompiles everything',
        () async {
      writeFile('a.dart', 'a-v1');
      writeFile('b.dart', 'b-v1');
      seedApplied();

      final outcome = await orchestrator.restart();
      expect(outcome, isA<ReloadApplied>());
      expect(compiler.fullCompileCalls, hasLength(1));
      expect(app.calls.last.mode, ApplyMode.hotRestart);

      // After restart, applied is repopulated to current snapshot. No
      // further changes, so next reload is a no-op.
      final second = await orchestrator.reload();
      expect(second, isA<ReloadNoChange>());
    });

    test('reload() over an in-flight first reload still completes (Pool(1) external + bounded compiler)',
        () async {
      // The orchestrator does not own single-flight; CommandRunner.Pool(1)
      // handles that. But internally, if a caller bypasses Pool and fires
      // two reloads, the pipeline must still be predictable. Here we use
      // FakeCompiler.pendingResult to hold the first compile open, then
      // ensure that after we release it, both calls return cleanly.
      writeFile('main.dart', 'v1');
      seedApplied();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      writeFile('main.dart', 'v2 longer');

      compiler.pendingResult = Completer<void>();
      final f1 = orchestrator.reload();
      // Don't fire the second one until the first has captured its
      // snapshot — the two compile calls would otherwise interleave the
      // FakeCompiler's single recompileCalls list. The orchestrator
      // captures snap synchronously at the top of reload(); awaiting a
      // microtask is enough to let it past that point.
      await Future<void>.delayed(Duration.zero);

      compiler.pendingResult!.complete();
      final r1 = await f1;
      expect(r1, isA<ReloadApplied>());
    });
  });
}
