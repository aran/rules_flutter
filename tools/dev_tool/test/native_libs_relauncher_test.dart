/// [Relauncher] with a real fingerprint over a real directory bundle, a fake
/// device, and an injected rebuild — so nothing here spawns bazel.
///
/// The aliasing this covers is what makes the relauncher hard: the
/// run's `sessions` list is swapped in place and the orchestrator's units are
/// pointed at the replacement processes. A copy anywhere in the chain leaves
/// the next reload aimed at a process that no longer exists — and rebuilding
/// the units instead of repointing them would throw away each app's compiler
/// and its record of what it is running.
import 'dart:async';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/command_failure.dart';
import 'package:flutter_bazel_dev_tool/command_runner.dart';
import 'package:flutter_bazel_dev_tool/device.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/applied_versions.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/source_uri_resolver.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/reload_orchestrator.dart';
import 'package:flutter_bazel_dev_tool/command_report.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/session_reloader.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/workspace.dart';
import 'package:flutter_bazel_dev_tool/logging.dart';
import 'package:flutter_bazel_dev_tool/machine_protocol.dart';
import 'package:flutter_bazel_dev_tool/native_libs_fingerprint.dart';
import 'package:flutter_bazel_dev_tool/native_libs_relauncher.dart';
import 'package:flutter_bazel_dev_tool/native_libs_watch.dart';
import 'package:flutter_bazel_dev_tool/outcome_renderer.dart';
import 'package:flutter_bazel_dev_tool/session.dart';
import 'package:flutter_bazel_dev_tool/vm_service_client.dart';
import 'package:vm_service/vm_service.dart' show IsolateRef;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fakes.dart';

/// A device whose launches are counted and whose replacement instances carry no
/// VM service URI — so reconnection answers "not ready" at once instead of
/// spending five one-second retries against a socket nobody is listening on.
class _RelaunchDevice extends Device {
  int launches = 0;
  int stops = 0;

  /// Thrown by [launch] when set: the replacement's install or launch failing
  /// after the old process has been stopped.
  Object? launchError;

  @override
  String get name => 'fake';

  @override
  bool sharesHostFilesystem = false;

  /// Run inside [stop], once the old process is being stopped.
  void Function()? onStop;

  /// When set, [launch] waits for it before returning its replacement: a
  /// launch still in flight.
  Future<void>? launchGate;

  /// Completed by [launch] once it has started.
  final launchStarted = Completer<void>();

  /// How many times the device was told to start nothing more.
  int abandons = 0;

  /// The instances [launch] returned, and those [stop] was given.
  final launched = <AppInstance>[];
  final stopped = <AppInstance>[];

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) async {
    launches++;
    if (!launchStarted.isCompleted) launchStarted.complete();
    if (launchGate case final gate?) await gate;
    if (launchError case final error?) throw error;
    final instance = AppInstance(process: FakeProcess());
    launched.add(instance);
    return instance;
  }

  @override
  Future<void> abandonLaunch() async => abandons++;

  @override
  Future<void> stop(AppInstance instance) async {
    stops++;
    stopped.add(instance);
    onStop?.call();
    await instance.logs.close();
  }
}

class _Harness {
  final Directory tmp;
  final String appDir;
  final _RelaunchDevice device;
  final DeviceSession session;
  final ReloadOrchestrator orchestrator;
  final AppliedVersions applied;
  final Workspace workspace;

  _Harness._(
    this.tmp,
    this.appDir,
    this.device,
    this.session,
    this.orchestrator,
    this.applied,
    this.workspace,
  );

