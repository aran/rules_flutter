import 'dart:io';

import 'package:flutter_bazel_dev_tool/hot_reload/app_instance.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/applied_versions.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/compiler.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/flutter_error_report.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/package_uri_resolver.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/session_reloader.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/workspace.dart';
import 'package:flutter_bazel_dev_tool/vm_service_client.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

import 'fakes.dart';

void main() {
  group('SessionReloader', () {
    late Directory tmp;
    late Workspace workspace;
    late FakeCompiler compiler;
    late FakeAppInstance app;
    late SessionReloader unit;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('session_reloader_test_');
      Directory(p.join(tmp.path, 'lib')).createSync();
      workspace = Workspace(
        resolver: PackageUriResolver(
          workspaceRoot: tmp.path,
          sourcePackages: const [(name: 'app', libRoot: '')],
        ),
      );
      compiler = FakeCompiler();
      app = FakeAppInstance(id: 'app1');
      unit = SessionReloader(
        id: 'app1',
        compiler: compiler,
        applied: AppliedVersions(),
        app: app,
      );
    });

    tearDown(() async => tmp.delete(recursive: true));

    void writeFile(String relPath, String content) {
      File(p.join(tmp.path, 'lib', relPath)).writeAsStringSync(content);
    }

    String uriFor(String relPath) => 'package:app/$relPath';

    void seed() {
      final snap = workspace.snapshot();
      unit.applied.markApplied(snap, files: snap.fileUris.toSet());
    }

    test('pendingAt reports what this app lacks', () async {
      writeFile('main.dart', 'v1');
      seed();
      expect(unit.pendingAt(workspace.snapshot()), isEmpty);

      writeFile('main.dart', 'v2 longer');
      expect(unit.pendingAt(workspace.snapshot()), {uriFor('main.dart')});
    });

    test('pendingAt unions the caller-declared set', () {
      writeFile('main.dart', 'v1');
      seed();
      expect(
        unit.pendingAt(workspace.snapshot(), declared: {uriFor('other.dart')}),
        {uriFor('other.dart')},
      );
    });

    test(
      'a reload compiles an increment, a restart compiles the whole program',
      () async {
        await unit.compile(
          invalidated: {uriFor('main.dart')},
          entrypoint: 'e',
          mode: ApplyMode.hotReload,
        );
        expect(compiler.recompileCalls, hasLength(1));
        expect(compiler.fullCompileCalls, isEmpty);

        await unit.compile(
          invalidated: {uriFor('main.dart')},
          entrypoint: 'e',
          mode: ApplyMode.hotRestart,
        );
        expect(compiler.fullCompileCalls, hasLength(1));
        expect(
          compiler.recompileCalls,
          hasLength(1),
          reason: 'a restart does not also ask for an increment',
        );
      },
    );

    // A unit whose FIRST compile failed carries that failure until its source
    // compiles — and it is the compile that settles it, not the apply. What
    // the failure claims is that this app's source has never compiled, and an
    // apply that fails afterwards is a separate report about a separate
    // thing: the compiler rolls back, the record holds, the file stays
    // pending, and the next reload re-offers it. Clearing on the apply would
    // leave the unit claiming its source is broken while the compiler has
    // just proved otherwise.
    test('a compile that succeeds clears the never-compiled state even when '
        'the apply fails', () async {
      unit.baselineFailure = 'main.dart:1:8: Error: Bad syntax';

      final failed = await unit.compile(
        invalidated: {uriFor('main.dart')},
        entrypoint: 'e',
        mode: ApplyMode.hotReload,
      );
      expect(failed, isA<CompileSucceeded>());
      expect(unit.baselineFailure, isNull);

      app.nextOutcome = const ApplyFailed('the VM refused it');
      writeFile('main.dart', 'v1');
      await unit.applyAndSettle(
        '/tmp/d.dill',
        mode: ApplyMode.hotReload,
        snapshot: workspace.snapshot(),
        invalidated: {uriFor('main.dart')},
      );
      expect(
        unit.baselineFailure,
        isNull,
        reason: 'the source compiled; the apply is a different verdict',
      );
      expect(
        unit.pendingAt(workspace.snapshot()),
        {uriFor('main.dart')},
        reason:
            'and the edit is still owed to the app, so nothing is lost '
            'by settling the compile state early',
      );
    });

    test(
      'a compile that fails leaves the never-compiled state in place',
      () async {
        unit.baselineFailure = 'main.dart:1:8: Error: Bad syntax';
        compiler.nextOutcome = const CompileFailed('still broken');

        await unit.compile(
          invalidated: {uriFor('main.dart')},
          entrypoint: 'e',
          mode: ApplyMode.hotReload,
        );
        expect(unit.baselineFailure, isNotNull);
      },
    );

    test(
      'a successful apply commits the compiler AND advances the record',
      () async {
        writeFile('main.dart', 'v1');
        final snap = workspace.snapshot();

        final outcome = await unit.applyAndSettle(
          '/tmp/d.dill',
          mode: ApplyMode.hotReload,
          snapshot: snap,
          invalidated: {uriFor('main.dart')},
        );

        expect(outcome, isA<Applied>());
        expect(compiler.commitCount, 1);
        expect(compiler.rollbackCount, 0);
        expect(unit.applied.versionOf(uriFor('main.dart')), isNotNull);
        expect(unit.pendingAt(workspace.snapshot()), isEmpty);
      },
    );

    test(
      'a refused apply rolls the compiler back and leaves the record',
      () async {
        writeFile('main.dart', 'v1');
        final snap = workspace.snapshot();
        app.nextOutcome = const ApplyFailed('device said no');

        final outcome = await unit.applyAndSettle(
          '/tmp/d.dill',
          mode: ApplyMode.hotReload,
          snapshot: snap,
          invalidated: {uriFor('main.dart')},
        );

        expect(outcome, isA<ApplyFailed>());
        expect(compiler.rollbackCount, 1);
        expect(compiler.commitCount, 0);
        expect(unit.applied.versionOf(uriFor('main.dart')), isNull);
        expect(
          unit.pendingAt(workspace.snapshot()),
          {uriFor('main.dart')},
          reason: 'the work must still be offered next time',
        );
      },
    );

    test(
      'an apply the app threw on commits the compiler AND advances the record',
      () async {
        // The code IS live: the VM took it and the next frame threw. Rolling the
        // compiler back here would tell it to discard exactly what the app is
        // running, so its baseline would describe a program no app has and the
        // next reload's delta would be computed against that fiction.
        writeFile('main.dart', 'v1');
        final snap = workspace.snapshot();
        app.nextOutcome = const AppliedThenThrew(
          FlutterErrorReport({'description': 'Null is not a String'}),
        );

        final outcome = await unit.applyAndSettle(
          '/tmp/d.dill',
          mode: ApplyMode.hotReload,
          snapshot: snap,
          invalidated: {uriFor('main.dart')},
        );

        expect(
          outcome,
          isA<AppliedThenThrew>(),
          reason: 'the caller still hears about the error',
        );
        expect(compiler.commitCount, 1);
        expect(compiler.rollbackCount, 0);
        expect(unit.applied.versionOf(uriFor('main.dart')), isNotNull);
        expect(
          unit.pendingAt(workspace.snapshot()),
          isEmpty,
          reason:
              'the app already has this file; re-offering it would be a '
              'delta against a baseline it does not have',
        );
      },
    );

    test(
      'a restart the app threw on still re-bases the record on disk',
      () async {
        // A broken main() throws on the first frame of the restarted isolate —
        // and the restart still happens, so the record must be cleared before
        // it is re-marked, exactly as a clean restart does.
        writeFile('gone.dart', 'v1');
        seed();
        File(p.join(tmp.path, 'lib', 'gone.dart')).deleteSync();
        writeFile('main.dart', 'v1');
        app.nextOutcome = const AppliedThenThrew(
          FlutterErrorReport({'description': 'boom'}),
        );

        final snap = workspace.snapshot();
        await unit.applyAndSettle(
          '/tmp/d.dill',
          mode: ApplyMode.hotRestart,
          snapshot: snap,
          invalidated: snap.fileUris.toSet(),
        );

        expect(compiler.commitCount, 1);
        expect(compiler.rollbackCount, 0);
        expect(
          unit.applied.versionOf(uriFor('gone.dart')),
          isNull,
          reason: 'the restarted app is running what is on disk now',
        );
        expect(unit.applied.versionOf(uriFor('main.dart')), isNotNull);
      },
    );

    test('a timed-out apply is treated as a failure', () async {
      writeFile('main.dart', 'v1');
      app.nextOutcome = const ApplyTimedOut();

      final outcome = await unit.applyAndSettle(
        '/tmp/d.dill',
        mode: ApplyMode.hotReload,
        snapshot: workspace.snapshot(),
        invalidated: {uriFor('main.dart')},
      );

      expect(outcome, isA<ApplyTimedOut>());
      expect(compiler.rollbackCount, 1);
      expect(compiler.commitCount, 0);
    });

    test('a restart clears the record before marking the new one', () async {
      writeFile('gone.dart', 'v1');
      seed();
      expect(unit.applied.versionOf(uriFor('gone.dart')), isNotNull);
      File(p.join(tmp.path, 'lib', 'gone.dart')).deleteSync();
      writeFile('main.dart', 'v1');

      final snap = workspace.snapshot();
      await unit.applyAndSettle(
        '/tmp/d.dill',
        mode: ApplyMode.hotRestart,
        snapshot: snap,
        invalidated: snap.fileUris.toSet(),
      );

      expect(
        unit.applied.versionOf(uriFor('gone.dart')),
        isNull,
        reason: 'a restart re-bases the record on what is on disk now',
      );
      expect(unit.applied.versionOf(uriFor('main.dart')), isNotNull);
    });

    test(
      'discard rolls the compiler back without touching the record',
      () async {
        writeFile('main.dart', 'v1');
        seed();
        await unit.discard();
        expect(compiler.rollbackCount, 1);
        expect(unit.pendingAt(workspace.snapshot()), isEmpty);
      },
    );

    test('the app can be replaced without disturbing the record', () async {
      writeFile('main.dart', 'v1');
      seed();
      final replacement = FakeAppInstance(id: 'app1');
      unit.app = replacement;

      await unit.applyAndSettle(
        '/tmp/d.dill',
        mode: ApplyMode.hotReload,
        snapshot: workspace.snapshot(),
        invalidated: const {},
      );

      expect(replacement.calls, hasLength(1));
      expect(app.calls, isEmpty);
    });

    group('per-unit baselines over one source tree', () {
      test(
        'a lagging unit re-derives the dependents it never received',
        () async {
          // `b` inlines a const from `a`, so editing `a` changes b's compiled
          // form while leaving b's own bytes untouched.
          final tree = FakeSourceTree()
            ..add('package:app/a.dart')
            ..add('package:app/b.dart', inlinesFrom: {'package:app/a.dart'});

          SessionReloader makeUnit(String id) {
            final c = DependencyFakeCompiler(tree)..seedFromTree();
            return SessionReloader(
              id: id,
              compiler: c,
              applied: AppliedVersions(),
              app: FakeAppInstance(id: id),
            );
          }

          final x = makeUnit('x');
          final y = makeUnit('y');
          final launched = {
            for (final uri in tree.versions.keys) uri: tree.imageOf(uri),
          };

          tree.edit('package:app/a.dart');

          // X reloads. Its compiler holds the old `a`, so the delta carries `b`.
          final xDill =
              await x.compile(
                    invalidated: {'package:app/a.dart'},
                    entrypoint: 'e',
                    mode: ApplyMode.hotReload,
                  )
                  as CompileSucceeded;
          await x.applyAndSettle(
            xDill.dillPath,
            mode: ApplyMode.hotReload,
            snapshot: workspace.snapshot(),
            invalidated: {'package:app/a.dart'},
          );

          // Y reloads later, against its OWN untouched baseline.
          final yDill =
              await y.compile(
                    invalidated: {'package:app/a.dart'},
                    entrypoint: 'e',
                    mode: ApplyMode.hotReload,
                  )
                  as CompileSucceeded;
          await y.applyAndSettle(
            yDill.dillPath,
            mode: ApplyMode.hotReload,
            snapshot: workspace.snapshot(),
            invalidated: {'package:app/a.dart'},
          );

          for (final unit in [x, y]) {
            final live = liveImageOf(
              unit.app as FakeAppInstance,
              tree: tree,
              launchedWith: launched,
            );
            expect(
              live['package:app/b.dart'],
              const LibImage(own: 1, inlined: {'package:app/a.dart': 2}),
              reason:
                  '${unit.id} must be running b recompiled against the '
                  'new a — a shared compiler would have withheld it',
            );
          }
        },
      );
    });
  });

  /// The bookkeeping over the real client rather than a canned outcome.
  ///
  /// [SessionReloader.applyAndSettle]'s correctness rests on the verdict it is
  /// handed being true about what the VM holds, and no test of a
  /// [FakeAppInstance] can check that: the fake is *told* the answer. Wiring
  /// `VmServiceClient` → `VmServiceAppInstance` → `SessionReloader` over a real
  /// devFS is what makes the VM's behaviour, not a test's assumption, decide
  /// whether the compiler rolls back.
  group('SessionReloader over a real VM service connection', () {
    late Directory tmp;
    late Workspace workspace;
    late FakeCompiler compiler;
    late FakeDevFS devFS;
    late String dillPath;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('reloader_vm_');
      Directory(p.join(tmp.path, 'lib')).createSync();
      Directory(p.join(tmp.path, 'devfs')).createSync();
      workspace = Workspace(
        resolver: PackageUriResolver(
          workspaceRoot: tmp.path,
          sourcePackages: const [(name: 'app', libRoot: '')],
        ),
      );
      compiler = FakeCompiler();
      devFS = await FakeDevFS.start(Directory(p.join(tmp.path, 'devfs')));
      dillPath = p.join(tmp.path, 'out.dill');
      File(dillPath).writeAsBytesSync([1, 2, 3]);
      File(p.join(tmp.path, 'lib', 'main.dart')).writeAsStringSync('v1');
    });

    tearDown(() async {
      await devFS.close();
      await tmp.delete(recursive: true);
    });

    Future<SessionReloader> reloaderOver(FakeVmService fake) async {
      final client = VmServiceClient(connector: (_) async => fake);
      await client.connect(devFS.serviceUri);
      return SessionReloader(
        id: 'app1',
        compiler: compiler,
        applied: AppliedVersions(),
        app: VmServiceAppInstance(id: 'app1', client: client),
      );
    }

    test('a reassemble that throws after the VM took the kernel commits the '
        'compiler', () async {
      // `reloadSources` succeeds — the new code is in the VM — and the
      // rebuild that follows it throws. Reporting that as a
      // refusal rolls the compiler's baseline back to a program the app is no
      // longer running, and every later delta is computed against that fiction.
      final fake = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      )..devFSUri = devFS.uri;
      // What a real refusal looks like on this wire: an extension handler that
      // fails crosses the VM service as a JSON-RPC error, which
      // `package:vm_service` completes with a throw.
      fake.extensionErrors['ext.flutter.reassemble'] = RPCError(
        'ext.flutter.reassemble',
        113,
        'Isolate must be runnable',
      );
      final unit = await reloaderOver(fake);
      final snap = workspace.snapshot();

      final outcome = await unit.applyAndSettle(
        dillPath,
        mode: ApplyMode.hotReload,
        snapshot: snap,
        invalidated: {'package:app/main.dart'},
      );

      expect(
        fake.reloadSourcesCalled,
        isTrue,
        reason:
            'the kernel reached the VM — without that this test would '
            'be asserting about a reload that never happened',
      );
      expect(
        outcome,
        isA<AppliedThenThrew>(),
        reason: 'the code is live and the app then failed',
      );
      expect(
        compiler.rollbackCount,
        0,
        reason:
            'rolling back would tell the compiler to forget what the VM '
            'is executing',
      );
      expect(compiler.commitCount, 1);
      expect(
        unit.applied.versionOf('package:app/main.dart'),
        isNotNull,
        reason: 'the app has this file now, so the record must say so',
      );
    });
  });
}
