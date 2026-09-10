import 'dart:async';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/hot_reload/app_instance.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/applied_versions.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/compiler.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/flutter_error_report.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/package_uri_resolver.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/reload_orchestrator.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/session_reloader.dart';
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

    /// One compiler per app id — the production shape. Tests that care about a
    /// particular app's compiler reach for it by id.
    late Map<String, FakeCompiler> compilers;

    /// Apps whose first compile failed, and what it said. Empty unless a test
    /// is about the never-compiled state.
    late Map<String, String> baselineFailures;

    /// The units [makeOrchestrator] last built, by app id — so a test can ask
    /// what a unit believes after the orchestrator has driven it.
    late Map<String, SessionReloader> units;

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
      compilers = {'app1': compiler};
      baselineFailures = {};
    });

    /// The unit that drives [a]: its own compiler, and a copy of the shared
    /// build baseline, exactly as the assembler builds them.
    SessionReloader unitFor(FakeAppInstance a) => SessionReloader(
      id: a.id,
      compiler: compilers[a.id] ??= FakeCompiler(),
      applied: AppliedVersions.from(applied),
      app: a,
      baselineFailure: baselineFailures[a.id],
    );

    /// Construct the orchestrator AFTER the shared baseline is seeded, the way
    /// the assembler does: each unit copies [applied], so seeding must come
    /// first to mean anything.
    ReloadOrchestrator makeOrchestrator({List<FakeAppInstance>? apps}) {
      units = {
        for (final a in apps ?? [app]) a.id: unitFor(a),
      };
      return ReloadOrchestrator(
        workspace: workspace,
        units: units.values.toList(),
        entrypoint: 'package:app/main.dart',
      );
    }

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

    test(
      'reload() with no declared and no FS changes returns ReloadNoChange',
      () async {
        writeFile('main.dart', 'void main() {}');
        seedApplied();
        final orchestrator = makeOrchestrator();

        final outcome = await orchestrator.reload(targets: [app]);
        expect(outcome, isA<ReloadNoChange>());
        expect(
          compiler.recompileCalls,
          isEmpty,
          reason: 'no compile should have been issued',
        );
      },
    );

    // The same empty reload, over an app whose first compile never succeeded.
    //
    // "Already up to date" is true of disk and false of the app: it is running
    // its launch build, the working tree still does not compile, and nothing
    // has changed since it was told so. That answer is the one thing that
    // would stop the reader looking for the error, which is why this arm
    // restates the compiler instead.
    test(
      'an empty reload on an app that never compiled restates the failure',
      () async {
        writeFile('main.dart', 'void main() {}');
        seedApplied();
        baselineFailures['app1'] = 'main.dart:1:8: Error: Bad syntax';
        final orchestrator = makeOrchestrator();

        final outcome = await orchestrator.reload(targets: [app]);
        expect(outcome, isA<ReloadCompileFailed>());
        expect(
          (outcome as ReloadCompileFailed).diagnostics,
          contains('Bad syntax'),
        );
        expect(
          compiler.recompileCalls,
          isEmpty,
          reason:
              'nothing changed on disk, so nothing is recompiled — this '
              'is about what the caller is TOLD, not about doing work',
        );
      },
    );

    // And it is a state the unit leaves, on the ordinary event: a compile that
    // succeeds. Nothing polls, nothing retries — the edit is what brings the
    // next compile, and that compile is what settles it.
    test('a successful compile clears the never-compiled state', () async {
      writeFile('main.dart', 'void main() {}');
      seedApplied();
      baselineFailures['app1'] = 'main.dart:1:8: Error: Bad syntax';
      final orchestrator = makeOrchestrator();

      // The fix lands, the watcher's reload compiles it, and it applies.
      writeFile('main.dart', 'void main() { print("fixed"); }');
      final recovered = await orchestrator.reload(targets: [app]);
      expect(
        recovered,
        isA<ReloadApplied>(),
        reason: 'the reload after the fix must land: $recovered',
      );
      expect(units['app1']!.baselineFailure, isNull);

      // So the next empty reload is an ordinary one again.
      final second = await orchestrator.reload(targets: [app]);
      expect(second, isA<ReloadNoChange>());
    });

    // Per unit, not per orchestrator: two apps can be in different states, and
    // an app that compiled fine must not be answered with another app's
    // failure.
    test(
      'a second app that compiled is not told about the first one\'s failure',
      () async {
        writeFile('main.dart', 'void main() {}');
        seedApplied();
        final app2 = FakeAppInstance(id: 'app2');
        baselineFailures['app1'] = 'main.dart:1:8: Error: Bad syntax';
        final orchestrator = makeOrchestrator(apps: [app, app2]);

        expect(
          await orchestrator.reload(targets: [app2]),
          isA<ReloadNoChange>(),
        );
        expect(
          await orchestrator.reload(targets: [app]),
          isA<ReloadCompileFailed>(),
        );
      },
    );

    test(
      'reload() refreshes generated sources before compile, invalidates them',
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
        final snap0 = ws.snapshot();
        applied.markApplied(snap0, files: snap0.fileUris.toSet());
        final orch = ReloadOrchestrator(
          workspace: ws,
          units: [unitFor(app)],
          entrypoint: 'package:app/main.dart',
          refreshGenerated: () async {
            refreshCalls++;
            compilesAtRefresh = compiler.recompileCalls.length;
            // Simulate bazel regenerating the file with new content.
            genFile.writeAsStringSync('// v2 regenerated (longer)');
            return true;
          },
        );

        final outcome = await orch.reload(targets: [app]);

        expect(
          refreshCalls,
          1,
          reason: 'refreshGenerated runs once per reload',
        );
        expect(
          compilesAtRefresh,
          0,
          reason: 'refreshGenerated runs BEFORE any compile',
        );
        expect(outcome, isA<ReloadApplied>());
        expect(
          (outcome as ReloadApplied).filesRecompiled,
          contains(genUri),
          reason: 'the regenerated file was invalidated via the snapshot diff',
        );
      },
    );

    test('reload() fails when refreshGenerated (bazel) fails', () async {
      writeFile('main.dart', 'void main() {}');
      seedApplied();
      final orch = ReloadOrchestrator(
        workspace: workspace,
        units: [unitFor(app)],
        entrypoint: 'package:app/main.dart',
        refreshGenerated: () async => false,
      );

      final outcome = await orch.reload(targets: [app]);
      expect(outcome, isA<ReloadCompileFailed>());
      expect(
        compiler.recompileCalls,
        isEmpty,
        reason: 'a failed generated rebuild must not proceed to compile',
      );
    });

    test(
      'reload() with one FS-changed file applies it and advances applied versions',
      () async {
        writeFile('main.dart', 'void main() { print(1); }');
        seedApplied();
        final orchestrator = makeOrchestrator();
        writeFile('main.dart', 'void main() { print(2); } // longer');

        final outcome = await orchestrator.reload(targets: [app]);
        expect(outcome, isA<ReloadApplied>());
        final applied_ = outcome as ReloadApplied;
        expect(applied_.filesRecompiled, {uriFor('main.dart')});
        expect(applied_.isEmpty, isFalse);

        // Subsequent reload sees nothing changed.
        final second = await orchestrator.reload(targets: [app]);
        expect(second, isA<ReloadNoChange>());
      },
    );

    test(
      'reload(declared: {f}) recompiles f even when its disk version equals applied',
      () async {
        writeFile('main.dart', 'void main() {}');
        seedApplied();
        final orchestrator = makeOrchestrator();

        final outcome = await orchestrator.reload(
          declared: {uriFor('main.dart')},
          targets: [app],
        );
        expect(outcome, isA<ReloadApplied>());
        expect(compiler.recompileCalls, hasLength(1));
        expect(compiler.recompileCalls.first.invalidated, {
          uriFor('main.dart'),
        });
      },
    );

    test(
      'reload(declared: {f}) returns ReloadApplied(isEmpty: true) when f is byte-identical to applied',
      () async {
        writeFile('main.dart', 'void main() {}');
        seedApplied();
        final orchestrator = makeOrchestrator();

        final outcome = await orchestrator.reload(
          declared: {uriFor('main.dart')},
          targets: [app],
        );
        expect(outcome, isA<ReloadApplied>());
        expect(
          (outcome as ReloadApplied).isEmpty,
          isTrue,
          reason: 'declared file is unchanged; compile is a no-op',
        );
      },
    );

    test(
      'reload(declared: {f}) returns ReloadApplied(isEmpty: false) when f produces a real delta',
      () async {
        writeFile('main.dart', 'void main() { print(1); }');
        seedApplied();
        final orchestrator = makeOrchestrator();
        writeFile('main.dart', 'void main() { print(2); } // longer');

        final outcome = await orchestrator.reload(
          declared: {uriFor('main.dart')},
          targets: [app],
        );
        expect(outcome, isA<ReloadApplied>());
        expect((outcome as ReloadApplied).isEmpty, isFalse);
      },
    );

    test(
      'declared invalidations are unioned with FS-detected changes — both are recompiled',
      () async {
        writeFile('a.dart', 'a-v1');
        writeFile('b.dart', 'b-v1');
        seedApplied();
        final orchestrator = makeOrchestrator();
        writeFile('a.dart', 'a-v2 longer');

        // FS shows a.dart changed; caller declares b.dart.
        final outcome = await orchestrator.reload(
          declared: {uriFor('b.dart')},
          targets: [app],
        );
        expect(outcome, isA<ReloadApplied>());
        expect(compiler.recompileCalls.first.invalidated, {
          uriFor('a.dart'),
          uriFor('b.dart'),
        });
      },
    );

    test(
      'reload() after a prior reload still picks up subsequent edits to the same file',
      () async {
        // With a global timestamp, the first reload's mark would hide the
        // second edit's mtime. With per-file AppliedVersions, the second reload
        // independently observes the new version.
        writeFile('main.dart', 'v1');
        seedApplied();
        final orchestrator = makeOrchestrator();
        writeFile('main.dart', 'v2 longer');

        final first = await orchestrator.reload(targets: [app]);
        expect(first, isA<ReloadApplied>());

        writeFile('main.dart', 'v3 longer still much');

        final second = await orchestrator.reload(targets: [app]);
        expect(
          second,
          isA<ReloadApplied>(),
          reason: 'subsequent edit must not be hidden by the first reload',
        );
      },
    );

    test(
      'reload() after a prior reload picks up edits to other files',
      () async {
        // The same hazard in its other shape: editing file A and reloading must
        // not hide a later edit to file B.
        writeFile('a.dart', 'a-v1');
        writeFile('b.dart', 'b-v1');
        seedApplied();
        final orchestrator = makeOrchestrator();
        writeFile('a.dart', 'a-v2 longer');

        final first = await orchestrator.reload(targets: [app]);
        expect(first, isA<ReloadApplied>());

        writeFile('b.dart', 'b-v2 longer');

        final second = await orchestrator.reload(targets: [app]);
        expect(second, isA<ReloadApplied>());
        expect((second as ReloadApplied).filesRecompiled, {uriFor('b.dart')});
      },
    );

    test(
      'a sequential second reload over a clean FS returns ReloadNoChange cheaply',
      () async {
        writeFile('main.dart', 'v1');
        seedApplied();
        final orchestrator = makeOrchestrator();
        writeFile('main.dart', 'v2 longer');

        await orchestrator.reload(targets: [app]);
        // No further edits.
        final second = await orchestrator.reload(targets: [app]);
        expect(second, isA<ReloadNoChange>());
        expect(
          compiler.recompileCalls,
          hasLength(1),
          reason: 'second reload should not have triggered a compile',
        );
      },
    );

    test(
      'reload() returns ReloadCompileFailed and rolls back on compile error; applied versions NOT advanced',
      () async {
        writeFile('main.dart', 'v1');
        seedApplied();
        final orchestrator = makeOrchestrator();
        writeFile('main.dart', 'v2 longer');

        compiler.nextOutcome = const CompileFailed('syntax error');
        final outcome = await orchestrator.reload(targets: [app]);
        expect(outcome, isA<ReloadCompileFailed>());
        expect((outcome as ReloadCompileFailed).diagnostics, 'syntax error');
        expect(compiler.rollbackCount, 1);
        expect(compiler.commitCount, 0);

        // applied not advanced — the next reload should still see main.dart as changed.
        compiler.nextOutcome = const CompileSucceeded('/tmp/d.dill');
        final retry = await orchestrator.reload(targets: [app]);
        expect(retry, isA<ReloadApplied>());
      },
    );

    test(
      'reload() returns ReloadApplyFailed when a device fails; applied versions NOT advanced',
      () async {
        writeFile('main.dart', 'v1');
        seedApplied();
        final orchestrator = makeOrchestrator();
        writeFile('main.dart', 'v2 longer');

        app.nextOutcome = const ApplyFailed('device error');
        final outcome = await orchestrator.reload(targets: [app]);
        expect(outcome, isA<ReloadApplyFailed>());
        expect(
          (outcome as ReloadApplyFailed).perApp['app1'],
          isA<ApplyFailed>(),
        );
        expect(compiler.rollbackCount, 1);
        expect(compiler.commitCount, 0);

        // applied not advanced — retry should still find main.dart changed.
        app.nextOutcome = const Applied();
        final retry = await orchestrator.reload(targets: [app]);
        expect(retry, isA<ReloadApplied>());
      },
    );

    test(
      'reload() returns ReloadApplyFailed when an AppInstance times out',
      () async {
        writeFile('main.dart', 'v1');
        seedApplied();
        final orchestrator = makeOrchestrator();
        writeFile('main.dart', 'v2 longer');

        app.nextOutcome = const ApplyTimedOut();
        final outcome = await orchestrator.reload(targets: [app]);
        expect(outcome, isA<ReloadApplyFailed>());
        expect(
          (outcome as ReloadApplyFailed).perApp['app1'],
          isA<ApplyTimedOut>(),
        );
      },
    );

    test(
      'reload() reports an applied-then-threw device as failed, but keeps its work',
      () async {
        // The user is told the reload failed — the app IS broken — while the
        // bookkeeping records what the VM is actually running. Nothing in the
        // sealed switches enforces this half: `results.every((r) => r is
        // Applied)` is silently correct only for as long as a test says so.
        writeFile('main.dart', 'v1');
        seedApplied();
        final orchestrator = makeOrchestrator();
        writeFile('main.dart', 'v2 longer');

        app.nextOutcome = const AppliedThenThrew(
          FlutterErrorReport({'description': 'Null is not a String'}),
        );
        final outcome = await orchestrator.reload(targets: [app]);
        expect(outcome, isA<ReloadApplyFailed>());
        expect(
          (outcome as ReloadApplyFailed).perApp['app1'],
          isA<AppliedThenThrew>(),
        );
        expect(compiler.commitCount, 1);
        expect(compiler.rollbackCount, 0);

        // The record advanced with it: nothing is outstanding for this app, so
        // the next reload has no delta to re-offer.
        app.nextOutcome = const Applied();
        expect(
          await orchestrator.reload(targets: [app]),
          isA<ReloadNoChange>(),
          reason:
              're-sending code the app already runs would compute the '
              'next delta against a baseline the compiler discarded',
        );
      },
    );

    test(
      'reload() across multiple devices: one fails, the others are still attempted',
      () async {
        writeFile('main.dart', 'v1');
        seedApplied();
        writeFile('main.dart', 'v2 longer');

        final app2 = FakeAppInstance(id: 'app2');
        final orch2 = makeOrchestrator(apps: [app, app2]);
        final compiler2 = compilers['app2']!;
        app.nextOutcome = const ApplyFailed('boom');
        app2.nextOutcome = const Applied();

        final outcome = await orch2.reload(targets: [app, app2]);
        expect(outcome, isA<ReloadApplyFailed>());
        // Both apps were attempted in parallel; app2 succeeded but the
        // overall outcome is failure because app1 failed.
        expect(app.calls, hasLength(1));
        expect(app2.calls, hasLength(1));

        // Each app settles its OWN compiler. app2 took the kernel and keeps it;
        // only app1 rolls back. A shared compiler would have to discard both,
        // throwing away work the device had already accepted.
        expect(compiler.rollbackCount, 1);
        expect(compiler.commitCount, 0);
        expect(compiler2.rollbackCount, 0);
        expect(compiler2.commitCount, 1);

        // So a retry re-offers the edit to app1 only.
        app.nextOutcome = const Applied();
        final retry = await orch2.reload(targets: [app, app2]);
        expect(retry, isA<ReloadApplied>());
        expect(
          (retry as ReloadApplied).apps,
          [app],
          reason: 'app2 is already current and is left alone',
        );
      },
    );

    test(
      'restart() clears applied versions; subsequent reload() recompiles everything',
      () async {
        writeFile('a.dart', 'a-v1');
        writeFile('b.dart', 'b-v1');
        seedApplied();
        final orchestrator = makeOrchestrator();

        final outcome = await orchestrator.restart(targets: [app]);
        expect(outcome, isA<ReloadApplied>());
        expect(compiler.fullCompileCalls, hasLength(1));
        expect(app.calls.last.mode, ApplyMode.hotRestart);

        // After restart, applied is repopulated to current snapshot. No
        // further changes, so next reload is a no-op.
        final second = await orchestrator.reload(targets: [app]);
        expect(second, isA<ReloadNoChange>());
      },
    );

    test(
      'reload() over an in-flight first reload still completes (Pool(1) external + bounded compiler)',
      () async {
        // The orchestrator does not own single-flight; CommandRunner.Pool(1)
        // handles that. But internally, if a caller bypasses Pool and fires
        // two reloads, the pipeline must still be predictable. Here we use
        // FakeCompiler.pendingResult to hold the first compile open, then
        // ensure that after we release it, both calls return cleanly.
        writeFile('main.dart', 'v1');
        seedApplied();
        final orchestrator = makeOrchestrator();
        writeFile('main.dart', 'v2 longer');

        compiler.pendingResult = Completer<void>();
        final f1 = orchestrator.reload(targets: [app]);
        // Don't fire the second one until the first has captured its
        // snapshot — the two compile calls would otherwise interleave the
        // FakeCompiler's single recompileCalls list. The orchestrator
        // captures snap synchronously at the top of reload(); awaiting a
        // microtask is enough to let it past that point.
        await Future<void>.delayed(Duration.zero);

        compiler.pendingResult!.complete();
        final r1 = await f1;
        expect(r1, isA<ReloadApplied>());
      },
    );

    group('targeting', () {
      late FakeAppInstance app2;

      setUp(() {
        app2 = FakeAppInstance(id: 'app2');
      });

      test('a targeted reload reaches only the targeted app', () async {
        writeFile('main.dart', 'v1');
        seedApplied();
        final orch = makeOrchestrator(apps: [app, app2]);
        writeFile('main.dart', 'v2 longer');

        final outcome = await orch.reload(targets: [app]);

        expect(outcome, isA<ReloadApplied>());
        expect(
          (outcome as ReloadApplied).apps,
          [app],
          reason: 'the outcome reports the apps that took the edit',
        );
        expect(app.calls, hasLength(1));
        expect(
          app2.calls,
          isEmpty,
          reason: 'the request named app1; app2 must be left alone',
        );
      });

      test('an untargeted app is not stranded: its next reload still delivers '
          'the earlier edit', () async {
        writeFile('main.dart', 'v1');
        seedApplied();
        final orch = makeOrchestrator(apps: [app, app2]);
        writeFile('main.dart', 'v2 longer');

        await orch.reload(targets: [app]);

        // No further edits. app2 never received v2; a reload aimed at it must
        // still recompile and deliver main.dart, not report "no changes".
        final second = await orch.reload(targets: [app2]);

        expect(second, isA<ReloadApplied>());
        expect(
          (second as ReloadApplied).filesRecompiled,
          contains(uriFor('main.dart')),
        );
        expect(
          compilers['app2']!.recompileCalls.last.invalidated,
          contains(uriFor('main.dart')),
          reason: "app2's own compiler must be told to re-emit what it lacks",
        );
        expect(app2.calls, hasLength(1));

        // Now both are current: a reload of everything has nothing to do.
        final third = await orch.reload(targets: [app, app2]);
        expect(third, isA<ReloadNoChange>());
      });

      test('a targeted restart restarts only the target, and the untargeted '
          'app still reloads correctly afterwards', () async {
        writeFile('main.dart', 'v1');
        seedApplied();
        final orch = makeOrchestrator(apps: [app, app2]);
        writeFile('main.dart', 'v2 longer');

        final outcome = await orch.restart(targets: [app]);

        expect(outcome, isA<ReloadApplied>());
        expect(app.calls.last.mode, ApplyMode.hotRestart);
        expect(
          app2.calls,
          isEmpty,
          reason: 'the request named app1; app2 must not restart',
        );

        // The restart marked everything applied FOR app1 ONLY. app2 is still
        // running v1, and a reload aimed at it must deliver v2.
        final second = await orch.reload(targets: [app2]);
        expect(second, isA<ReloadApplied>());
        expect(
          (second as ReloadApplied).filesRecompiled,
          contains(uriFor('main.dart')),
        );
        expect(app2.calls, hasLength(1));
        expect(app2.calls.last.mode, ApplyMode.hotReload);
      });

      test(
        'isEmpty is judged against the targets, not the other apps',
        () async {
          writeFile('main.dart', 'v1');
          seedApplied();
          final orch = makeOrchestrator(apps: [app, app2]);
          writeFile('main.dart', 'v2 longer');

          await orch.reload(targets: [app]);

          // app1 already has v2; declaring main.dart at it is a semantic no-op
          // even though app2 still lags.
          final outcome = await orch.reload(
            declared: {uriFor('main.dart')},
            targets: [app],
          );
          expect(outcome, isA<ReloadApplied>());
          expect((outcome as ReloadApplied).isEmpty, isTrue);
        },
      );

      test(
        'a lagging app receives the dependent recompilations it missed',
        () async {
          // `b.dart` inlines a const from `a.dart`. Editing `a` changes what `b`
          // compiles to while leaving b's own bytes untouched — so no per-file
          // version record can ever flag `b` as something an app is missing. The
          // only thing that re-derives it is a compiler whose accepted baseline
          // still holds the old `a`, which is exactly what per-app compilers are.
          writeFile('a.dart', 'a-v1');
          writeFile('b.dart', 'b-v1');
          seedApplied();

          final tree = FakeSourceTree()
            ..add(uriFor('a.dart'))
            ..add(uriFor('b.dart'), inlinesFrom: {uriFor('a.dart')});
          final launched = {
            for (final uri in tree.versions.keys) uri: tree.imageOf(uri),
          };
          for (final id in ['app1', 'app2']) {
            compilers.remove(id);
          }
          final depCompilers = {
            for (final id in ['app1', 'app2'])
              id: DependencyFakeCompiler(tree)..seedFromTree(),
          };
          final orch = ReloadOrchestrator(
            workspace: workspace,
            units: [
              for (final a in [app, app2])
                SessionReloader(
                  id: a.id,
                  compiler: depCompilers[a.id]!,
                  applied: AppliedVersions.from(applied),
                  app: a,
                ),
            ],
            entrypoint: 'package:app/main.dart',
          );

          writeFile('a.dart', 'a-v2 longer');
          tree.edit(uriFor('a.dart'));

          // app1 reloads first and receives a AND b.
          await orch.reload(targets: [app]);
          // app2 reloads afterwards, against its own untouched baseline.
          await orch.reload(targets: [app2]);

          for (final target in [app, app2]) {
            final live = liveImageOf(
              target,
              tree: tree,
              launchedWith: launched,
            );
            expect(
              live[uriFor('b.dart')],
              LibImage(own: 1, inlined: {uriFor('a.dart'): 2}),
              reason:
                  '${target.id} must be running b recompiled against the '
                  'new a; a shared compiler would have withheld it from '
                  'whichever app reloaded second',
            );
          }
        },
      );

      test(
        'a replaced process keeps its unit, its compiler and its record',
        () async {
          writeFile('main.dart', 'v1');
          seedApplied();
          final orch = makeOrchestrator(apps: [app, app2]);
          final unitBefore = orch.unitFor(app);

          // What the relauncher does: same id, new process.
          final replacement = FakeAppInstance(id: 'app1');
          orch.syncLiveApps([replacement, app2]);

          expect(orch.unitFor(replacement), same(unitBefore));
          expect(orch.apps, [replacement, app2]);

          writeFile('main.dart', 'v2 longer');
          await orch.reload(targets: [replacement]);
          expect(replacement.calls, hasLength(1));
          expect(app.calls, isEmpty, reason: 'the dead instance is not driven');
        },
      );

      test(
        'an app whose VM service never came back stops being a target',
        () async {
          writeFile('main.dart', 'v1');
          seedApplied();
          final orch = makeOrchestrator(apps: [app, app2]);
          final unitBefore = orch.unitFor(app2);

          // The relauncher reports only the apps that reconnected.
          orch.syncLiveApps([app]);

          expect(orch.apps, [
            app,
          ], reason: 'a disconnected app is not something to reload');
          expect(
            orch.unitFor(app2),
            same(unitBefore),
            reason: 'its compiler and record survive for when it returns',
          );

          // An unaddressed reload reaches the healthy app and does not fail on
          // the dead one.
          writeFile('main.dart', 'v2 longer');
          final outcome = await orch.reload(targets: orch.apps);
          expect(outcome, isA<ReloadApplied>());
          expect(app2.calls, isEmpty);

          // And it comes back whole when it reconnects.
          final back = FakeAppInstance(id: 'app2');
          orch.syncLiveApps([app, back]);
          expect(orch.apps, [app, back]);
          final second = await orch.reload(targets: [back]);
          expect(
            second,
            isA<ReloadApplied>(),
            reason: 'its record still knew what it was missing',
          );
          expect(
            (second as ReloadApplied).filesRecompiled,
            contains(uriFor('main.dart')),
          );
        },
      );

      test('a target the orchestrator does not know is a loud error', () async {
        writeFile('main.dart', 'v1');
        seedApplied();
        final orch = makeOrchestrator(apps: [app]);

        expect(
          () => orch.reload(targets: [FakeAppInstance(id: 'ghost')]),
          throwsStateError,
        );
        expect(() => orch.restart(targets: []), throwsStateError);
      });
    });
  });
}
