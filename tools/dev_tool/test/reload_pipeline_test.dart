/// Drives [ReloadPipeline] the way production does — through the `app.hotReload`
/// / `app.restart` handlers [SessionHost.registerReloadCommands] wires up —
/// with a real [ReloadOrchestrator] and [AssetTracker] over fakes.
///
/// The response maps these produce are the dev tool's contract with every
/// client it has: the machine protocol, the HTTP control channel, and whatever
/// agent is reading `message` to decide whether its edit went live.
import 'dart:async';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/command_report.dart';
import 'package:flutter_bazel_dev_tool/compiler_config.dart';
import 'package:flutter_bazel_dev_tool/device.dart' as device;
import 'package:flutter_bazel_dev_tool/frontend_server.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/app_instance.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/asset_bundle.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/compiler.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/package_uri_resolver.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/applied_versions.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/reload_orchestrator.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/session_reloader.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/workspace.dart';
import 'package:flutter_bazel_dev_tool/logging.dart';
import 'package:flutter_bazel_dev_tool/reload_pipeline.dart';
import 'package:flutter_bazel_dev_tool/reload_strategy.dart';
import 'package:flutter_bazel_dev_tool/session.dart';
import 'package:flutter_bazel_dev_tool/session_host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fakes.dart';

/// Enough of a config to construct a [FrontendServer] that is never started.
/// The web-legacy branch's null checks are about the *presence* of a compiler,
/// not about anything it can do.
final _stubConfig = NativeCompilerConfig(patchedSdkRoot: '');

/// Records what it was asked to apply and answers with [next].
class _RecordingStrategy implements ReloadStrategy {
  StrategyOutcome next = const StrategyApplied(1);
  final List<Set<String>> assetCalls = [];

  /// Which sessions each [applyAssets] call was aimed at, by appId.
  final List<List<String>> assetRecipients = [];

  @override
  Future<StrategyOutcome> applyReload(
    CompileResult result,
    List<DeviceSession> sessions,
  ) async => next;

  @override
  Future<StrategyOutcome> applyRestart(
    CompileResult result,
    List<DeviceSession> sessions,
  ) async => next;

  @override
  Future<StrategyOutcome> applyAssets(
    Set<String> changed,
    List<DeviceSession> sessions,
  ) async {
    assetCalls.add(changed);
    assetRecipients.add([for (final s in sessions) s.appId]);
    return next;
  }
}

class _Harness {
  final Directory tmp;
  final SessionHost host;
  final ReloadPipeline pipeline;
  final FakeCompiler compiler;
  final Workspace workspace;

  /// The orchestrator's apps. [app] is the first, which single-app tests use.
  final List<FakeAppInstance> apps;
  FakeAppInstance get app => apps.first;

  final bool _withOrchestrator;

  _Harness._(
    this.tmp,
    this.host,
    this.pipeline,
    this.compiler,
    this.workspace,
    this.apps,
    this._withOrchestrator,
  );

  static Future<_Harness> create({
    bool withOrchestrator = true,
    List<FakeAppInstance>? apps,
  }) async {
    final tmp = await Directory.systemTemp.createTemp('reload_pipeline_');
    Directory(p.join(tmp.path, 'lib')).createSync();
    final host = SessionHost(
      isMachine: false,
      logger: Logger('test.reload_pipeline'),
    );
    final pipeline = ReloadPipeline(host: host);
    host.registerReloadCommands(pipeline);

    final resolver = PackageUriResolver(
      workspaceRoot: tmp.path,
      sourcePackages: const [(name: 'app', libRoot: '')],
    );
    final workspace = Workspace(resolver: resolver);
    final compiler = FakeCompiler();

    pipeline.resolver = resolver;
    pipeline.workspaceView = workspace;
    pipeline.entrypoint = 'package:app/main.dart';
    final harness = _Harness._(
      tmp,
      host,
      pipeline,
      compiler,
      workspace,
      apps ?? [FakeAppInstance(id: 'app1')],
      withOrchestrator,
    );
    if (withOrchestrator) harness._wireOrchestrator();
    return harness;
  }

  void _wireOrchestrator() {
    pipeline.orchestrator = ReloadOrchestrator(
      workspace: workspace,
      // One unit per app, each with its own compiler — except that these tests
      // assert on a single [compiler], so they share this one deliberately.
      // What they cover is the pipeline's dispatch, not the compiler isolation
      // that reload_orchestrator_test owns.
      units: [
        for (final a in apps)
          SessionReloader(
            id: a.id,
            compiler: compiler,
            applied: AppliedVersions.from(pipeline.appliedVersions),
            app: a,
          ),
      ],
      entrypoint: 'package:app/main.dart',
    );
  }

  /// A session in [SessionHost.sessions] for [appId], so `appId` params have
  /// something to resolve against, the way a real run's launch loop appends
  /// one per device.
  DeviceSession addSession(String appId) {
    final session = DeviceSession(
      device: device.MacOSDevice(),
      appInstance: device.AppInstance(process: FakeProcess()),
      vmClient: null,
      appId: appId,
    );
    host.sessions.add(session);
    return session;
  }