  static Future<_Harness> create() async {
    final tmp = await Directory.systemTemp.createTemp('relauncher_');
    Directory(p.join(tmp.path, 'lib')).createSync();
    // An extracted-bundle artifact: a directory holding a loose `.dylib`, which
    // is what makes the fingerprint non-empty at all.
    final appDir = p.join(tmp.path, 'app.app');
    Directory(appDir).createSync();
    File(
      p.join(appDir, 'libnative.dylib'),
    ).writeAsStringSync('machine code v1');

    final device = _RelaunchDevice();
    final session = DeviceSession(
      device: device,
      // The initial instance HAS a VM service URI: the relaunch loop skips any
      // session without one, on the grounds that there is nothing to reconnect.
      appInstance: AppInstance(
        process: FakeProcess(),
        vmServiceUri: Uri.parse('http://127.0.0.1:1/'),
      ),
      vmClient: null,
      appId: 'app1',
    );

    final resolver = SourceUriResolver(
      workspaceRoot: tmp.path,
      sourcePackages: const [(name: 'app', packageRoot: '')],
    );
    final workspace = Workspace(resolver: resolver);
    final applied = AppliedVersions();
    final orchestrator = ReloadOrchestrator(
      workspace: workspace,
      units: [
        SessionReloader(
          id: 'app1',
          compiler: FakeCompiler(),
          applied: applied,
          app: FakeAppInstance(id: 'app1'),
        ),
      ],
      entrypoint: 'package:app/main.dart',
    );
    return _Harness._(
      tmp,
      appDir,
      device,
      session,
      orchestrator,
      applied,
      workspace,
    );
  }

  Future<void> dispose() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  }

  void changeNativeLib(String contents) =>
      File(p.join(appDir, 'libnative.dylib')).writeAsStringSync(contents);

  Future<Relauncher> relauncher({
    required Future<bool> Function() rebuild,
    List<String> Function()? patchedLibs,
    Future<void> Function({required bool newProcess})? catchUpPatcher,
    NativeLibsWatch? nativeLibs,
    Future<Map<String, String>?> Function()? probeLibs,
    bool Function()? runEnding,
  }) async {
    return Relauncher(
      appFile: appDir,
      runEnding: runEnding ?? () => false,
      rebuild: rebuild,
      probeLibs: probeLibs,
      sessions: [session],
      protocol: MachineProtocol(enabled: false, commandRunner: CommandRunner()),
      orchestrator: orchestrator,
      assetsDir: '',
      logger: Logger('test.relauncher'),
      liveFingerprint: await nativeLibsFingerprint(appDir),
      patchedLibs: patchedLibs,
      catchUpPatcher: catchUpPatcher,
      nativeLibs: nativeLibs,
    );
  }
}

