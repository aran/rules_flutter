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

import 'package:flutter_bazel_dev_tool/command_runner.dart';
import 'package:flutter_bazel_dev_tool/device.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/applied_versions.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/package_uri_resolver.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/reload_orchestrator.dart';
import 'package:flutter_bazel_dev_tool/command_report.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/session_reloader.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/workspace.dart';
import 'package:flutter_bazel_dev_tool/logging.dart';
import 'package:flutter_bazel_dev_tool/machine_protocol.dart';
import 'package:flutter_bazel_dev_tool/native_libs_fingerprint.dart';
import 'package:flutter_bazel_dev_tool/native_libs_relauncher.dart';
import 'package:flutter_bazel_dev_tool/outcome_renderer.dart';
import 'package:flutter_bazel_dev_tool/session.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fakes.dart';

/// A device whose launches are counted and whose replacement instances carry no
/// VM service URI — so reconnection answers "not ready" at once instead of
/// spending five one-second retries against a socket nobody is listening on.
class _RelaunchDevice extends Device {
  int launches = 0;
  int stops = 0;

  @override
  String get name => 'fake';

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) async {
    launches++;
    return AppInstance(process: FakeProcess());
  }

  @override
  Future<void> stop(AppInstance instance) async {
    stops++;
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

    final resolver = PackageUriResolver(
      workspaceRoot: tmp.path,
      sourcePackages: const [(name: 'app', libRoot: '')],
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
  }) async {
    return Relauncher(
      appFile: appDir,
      rebuild: rebuild,
      sessions: [session],
      protocol: MachineProtocol(enabled: false, commandRunner: CommandRunner()),
      orchestrator: orchestrator,
      assetsDir: '',
      logger: Logger('test.relauncher'),
      liveFingerprint: await nativeLibsFingerprint(appDir),
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
}