  Future<void> dispose() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  }

  void writeSource(String relPath, String content) {
    final f = File(p.join(tmp.path, 'lib', relPath));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  void seedApplied() {
    final snap = pipeline.workspaceView!.snapshot();
    pipeline.appliedVersions.markApplied(snap, files: snap.fileUris.toSet());
    // The assembler seeds the shared baseline and THEN constructs the
    // orchestrator, whose constructor copies it per app. Mirror that order:
    // reconstruct the orchestrator over the now-seeded baseline.
    if (_withOrchestrator) _wireOrchestrator();
  }

  Future<Map<String, dynamic>> hotReload([Map<String, dynamic>? params]) =>
      host.commandRunner.run('app.hotReload', params ?? {});

  Future<Map<String, dynamic>> restart([Map<String, dynamic>? params]) =>
      host.commandRunner.run('app.restart', params ?? {});
}

/// A bundle at `<tmp>/bundle` whose `assets/message.txt` maps back to a
/// real source file at `<tmp>/assets/message.txt`, which is what
/// [AssetBundle.sourceOf] resolves and the tracker watches.
///
/// Edits below need not change the file's size: the tracker identifies an
/// asset source by a digest of its contents, so a same-length write inside
/// one millisecond reads as the change it is.
Future<AssetTracker> seedBundle(Directory tmp, String contents) async {
  Directory(p.join(tmp.path, 'assets')).createSync(recursive: true);
  Directory(p.join(tmp.path, 'bundle', 'assets')).createSync(recursive: true);
  File(p.join(tmp.path, 'assets', 'message.txt')).writeAsStringSync(contents);
  File(
    p.join(tmp.path, 'bundle', 'assets', 'message.txt'),
  ).writeAsStringSync(contents);
  return AssetTracker(
    AssetBundle(
      directory: p.join(tmp.path, 'bundle'),
      workspaceRoot: tmp.path,
    ),
    builtBefore: DateTime.now().add(const Duration(hours: 1)),
  );
}

/// A [FakeProcess] whose stdin is watched line by line, so a test can answer
/// the compiler's requests as they arrive.
///
/// Subscribes at construction: [FakeProcess.stdinLines] is a broadcast stream,
/// so anything written before a listener attaches is dropped, and the compiler
/// can write its first request the moment it is started.
class _ScriptedProcess extends FakeProcess {
  void Function(String line) onLine = (_) {};

  _ScriptedProcess() {
    stdinLines.listen((line) => onLine(line));
  }
}

/// A frontend server backed by a scriptable fake process. The web branch's
/// full restart runs a real compile, so a server that merely *exists* — which
/// is all the refusal tests need — cannot reach it.
({FrontendServer server, _ScriptedProcess process}) startedServer() {
  final process = _ScriptedProcess();
  return (
    server: FrontendServer(
      dartaotruntimePath: '/fake/dartaotruntime',
      frontendServerPath: '/fake/frontend_server.dart.snapshot',
      config: _stubConfig,
      packageConfig: '/fake/package_config.json',
      processFactory: (exe, args) async => process,
    ),
    process: process,
  );
}

/// The two lines a frontend server answers a clean compile with: the boundary
/// key, then that key with the dill and an error count of zero.
void emitCleanCompile(FakeProcess process) {
  process.emitStdout('result k');
  process.emitStdout('k /tmp/out.dill 0');
}