void main() {
  test('an unchanged native library does not relaunch', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    var rebuilds = 0;
    final r = await h.relauncher(
      rebuild: () async {
        rebuilds++;
        return true;
      },
    );

    // "Nothing to do here" — the caller goes on to the ordinary isolate
    // restart, which is the fast path this check exists to protect.
    expect(await r.relaunchIfNeeded(), isA<RelaunchNotNeeded>());
    expect(rebuilds, 1);
    expect(h.device.launches, 0);
  });

  group('over a native hot patch', () {
    // A patched process runs code its bundle does not hold. A restart is the
    // reset, so it relaunches even when the rebuilt bundle is the launched one
    // — which is exactly an edit that was patched in and then undone.
    test('a live patch relaunches an unchanged bundle, naming the patched '
        'library', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final caughtUp = <bool>[];
      final r = await h.relauncher(
        rebuild: () async => true,
        patchedLibs: () => ['libnative.dylib'],
        catchUpPatcher: ({required newProcess}) async =>
            caughtUp.add(newProcess),
      );
      expect(
        await r.relaunchIfNeeded(),
        isA<Relaunched>().having((o) => o.changedLibs, 'changedLibs', [
          'libnative.dylib',
        ]),
      );
      expect(h.device.launches, 1);
      // The hot patcher re-snapshots the image the new process loaded.
      expect(caughtUp, [true]);
    });

    test(
      'no live patch and an unchanged bundle is still the fast path',
      () async {
        final h = await _Harness.create();
        addTearDown(h.dispose);
        final caughtUp = <bool>[];
        final r = await h.relauncher(
          rebuild: () async => true,
          patchedLibs: () => const [],
          catchUpPatcher: ({required newProcess}) async =>
              caughtUp.add(newProcess),
        );
        expect(await r.relaunchIfNeeded(), isA<RelaunchNotNeeded>());
        // Asked, as the process that stayed: the patcher decides from its
        // own sources whether its snapshot still describes it.
        expect(caughtUp, [false]);
      },
    );
  });

  test('a restart that keeps the process brings the watch up to it', () async {
    // A source moved and no bundled byte did — a declaration added to a header
    // nothing defines yet. The process already runs what the tree builds, so
    // the watch must stop calling the edit undelivered, or every reload after
    // this restart is withheld with advice to restart.
    final h = await _Harness.create();
    addTearDown(h.dispose);
    final header = File(p.join(h.tmp.path, 'native.h'))
      ..writeAsStringSync('int f(void);');
    final contract = File(p.join(h.tmp.path, 'native.api'))
      ..writeAsStringSync('f');
    final lib = p.join(h.appDir, 'libnative.dylib');
    final watch = await NativeLibsWatch.of(
      {
        lib: [contract.path],
      },
      sources: {
        lib: [header.path],
      },
    );
    header.writeAsStringSync('int f(void);\nint g(void);');
    contract.writeAsStringSync('f\ng');
    expect(await watch.verdict(), isA<NativeBindingsMoved>());

    final r = await h.relauncher(
      rebuild: () async => true,
      nativeLibs: watch,
    );
    expect(await r.relaunchIfNeeded(), isA<RelaunchNotNeeded>());
    expect(h.device.launches, 0);
    expect(await watch.verdict(), isA<NativeLibsCurrent>());
  });

  test('a failed rebuild reports it and relaunches nothing', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    final r = await h.relauncher(rebuild: () async => false);

    final outcome = await r.relaunchIfNeeded();
    expect(
      outcome,
      isA<RelaunchBuildFailed>().having(
        (o) => o.reason,
        'reason',
        'bazel build failed during restart; see build output.',
      ),
    );
    expect(h.device.launches, 0);
  });

  test('a changed native library replaces the process', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    final r = await h.relauncher(
      rebuild: () async {
        // What the rebuild would have produced.
        h.changeNativeLib('machine code v2 — longer');
        return true;
      },
    );

    final outcome = await r.relaunchIfNeeded();

    expect(outcome, isA<Relaunched>());
    final relaunched = outcome as Relaunched;
    expect(relaunched.changedLibs, ['libnative.dylib']);
    // The replacement carries no VM service URI here, so the app cannot yet
    // take an `app.*` command and the outcome says so rather than implying it.
    expect(relaunched.ready, isFalse);
    expect(h.device.stops, 1);
    expect(h.device.launches, 1);

    // Facts, not a reply: the wording is the renderer's. This arm owes the wire
    // a `succeeded` and a `runningCode` like every other restart reply.
    final wire = toWire(CommandReport(verb: 'Restart', relaunch: relaunched));
    expect(wire['succeeded'], isTrue);
    expect(wire['runningCode'], 'updated');
    expect(wire['message'], contains('libnative.dylib'));
  });

  // Measured on a Windows VM: the engine holds files of the devFS open while
  // the app runs, so asking the running app to delete it fails with `Access is
  // denied` and leaves the directory behind for good.
  test(
    'the devFS of a replaced process is deleted after it exits, not by it',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final outer = Directory(p.join(h.tmp.path, 'flutter_bazelAb12Cd'))
        ..createSync();
      final devFS = await FakeDevFS.start(
        Directory(p.join(outer.path, 'flutter_bazel'))..createSync(),
      );
      addTearDown(devFS.close);
      final vm = FakeVmService(
        isolates: [IsolateRef(id: 'iso-main', name: 'main', number: '1')],
      )..devFSUri = devFS.uri;
      final client = VmServiceClient(connector: (_) async => vm);
      await client.connect(devFS.serviceUri);
      h.session.vmClient = client;
      h.device.sharesHostFilesystem = true;
      bool? presentWhileStopping;
      h.device.onStop = () => presentWhileStopping = outer.existsSync();
      final r = await h.relauncher(
        rebuild: () async {
          h.changeNativeLib('machine code v2 — longer');
          return true;
        },
      );

      await r.relaunchIfNeeded();

      expect(
        vm.extensionCalls.map((c) => c.method),
        isNot(contains('_deleteDevFS')),
        reason: 'the old process is not asked: it may hold the files open',
      );
      expect(
        presentWhileStopping,
        isTrue,
        reason: 'nothing is deleted before the process is stopped',
      );
      expect(outer.existsSync(), isFalse);
    },
  );

  test(
    'a device on another filesystem is still asked to delete its devFS',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final vm = FakeVmService(
        isolates: [IsolateRef(id: 'iso-main', name: 'main', number: '1')],
      );
      final devFS = await FakeDevFS.start(
        Directory(p.join(h.tmp.path, 'devfs'))..createSync(),
      );
      addTearDown(devFS.close);
      vm.devFSUri = devFS.uri;
      final client = VmServiceClient(connector: (_) async => vm);
      await client.connect(devFS.serviceUri);
      h.session.vmClient = client;
      final r = await h.relauncher(
        rebuild: () async {
          h.changeNativeLib('machine code v2 — longer');
          return true;
        },
      );

      await r.relaunchIfNeeded();

      expect(vm.extensionCalls.map((c) => c.method), contains('_deleteDevFS'));
    },
  );

  // Measured on an Android emulator short of storage: `adb install -r` refused
  // the rebuilt APK after the old app had been stopped. The run then ended
  // with no reply and no log line saying why.
  test('a relaunch that cannot launch says why and ends the session', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    h.device.launchError = StateError(
      'adb install failed: the device is out of room for this APK.',
    );
    final r = await h.relauncher(
      rebuild: () async {
        h.changeNativeLib('machine code v2 — longer');
        return true;
      },
    );

    final outcome = await r.relaunchIfNeeded();

    expect(outcome, isA<RelaunchFailed>());
    final failed = outcome as RelaunchFailed;
    expect(failed.changedLibs, ['libnative.dylib']);
    expect(failed.failures.values.single, contains('out of room'));
    expect(failed.failures.values.single, isNot(startsWith('Bad state')));
    // The old process is gone and nothing replaced it.
    expect(h.device.stops, 1);
    await h.session.terminated.timeout(const Duration(seconds: 5));

    final wire = toWire(
      CommandReport(verb: 'Restart', relaunchFailed: failed),
    );
    expect(wire['succeeded'], isFalse);
    expect(wire['runningCode'], 'unknown');
    expect(wire['relaunched'], isFalse);
    expect(wire['error'], contains('out of room'));
    expect(wire['message'], contains('not running'));
  });

  // `app.stop`, `daemon.shutdown` and `q` run beside a restart, so the session
  // a restart is relaunching can be shut down at any point of it. A
  // replacement launched or kept after that is an app left on the device when
  // the run has ended.
  group('a relaunch whose app is stopped while it runs', () {
    final protocol = MachineProtocol(enabled: false);

    // With the run ending, answered as any command the run's end overtakes
    // is, and not as a failed relaunch: the terminal reports that below
    // severe, as the `q` working.
    final shutsDown = throwsA(
      isA<CommandFailure>().having(
        (e) => e.kind,
        'kind',
        CommandFailureKind.shuttingDown,
      ),
    );

    // With only the app ended (an `app.stop`), the run goes on, and saying it
    // is shutting down would be false: the restart failed, and says why.
    final stoppedDuringRestart = completion(
      isA<RelaunchFailed>().having(
        (f) => f.failures.values.single,
        'failure',
        'the app was stopped during the restart',
      ),
    );

    test('launches nothing when the stop lands with the old process', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      Future<void>? shutdown;
      h.device.onStop = () => shutdown ??= h.session.shutdown(protocol);
      final r = await h.relauncher(
        rebuild: () async {
          h.changeNativeLib('machine code v2 — longer');
          return true;
        },
      );

      await expectLater(r.relaunchIfNeeded(), stoppedDuringRestart);
      await shutdown;

      expect(h.device.launches, 0);
      await h.session.terminated.timeout(const Duration(seconds: 5));
    });

    test(
      'is answered as shutting down when the run ends with the app',
      () async {
        final h = await _Harness.create();
        addTearDown(h.dispose);
        var ending = false;
        Future<void>? shutdown;
        h.device.onStop = () {
          ending = true;
          shutdown ??= h.session.shutdown(protocol);
        };
        final r = await h.relauncher(
          rebuild: () async {
            h.changeNativeLib('machine code v2 — longer');
            return true;
          },
          runEnding: () => ending,
        );

        await expectLater(r.relaunchIfNeeded(), shutsDown);
        await shutdown;
        expect(h.device.launches, 0);
      },
    );

    test('launches nothing once the run has started to end', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final r = await h.relauncher(
        rebuild: () async {
          h.changeNativeLib('machine code v2 — longer');
          return true;
        },
        runEnding: () => true,
      );

      await expectLater(r.relaunchIfNeeded(), shutsDown);
      expect(h.device.launches, 0);
    });

    test('abandons a launch in flight and stops the replacement it '
        'returns', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final gate = Completer<void>();
      h.device
        ..launchGate = gate.future
        // Longer than the gate is held below, so the shutdown is still
        // waiting for the relaunch when the replacement arrives.
        ..teardownBound = const Duration(seconds: 5);
      final r = await h.relauncher(
        rebuild: () async {
          h.changeNativeLib('machine code v2 — longer');
          return true;
        },
      );

      final restart = r.relaunchIfNeeded();
      await h.device.launchStarted.future;
      var shutDown = false;
      final shutdown = h.session.shutdown(protocol)
        ..then((_) => shutDown = true);
      await pumpEventQueue();
      expect(h.device.abandons, 1);
      expect(
        shutDown,
        isFalse,
        reason: 'the shutdown waits for the launch it abandoned',
      );

      final answered = expectLater(restart, stoppedDuringRestart);
      gate.complete();
      await shutdown;
      await answered;

      final replacement = h.device.launched.single;
      expect(h.device.stopped, contains(same(replacement)));
      expect(identical(h.session.appInstance, replacement), isFalse);
      expect(h.session.vmClient, isNull);
      await h.session.terminated.timeout(const Duration(seconds: 5));
    });

    test('stops a replacement that arrives after the shutdown gave up '
        'waiting for it', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final gate = Completer<void>();
      h.device
        ..launchGate = gate.future
        // No wait at all: the shutdown finishes before the launch returns.
        ..teardownBound = Duration.zero;
      final r = await h.relauncher(
        rebuild: () async {
          h.changeNativeLib('machine code v2 — longer');
          return true;
        },
      );

      final restart = r.relaunchIfNeeded();
      await h.device.launchStarted.future;
      await h.session.shutdown(protocol);
      expect(h.device.launched, isEmpty);

      gate.complete();
      await expectLater(restart, stoppedDuringRestart);

      final replacement = h.device.launched.single;
      expect(h.device.stopped, contains(same(replacement)));
      expect(identical(h.session.appInstance, replacement), isFalse);
    });
  });

  // A relaunch repoints the units; it does not rebuild them. Each unit owns
  // this app's compiler and its record of what the app is running, and a fresh
  // unit would mean a fresh compiler — throwing away the incremental state and,
  // worse, a record that then has to be invented from somewhere.
  test('the orchestrator keeps its units across a relaunch', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    final unitsBefore = [...h.orchestrator.units];
    final compilerBefore = h.orchestrator.units.single.compiler;
    final appliedBefore = h.orchestrator.units.single.applied;
    final r = await h.relauncher(
      rebuild: () async {
        h.changeNativeLib('machine code v2 — longer');
        return true;
      },
    );

    await r.relaunchIfNeeded();

    expect(h.orchestrator.units.single, same(unitsBefore.single));
    expect(h.orchestrator.units.single.compiler, same(compilerBefore));
    expect(
      h.orchestrator.units.single.applied,
      same(appliedBefore),
      reason:
          'the record must survive: the replacement runs current disk, '
          'so a record left alone can only under-claim, never over-claim',
    );
  });

  test('the session is swapped, not ended', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    final before = h.session.appInstance;
    final r = await h.relauncher(
      rebuild: () async {
        h.changeNativeLib('machine code v2 — longer');
        return true;
      },
    );

    await r.relaunchIfNeeded();

    expect(identical(h.session.appInstance, before), isFalse);
    // A relaunch is not the app exiting: `terminated` completing here would
    // tear down the run's transports under a driver that is mid-restart.
    expect(
      h.session.terminated.timeout(
        const Duration(milliseconds: 100),
        onTimeout: () => 'still running',
      ),
      completion('still running'),
    );
  });

  test('a second relaunch compares against what is now running', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    final r = await h.relauncher(
      rebuild: () async {
        h.changeNativeLib('machine code v2 — longer');
        return true;
      },
    );

    // Named variants, not `isNotNull`/`isNull`. Every outcome is non-null, so
    // `isNotNull` would hold for the build-failure arm too — and this test is
    // about telling the arms apart.
    expect(await r.relaunchIfNeeded(), isA<Relaunched>());
    // Nothing changed since, so the live fingerprint must have advanced —
    // otherwise every subsequent restart would relaunch the process again.
    expect(await r.relaunchIfNeeded(), isA<RelaunchNotNeeded>());
    expect(h.device.launches, 1);
  });

  // Packaging the launch artifact is most of what an Android restart costs (an
  // APK is dexed, linked, zipped and signed), and the only thing a restart
  // needs of it is its native libraries. A platform that can read those without
  // the artifact says how, and a restart that finds them unchanged builds
  // nothing of it.
  group('with a probe of the libraries that does not package the artifact', () {
    /// The fingerprint the probe reads off the libraries, as the bundle's own
    /// is keyed: the same file name and a token for its content.
    Future<Map<String, String>?> Function() probing(
      _Harness h,
      List<String> asked,
    ) => () async {
      asked.add('probe');
      return nativeLibsFingerprint(h.appDir);
    };

    test('unchanged libraries build and relaunch nothing', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final asked = <String>[];
      final r = await h.relauncher(
        rebuild: () async {
          asked.add('rebuild');
          return true;
        },
        probeLibs: probing(h, asked),
      );

      expect(await r.relaunchIfNeeded(), isA<RelaunchNotNeeded>());
      expect(asked, ['probe']);
      expect(h.device.launches, 0);
    });

    test('changed libraries build the artifact once, then relaunch from it, '
        'and the next restart compares against what now runs', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final asked = <String>[];
      final r = await h.relauncher(
        rebuild: () async {
          asked.add('rebuild');
          return true;
        },
        probeLibs: () async {
          asked.add('probe');
          h.changeNativeLib('machine code v2 — longer');
          return nativeLibsFingerprint(h.appDir);
        },
      );

      final outcome = await r.relaunchIfNeeded();
      expect(
        outcome,
        isA<Relaunched>().having((o) => o.changedLibs, 'changedLibs', [
          'libnative.dylib',
        ]),
      );
      // The relaunch installs the artifact, so it is built before it, and only
      // once the libraries are known to have moved.
      expect(asked, ['probe', 'rebuild']);
      expect(h.device.launches, 1);

      expect(await r.relaunchIfNeeded(), isA<RelaunchNotNeeded>());
      expect(h.device.launches, 1);
    });

    test('a probe that cannot read the libraries reports the build and '
        'relaunches nothing', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      var rebuilt = false;
      final r = await h.relauncher(
        rebuild: () async => rebuilt = true,
        probeLibs: () async => null,
      );

      expect(await r.relaunchIfNeeded(), isA<RelaunchBuildFailed>());
      expect(rebuilt, isFalse);
      expect(h.device.launches, 0);
    });

    test('a failed build of the artifact after a changed library relaunches '
        'nothing', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final r = await h.relauncher(
        rebuild: () async => false,
        probeLibs: () async {
          h.changeNativeLib('machine code v2 — longer');
          return nativeLibsFingerprint(h.appDir);
        },
      );

      expect(await r.relaunchIfNeeded(), isA<RelaunchBuildFailed>());
      expect(h.device.stops, 0);
      expect(h.device.launches, 0);
    });

    test('a live patch still relaunches an unchanged bundle, from a rebuilt '
        'artifact', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final asked = <String>[];
      final r = await h.relauncher(
        rebuild: () async {
          asked.add('rebuild');
          return true;
        },
        probeLibs: probing(h, asked),
        patchedLibs: () => ['libnative.dylib'],
      );

      expect(await r.relaunchIfNeeded(), isA<Relaunched>());
      expect(asked, ['probe', 'rebuild']);
    });
  });
}