void main() {
  group('readiness', () {
    // The race this gate exists for: `app.started` is emitted from the launch
    // loop, and the pipeline is assembled after it. A client answering that
    // event must queue, not be told hot reload is broken.
    test('an unavailable pipeline answers with its reason', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      h.pipeline.ready.signalUnavailable('Initial compile failed.');

      // A refusal is still a report: it carries the verdict, and it is the one
      // failure that can say for certain the app kept its old code, since the
      // command stopped before anything was delivered. That certainty is what
      // `reportReloadCommand` gates its reassurance on.
      const refused = {
        'succeeded': false,
        'runningCode': 'unchanged',
        'error': 'Initial compile failed.',
      };
      expect(await h.hotReload(), refused);
      expect(await h.restart(), refused);
    });

    test('a ready pipeline runs the command', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      h.pipeline.ready.signalReady();

      expect(
        await h.hotReload(),
        containsPair('message', contains('Hot reload')),
      );
    });

    // A pipeline whose bazel build failed is armed rather than settled: the
    // request that finds it is the event that builds again. Nothing here is on
    // a timer — the tests below drive it with requests, which is all production
    // does.
    test('a request on a retryable pipeline assembles and then runs', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      h.pipeline.ready.signalRetryable('the build failed');
      var attempts = 0;
      h.pipeline.reassemble = () async {
        attempts++;
        h.pipeline.reassemble = null;
        h.pipeline.ready.signalReady();
      };

      expect(
        await h.hotReload(),
        containsPair('message', contains('Hot reload')),
      );
      expect(attempts, 1);
      expect(
        h.pipeline.awaitingAssembly,
        isFalse,
        reason:
            'a pipeline that assembled owes no build, and a watcher that '
            'is told otherwise wakes it on every edit for the rest of the run',
      );
    });

    test('an attempt that fails again answers with the new reason', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      h.pipeline.ready.signalRetryable('the build failed');
      h.pipeline.reassemble = () async =>
          h.pipeline.ready.signalRetryable('the build failed again');

      expect(
        await h.hotReload(),
        containsPair('error', 'the build failed again'),
      );
      expect(
        h.pipeline.ready.isRetryable,
        isTrue,
        reason: 'still curable, so the next request still gets an attempt',
      );
    });

    // Builds take seconds and saves take milliseconds: a save that is still
    // broken starts attempt one, the user saves the FIX while it is building,
    // and the reload that fix owes queues behind it. If that second
    // request settled for attempt one's verdict it would report a build of a
    // tree that never contained the fix — and nothing would try again, because
    // the event that would have driven the next attempt was just spent on the
    // wrong answer.
    test('a request that queued behind an attempt gets its own', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      h.pipeline.ready.signalRetryable('the build failed');

      var attempts = 0;
      final firstAttemptStarted = Completer<void>();
      final releaseFirstAttempt = Completer<void>();
      h.pipeline.reassemble = () async {
        attempts++;
        if (attempts == 1) {
          firstAttemptStarted.complete();
          await releaseFirstAttempt.future;
          // The tree it read was still broken.
          h.pipeline.ready.signalRetryable('the build failed');
          return;
        }
        // The second attempt reads the fixed tree.
        h.pipeline.reassemble = null;
        h.pipeline.ready.signalReady();
      };

      final broken = h.hotReload();
      await firstAttemptStarted.future;
      // The watcher reads this to decide whether an edit it cannot map is
      // worth a request. An attempt clears `reassemble` as it starts, so if
      // this went false while one was running, the save that fixes the code —
      // which usually lands inside the build it is fixing — would be dropped
      // before it reached the queue above, and nothing would ask again.
      expect(h.pipeline.awaitingAssembly, isTrue);
      final fixed = h.hotReload();
      releaseFirstAttempt.complete();

      expect(await broken, containsPair('error', 'the build failed'));
      expect(
        await fixed,
        containsPair('message', contains('Hot reload')),
        reason:
            'the reload the fix owes must build the fixed tree, not '
            'report the verdict of a build that began before it existed',
      );
      expect(attempts, 2);
    });

    test(
      'two requests on one retryable pipeline do not build at once',
      () async {
        final h = await _Harness.create();
        addTearDown(h.dispose);
        h.pipeline.ready.signalRetryable('the build failed');

        var running = 0;
        var overlapped = false;
        h.pipeline.reassemble = () async {
          running++;
          if (running > 1) overlapped = true;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          running--;
          h.pipeline.ready.signalRetryable('the build failed');
        };

        await Future.wait([h.hotReload(), h.restart()]);
        expect(overlapped, isFalse);
      },
    );

    test(
      'an attempt that throws settles the gate with what went wrong',
      () async {
        // Assembly is documented never to throw. If one ever does, the gate it
        // reopened would never settle and every later request would wait out the
        // full 90-second timeout before answering "still starting up".
        final h = await _Harness.create();
        addTearDown(h.dispose);
        h.pipeline.ready.signalRetryable('the build failed');
        h.pipeline.reassemble = () async => throw StateError('assembler bug');

        final answer = await h.hotReload();
        expect(answer['error'], contains('assembler bug'));
        expect(h.pipeline.ready.isSettled, isTrue);
        expect(
          h.pipeline.ready.isRetryable,
          isFalse,
          reason: 'a bug in the assembler is not something a save can cure',
        );
      },
    );
  });

  group('orchestrator branch', () {
    test('a real edit reports what was recompiled', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      h.writeSource('main.dart', 'void main() {}');
      h.seedApplied();
      h.pipeline.ready.signalReady();
      h.writeSource('main.dart', 'void main() { print("edited"); }');

      final response = await h.hotReload();

      expect(response['message'], 'Hot reload successful');
      expect(response['filesRecompiled'], ['package:app/main.dart']);
      expect(response['isEmpty'], isFalse);
    });

    test('an untouched tree reports no changes', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      h.writeSource('main.dart', 'void main() {}');
      h.seedApplied();
      h.pipeline.ready.signalReady();

      expect(await h.hotReload(), {
        'succeeded': true,
        // A no-op reload succeeded *and* left the app on the code it had.
        // Success and "the code moved" are different questions, and this is
        // the case where their answers differ.
        'runningCode': 'unchanged',
        // The request named no app, so it addressed every app there is —
        // reported as the resolved set rather than left for the reader to
        // infer from an absent field.
        'appIds': ['app1'],
        'message': 'Hot reload successful (no changes detected)',
      });
    });

    test('a compile failure carries its diagnostics', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      h.writeSource('main.dart', 'void main() {}');
      h.seedApplied();
      h.pipeline.ready.signalReady();
      h.writeSource('main.dart', 'this is not dart');
      h.compiler.nextOutcome = const CompileFailed("expected ';'");

      final response = await h.hotReload();

      expect(response['message'], 'Compilation failed');
      expect(response['error'], "expected ';'");
    });

    test('an apply failure names the device that refused', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      h.writeSource('main.dart', 'void main() {}');
      h.seedApplied();
      h.pipeline.ready.signalReady();
      h.writeSource('main.dart', 'void main() { print("x"); }');
      h.app.nextOutcome = const ApplyFailed('isolate is gone');

      final response = await h.hotReload();

      expect(response['message'], 'Hot reload failed on some devices');
      // Structured per app, not a flattened string: which app, what status,
      // and — when the app itself reported one — the error beside the text it
      // was rendered from.
      expect(response['perApp'], {
        'app1': {'status': 'failed', 'reason': 'isolate is gone'},
      });
      expect(response['error'], contains('isolate is gone'));
      expect(
        response['error'],
        contains('app1'),
        reason: 'every failing app is named, not only the first',
      );
    });

    test('restart goes through the orchestrator too', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      h.writeSource('main.dart', 'void main() {}');
      h.seedApplied();
      h.pipeline.ready.signalReady();

      expect(await h.restart(), containsPair('message', 'Restart successful'));
      expect(
        h.compiler.fullCompileCalls.single.entrypoint,
        'package:app/main.dart',
      );
    });

    // `fullRestart: false` is how a flutter-run-shaped client asks for a reload
    // through the restart command. Dispatching it to `restart` would do a full
    // recompile and re-run `main()` for what the client asked to be a reload.
    test('app.restart with fullRestart:false is a hot reload', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      h.writeSource('main.dart', 'void main() {}');
      h.seedApplied();
      h.pipeline.ready.signalReady();

      final response = await h.restart({'fullRestart': false});

      expect(response['message'], contains('Hot reload'));
      expect(h.compiler.fullCompileCalls, isEmpty);
    });
  });

  group('targeting', () {
    /// Two running apps, each with a session the way a multi-device run has.
    Future<_Harness> createTwoApps() async {
      final h = await _Harness.create(
        apps: [
          FakeAppInstance(id: 'app1'),
          FakeAppInstance(id: 'app2'),
        ],
      );
      h.addSession('app1');
      h.addSession('app2');
      return h;
    }

    test('app.hotReload with an appId reaches only that app', () async {
      final h = await createTwoApps();
      addTearDown(h.dispose);
      h.writeSource('main.dart', 'void main() {}');
      h.seedApplied();
      h.pipeline.ready.signalReady();
      h.writeSource('main.dart', 'void main() { print("edited"); }');

      final response = await h.hotReload({'appId': 'app1'});

      expect(response['message'], 'Hot reload successful');
      expect(h.apps[0].calls, hasLength(1));
      expect(
        h.apps[1].calls,
        isEmpty,
        reason: 'the request named app1; app2 must be left alone',
      );
    });

    test('app.restart with an appId restarts only that app, and the other '
        'still picks up the edit afterwards', () async {
      final h = await createTwoApps();
      addTearDown(h.dispose);
      h.writeSource('main.dart', 'void main() {}');
      h.seedApplied();
      h.pipeline.ready.signalReady();
      h.writeSource('main.dart', 'void main() { print("edited"); }');

      final response = await h.restart({'appId': 'app1'});

      expect(response['message'], 'Restart successful');
      expect(h.apps[0].calls.last.mode, ApplyMode.hotRestart);
      expect(
        h.apps[1].calls,
        isEmpty,
        reason: 'the request named app1; app2 must not restart',
      );

      // The stranded-baseline case: app2 never received the edit, and its
      // reload must still deliver it rather than reporting no changes.
      final reload = await h.hotReload({'appId': 'app2'});
      expect(reload['message'], 'Hot reload successful');
      expect(reload['filesRecompiled'], ['package:app/main.dart']);
      expect(h.apps[1].calls, hasLength(1));
      expect(h.apps[1].calls.last.mode, ApplyMode.hotReload);
    });

    test(
      'app.restart with fullRestart:false and an appId reloads that app',
      () async {
        final h = await createTwoApps();
        addTearDown(h.dispose);
        h.writeSource('main.dart', 'void main() {}');
        h.seedApplied();
        h.pipeline.ready.signalReady();
        h.writeSource('main.dart', 'void main() { print("edited"); }');

        final response = await h.restart({
          'fullRestart': false,
          'appId': 'app2',
        });

        expect(response['message'], 'Hot reload successful');
        expect(h.compiler.fullCompileCalls, isEmpty);
        expect(h.apps[0].calls, isEmpty);
        expect(h.apps[1].calls, hasLength(1));
      },
    );

    test('an unknown appId is refused on the orchestrator path', () async {
      final h = await createTwoApps();
      addTearDown(h.dispose);
      h.writeSource('main.dart', 'void main() {}');
      h.seedApplied();
      h.pipeline.ready.signalReady();

      // A request naming an app that does not exist is refused before
      // anything is compiled or sent, so it carries the same verdict as any
      // other refusal — including the one promise a refusal can keep.
      expect(await h.hotReload({'appId': 'ghost'}), {
        'succeeded': false,
        'runningCode': 'unchanged',
        'error': 'Unknown appId: ghost',
      });
      expect(await h.restart({'appId': 'ghost'}), {
        'succeeded': false,
        'runningCode': 'unchanged',
        'error': 'Unknown appId: ghost',
      });
      expect(h.apps[0].calls, isEmpty);
      expect(h.apps[1].calls, isEmpty);
    });

    test(
      'an appId whose session has no reload connection is a loud error',
      () async {
        final h = await createTwoApps();
        addTearDown(h.dispose);
        // A session exists but no orchestrator app does — a device whose VM
        // service never came up.
        h.addSession('app3');
        h.writeSource('main.dart', 'void main() {}');
        h.seedApplied();
        h.pipeline.ready.signalReady();

        final response = await h.hotReload({'appId': 'app3'});
        expect(response['error'], contains('app3'));
        expect(response['error'], contains('no reload connection'));
        expect(response['succeeded'], isFalse);
        expect(
          response['runningCode'],
          'unchanged',
          reason:
              'the app never had a reload connection, so nothing reached '
              'it and nothing could have changed under it',
        );
      },
    );

    test(
      'a targeted restart delivers asset evictions to the untargeted app',
      () async {
        final h = await createTwoApps();
        addTearDown(h.dispose);
        h.writeSource('main.dart', 'void main() {}');
        h.seedApplied();
        Directory(p.join(h.tmp.path, 'assets')).createSync(recursive: true);
        Directory(
          p.join(h.tmp.path, 'bundle', 'assets'),
        ).createSync(recursive: true);
        File(
          p.join(h.tmp.path, 'assets', 'message.txt'),
        ).writeAsStringSync('v1');
        File(
          p.join(h.tmp.path, 'bundle', 'assets', 'message.txt'),
        ).writeAsStringSync('v1');
        final strategy = _RecordingStrategy();
        h.pipeline
          ..assetTracker = AssetTracker(
            AssetBundle(
              directory: p.join(h.tmp.path, 'bundle'),
              workspaceRoot: h.tmp.path,
            ),
            // Later than anything the fixture wrote: these cases are about a
            // tree the build consumed, not one edited during assembly.
            builtBefore: DateTime.now().add(const Duration(hours: 1)),
          )
          ..strategy = strategy
          ..rebuildAssets = () async {
            File(
              p.join(h.tmp.path, 'bundle', 'assets', 'message.txt'),
            ).writeAsStringSync(
              File(
                p.join(h.tmp.path, 'assets', 'message.txt'),
              ).readAsStringSync(),
            );
            return true;
          };
        h.pipeline.ready.signalReady();

        File(
          p.join(h.tmp.path, 'assets', 'message.txt'),
        ).writeAsStringSync('version two');
        await h.restart({'appId': 'app1'});

        // app1 re-reads the whole bundle as part of its restart; app2 does not
        // restart, so it must be told its cached copy is stale.
        expect(strategy.assetCalls, [
          {'assets/message.txt'},
        ]);
        expect(strategy.assetRecipients, [
          ['app2'],
        ]);
      },
    );
  });

  group('web-legacy branch', () {
    // No orchestrator is the web DDC shape. Each of these nulls is a real
    // state a failed assembly leaves behind, and the message has to name the
    // right thing rather than blame the nearest missing piece.
    test('no frontend server says so', () async {
      final h = await _Harness.create(withOrchestrator: false);
      addTearDown(h.dispose);
      h.pipeline.ready.signalReady();

      const refused = {
        'succeeded': false,
        'runningCode': 'unchanged',
        'error': 'No frontend server available',
      };
      expect(await h.hotReload(), refused);
      expect(await h.restart(), refused);
    });

    test('a frontend server with no strategy says THAT', () async {
      final h = await _Harness.create(withOrchestrator: false);
      addTearDown(h.dispose);
      h.pipeline.frontendServer = FrontendServer(
        dartaotruntimePath: '/nonexistent',
        frontendServerPath: '/nonexistent',
        config: _stubConfig,
        packageConfig: '/nonexistent',
      );
      h.pipeline.ready.signalReady();

      expect(await h.hotReload(), {
        'succeeded': false,
        'runningCode': 'unchanged',
        'error': 'No reload strategy for this session.',
      });
      expect(await h.restart(), {
        'succeeded': false,
        'runningCode': 'unchanged',
        'error': 'No reload strategy for this session.',
      });
    });

    test('an unknown appId is refused, not silently applied to all', () async {
      final h = await _Harness.create(withOrchestrator: false);
      addTearDown(h.dispose);
      h.pipeline.frontendServer = FrontendServer(
        dartaotruntimePath: '/nonexistent',
        frontendServerPath: '/nonexistent',
        config: _stubConfig,
        packageConfig: '/nonexistent',
      );
      h.pipeline.strategy = _RecordingStrategy();
      h.pipeline.ready.signalReady();

      const refused = {
        'succeeded': false,
        'runningCode': 'unchanged',
        'error': 'Unknown appId: ghost',
      };
      expect(await h.hotReload({'appId': 'ghost'}), refused);
      expect(await h.restart({'appId': 'ghost'}), refused);
    });

    /// Answer every compile request with a clean result, the moment the
    /// request reaches the compiler's stdin.
    ///
    /// Scripted off `stdinLines` rather than emitted straight after the call:
    /// the pipeline awaits the readiness gate, the codegen rebuild and the
    /// asset refresh before it compiles anything, and a `result` line that
    /// arrives before the compiler has a request pending is dropped on the
    /// floor (`_pendingResult?.complete`) — after which the command waits out
    /// its entire response timeout for an answer that already went past.
    void answerCompiles(_ScriptedProcess process) {
      process.onLine = (line) {
        if (line.startsWith('compile ') || line.startsWith('recompile ')) {
          emitCleanCompile(process);
        }
      };
    }

    /// A web pipeline that can actually complete a restart: a compiler that
    /// answers, and a strategy to apply what it produces.
    Future<_Harness> webPipeline(_RecordingStrategy strategy) async {
      final h = await _Harness.create(withOrchestrator: false);
      final (:server, :process) = startedServer();
      await server.start();
      addTearDown(() async {
        process.complete(0);
        await server.shutdown();
        await h.dispose();
      });
      answerCompiles(process);
      h.pipeline
        ..frontendServer = server
        ..strategy = strategy;
      h.pipeline.ready.signalReady();
      return h;
    }

    // The web restart answers from the same [CommandReport] rendering as every
    // other command, so it carries `succeeded` and `runningCode` too: a client
    // written against the contract reads one shape everywhere.
    test(
      'a web restart answers with the verdict, like every other command',
      () async {
        final h = await webPipeline(_RecordingStrategy());

        final response = await h.restart().timeout(const Duration(seconds: 5));

        expect(response['succeeded'], isTrue);
        expect(
          response['runningCode'],
          'updated',
          reason: 'the browser took the new sources',
        );
        expect(response['message'], 'Restart successful');
        expect(response['elapsedMs'], isNotNull);
      },
    );

    test(
      'a web restart the browser refuses will not claim it kept its code',
      () async {
        final h = await webPipeline(
          _RecordingStrategy()
            ..next = const StrategyRejected(
              'the browser refused the new sources',
            ),
        );

        final response = await h.restart().timeout(const Duration(seconds: 5));

        expect(response['succeeded'], isFalse);
        // Not `unchanged`: a rejection is shared between a browser declining the
        // sources and a `catch` that can fire mid-delivery, so nothing here may
        // promise the old code survived.
        expect(response['runningCode'], 'unknown');
        expect(response['error'], contains('refused the new sources'));
      },
    );

    // A restart re-reads the whole bundle, so the rebuild's result reaches the
    // app — and the response has to name the assets it changed.
    test('a web restart reports the assets its rebuild changed', () async {
      final h = await webPipeline(_RecordingStrategy());
      h.pipeline
        ..assetTracker = await seedBundle(h.tmp, 'v1')
        ..rebuildAssets = () async {
          File(
            p.join(h.tmp.path, 'bundle', 'assets', 'message.txt'),
          ).writeAsStringSync(
            File(
              p.join(h.tmp.path, 'assets', 'message.txt'),
            ).readAsStringSync(),
          );
          return true;
        };

      File(
        p.join(h.tmp.path, 'assets', 'message.txt'),
      ).writeAsStringSync('version two');
      final response = await h.restart().timeout(const Duration(seconds: 5));

      expect(response['assetsChanged'], 1);
      expect(response['assetPaths'], ['assets/message.txt']);
    });
  });

  group('assets', () {
    // An asset-only edit has no Dart changes, so the orchestrator truthfully
    // says "no changes detected" — which the user who just repainted an icon
    // reads as "my edit did nothing".
    test(
      'an asset-only edit is reported as a reload, not as no changes',
      () async {
        final h = await _Harness.create();
        addTearDown(h.dispose);
        h.writeSource('main.dart', 'void main() {}');
        h.seedApplied();
        final tracker = await seedBundle(h.tmp, 'v1');
        final strategy = _RecordingStrategy();
        h.pipeline
          ..assetTracker = tracker
          ..strategy = strategy
          ..rebuildAssets = () async {
            // What `bazel build` would do: republish the source into the bundle.
            File(
              p.join(h.tmp.path, 'bundle', 'assets', 'message.txt'),
            ).writeAsStringSync(
              File(
                p.join(h.tmp.path, 'assets', 'message.txt'),
              ).readAsStringSync(),
            );
            return true;
          };
        h.pipeline.ready.signalReady();

        File(
          p.join(h.tmp.path, 'assets', 'message.txt'),
        ).writeAsStringSync('version two');
        final response = await h.hotReload();

        expect(
          response['message'],
          'Hot reload successful — 1 asset(s) reloaded',
        );
        expect(response['assetsChanged'], 1);
        expect(strategy.assetCalls, [
          {'assets/message.txt'},
        ]);
      },
    );

    // Two very different failures are easy to confuse: the tracker seeing no
    // source change, and a rebuild that ran and handed back the bundle it
    // already had. The second is what a poisoned Bazel action cache
    // looks like, and telling them apart from the outside is the difference
    // between suspecting the tracker and suspecting the build.
    test(
      'a rebuild that changes nothing says the build is what found nothing',
      () async {
        final h = await _Harness.create();
        addTearDown(h.dispose);
        h.writeSource('main.dart', 'void main() {}');
        h.seedApplied();
        h.pipeline
          ..assetTracker = await seedBundle(h.tmp, 'v1')
          ..strategy = _RecordingStrategy()
          // A build that "succeeds" without republishing anything — the source
          // moved, the bundle did not.
          ..rebuildAssets = () async => true;
        h.pipeline.ready.signalReady();

        File(
          p.join(h.tmp.path, 'assets', 'message.txt'),
        ).writeAsStringSync('version two');
        final response = await h.hotReload();

        expect(response['assetsChanged'], 0);
        expect(
          response['assetsRebuiltIdentical'],
          isTrue,
          reason:
              'the build ran and produced the bundle already delivered; a '
              'reader has to be able to tell that from the tracker never '
              'asking for a build at all',
        );
        expect(response['message'], contains('identical'));
      },
    );

    test(
      'an untouched asset tree reports nothing at all about assets',
      () async {
        // The other half of the same claim: no source moved, so no build ran and
        // there is nothing to say. A field set here would make the signature
        // above useless.
        final h = await _Harness.create();
        addTearDown(h.dispose);
        h.writeSource('main.dart', 'void main() {}');
        h.seedApplied();
        var built = false;
        h.pipeline
          ..assetTracker = await seedBundle(h.tmp, 'v1')
          ..strategy = _RecordingStrategy()
          ..rebuildAssets = () async {
            built = true;
            return true;
          };
        h.pipeline.ready.signalReady();

        final response = await h.hotReload();

        expect(built, isFalse);
        expect(response['assetsRebuiltIdentical'], isNull);
      },
    );

    // The window `builtBefore` closes at construction, reopened on every
    // re-commit: a save landing while bazel is running is not in the bundle
    // the build produced, so scanning it in as the state the app holds leaves
    // the next reload nothing to do and loses the edit for good.
    test(
      'an asset saved while the rebuild ran is still stale afterwards',
      () async {
        final h = await _Harness.create();
        addTearDown(h.dispose);
        h.writeSource('main.dart', 'void main() {}');
        h.seedApplied();
        final tracker = await seedBundle(h.tmp, 'v1');
        final source = File(p.join(h.tmp.path, 'assets', 'message.txt'));
        h.pipeline
          ..assetTracker = tracker
          ..strategy = _RecordingStrategy()
          ..rebuildAssets = () async {
            // The build publishes what it read…
            File(
              p.join(h.tmp.path, 'bundle', 'assets', 'message.txt'),
            ).writeAsStringSync('version two');
            // …and the user saves again before it returns.
            source.writeAsStringSync('version three');
            return true;
          };
        h.pipeline.ready.signalReady();

        source.writeAsStringSync('version two');
        await h.hotReload();

        expect(
          tracker.sourcesAreStale,
          isTrue,
          reason:
              'the bundle holds version two and the workspace holds '
              'version three; committing the latter as delivered loses the '
              'edit with no way to notice',
        );
      },
    );

    test(
      'a failed asset rebuild aborts rather than reloading half of it',
      () async {
        final h = await _Harness.create();
        addTearDown(h.dispose);
        h.writeSource('main.dart', 'void main() {}');
        h.seedApplied();
        h.pipeline
          ..assetTracker = await seedBundle(h.tmp, 'v1')
          ..strategy = _RecordingStrategy()
          ..rebuildAssets = () async => false;
        h.pipeline.ready.signalReady();

        File(
          p.join(h.tmp.path, 'assets', 'message.txt'),
        ).writeAsStringSync('version two');

        final response = await h.hotReload();
        expect(
          response['error'],
          'Asset rebuild (bazel) failed; see build output above.',
        );
        expect(
          response['message'],
          'Asset rebuild failed',
          reason: 'a failure says so in the line a human reads, too',
        );
      },
    );

    // A restart re-reads the whole bundle by construction, so delivering
    // individual assets first is work the next step throws away.
    test('a restart rebuilds the bundle but does not deliver assets', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      h.writeSource('main.dart', 'void main() {}');
      h.seedApplied();
      final strategy = _RecordingStrategy();
      h.pipeline
        ..assetTracker = await seedBundle(h.tmp, 'v1')
        ..strategy = strategy
        ..rebuildAssets = () async => true;
      h.pipeline.ready.signalReady();

      File(
        p.join(h.tmp.path, 'assets', 'message.txt'),
      ).writeAsStringSync('version two');
      await h.restart();

      expect(strategy.assetCalls, isEmpty);
    });

    test(
      'a native pipeline reports a reload path without a frontend server',
      () async {
        // What gates the interactive session, the file watcher and DevTools.
        // The native side has one compiler per app and so never sets
        // `frontendServer`; reading that field as "is reload wired" would
        // silently turn off the watcher and the keyboard for every native run.
        final h = await _Harness.create();
        addTearDown(h.dispose);
        expect(h.pipeline.frontendServer, isNull);
        expect(h.pipeline.orchestrator, isNotNull);
        expect(h.pipeline.hasReloadPath, isTrue);
      },
    );

    test(
      'a pipeline with neither compiler nor orchestrator has no reload path',
      () async {
        final h = await _Harness.create(withOrchestrator: false);
        addTearDown(h.dispose);
        expect(h.pipeline.hasReloadPath, isFalse);
      },
    );

    test('watchesAsset consults the tracker, and is false without one', () async {
      final h = await _Harness.create(withOrchestrator: false);
      addTearDown(h.dispose);
      final assetSource = p.join(h.tmp.path, 'assets', 'message.txt');
      // A directory that exists but feeds nothing in the bundle.
      final notAnAsset = p.join(h.tmp.path, 'lib', 'main.dart');

      // One pipeline object, answering differently once a tracker is attached:
      // that difference is what "consults" means.
      expect(h.pipeline.watchesAsset(assetSource), isFalse);

      h.pipeline.assetTracker = await seedBundle(h.tmp, 'v1');

      expect(h.pipeline.watchesAsset(assetSource), isTrue);
      // Without this one, a `watchesAsset` reporting nothing but "a tracker is
      // attached" would satisfy every other assertion here.
      expect(h.pipeline.watchesAsset(notAnAsset), isFalse);
    });
  });

  group('codegen', () {
    test('a failed generated-source rebuild aborts the reload', () async {
      final h = await _Harness.create(withOrchestrator: false);
      addTearDown(h.dispose);
      h.pipeline
        ..frontendServer = FrontendServer(
          dartaotruntimePath: '/nonexistent',
          frontendServerPath: '/nonexistent',
          config: _stubConfig,
          packageConfig: '/nonexistent',
        )
        ..strategy = _RecordingStrategy()
        ..refreshGenerated = () async => false;
      h.pipeline.ready.signalReady();

      // A failure, not a refusal: the bazel build was attempted and broke.
      // Both still say the app kept its old code, and both have earned it —
      // `refreshGenerated` runs before the asset refresh and before any
      // compile, so nothing had reached a device when this aborted.
      expect(await h.hotReload(), {
        'succeeded': false,
        'runningCode': 'unchanged',
        // Empty, not absent: this harness stands up no session, so the
        // command resolved its targets and there genuinely were none. A
        // refusal that never got as far as resolving omits the key instead.
        'appIds': <String>[],
        'error': 'Generated source rebuild (bazel) failed.',
        'message':
            'Hot reload failed: Generated source rebuild (bazel) failed.',
      });
      expect(await h.restart(), {
        'succeeded': false,
        'runningCode': 'unchanged',
        // Empty for the same reason as the hot reload above.
        'appIds': <String>[],
        'error': 'Generated source rebuild (bazel) failed.',
        'message': 'Restart failed: Generated source rebuild (bazel) failed.',
      });
    });
  });

  group('native libs', () {
    // A hot restart cannot replace a dlopened image, so the relauncher's answer
    // — when it gives one — IS the restart result and must short-circuit.
    test('a relaunch answers instead of the isolate restart', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      h.writeSource('main.dart', 'void main() {}');
      h.seedApplied();
      // A `Relaunched`, not a map a fake made up: the sealed type is what
      // keeps these assertions over a reply the real relauncher can produce.
      h.pipeline.relaunchIfNativeLibsChanged = () async => const Relaunched(
        changedLibs: ['libnative.dylib'],
        ready: true,
        launches: {'app-a': 2},
      );
      h.pipeline.ready.signalReady();

      final result = await h.restart();
      expect(result['relaunched'], isTrue);
      expect(result['succeeded'], isTrue);
      expect(result['runningCode'], 'updated');
      expect(result['ready'], isTrue);
      expect(result['launch'], {'app-a': 2});
      expect(result['message'], contains('libnative.dylib'));
      expect(
        h.compiler.fullCompileCalls,
        isEmpty,
        reason: 'the process was replaced; there is no isolate to restart',
      );
    });

    test('a failed relaunch rebuild reports a source rebuild failure', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      h.writeSource('main.dart', 'void main() {}');
      h.seedApplied();
      h.pipeline.relaunchIfNativeLibsChanged = () async =>
          const RelaunchBuildFailed('bazel build failed.');
      h.pipeline.ready.signalReady();

      final result = await h.restart();
      expect(result['succeeded'], isFalse);
      expect(result['error'], 'bazel build failed.');
      // `unchanged`, and provably: the rebuild runs before any process is
      // replaced and before any isolate is restarted, so nothing was delivered.
      expect(result['runningCode'], 'unchanged');
      // Not a refusal. `unavailable` would tell a driver this run cannot
      // reload at all and have it retire the session over a build error the
      // user can fix and retry — so the reply must still name the command.
      expect(result['message'], 'Restart failed: bazel build failed.');
      expect(h.compiler.fullCompileCalls, isEmpty);
    });

    test('no native-lib change falls through to the isolate restart', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      h.writeSource('main.dart', 'void main() {}');
      h.seedApplied();
      h.pipeline.relaunchIfNativeLibsChanged = () async =>
          const RelaunchNotNeeded();
      h.pipeline.ready.signalReady();

      final result = await h.restart();
      expect(result, containsPair('message', 'Restart successful'));
      expect(
        result.containsKey('relaunched'),
        isFalse,
        reason: 'nothing was relaunched, so nothing may say it was',
      );
      expect(
        h.compiler.fullCompileCalls.single.entrypoint,
        'package:app/main.dart',
      );
    });
  });
}
