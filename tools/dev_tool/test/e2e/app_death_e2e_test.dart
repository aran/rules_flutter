@Tags(['e2e'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';

/// The apps under test.
const _iosExample = E2eApp('ios_example');
const _macosExample = E2eApp('macos_example');

/// An app that dies under a connected `run` ends the run, failed, with the
/// platform's account of why; one that is closed ends it cleanly.
///
/// Before this the run kept asking a VM service that was gone and printing
/// "still waiting" until it was killed. The app here is killed from outside,
/// after the tool reports it connected and drivable, so the death arrives as
/// the connection closing and the process going.
void main() {
  /// The run ended on its own, failed, and said the app died.
  Future<void> expectRunFailedWithAppDeath(
    DevToolProcess dt, {
    required String appId,
    required Pattern platformWords,
  }) async {
    final code = await dt.exitCodeWithin(
      const Duration(seconds: 90),
      stillRunning:
          'the app the run was connected to died, and the run did not end. '
          'Nothing on the connected path observed the app going away',
    );
    expect(code, isNot(0), reason: 'a dead app is a failed run');

    final stop = await dt.waitForEventWhere(
      'app.stop',
      test: (params) => params['appId'] == appId,
      what: 'an app.stop for the dead app',
      timeout: const Duration(seconds: 5),
    );
    final error = (stop['params'] as Map)['error'];
    expect(
      error,
      isA<String>().having((e) => e, 'error', contains(platformWords)),
      reason: 'app.stop must carry why the app stopped',
    );
  }

  group('macOS', () {
    test(
      'an app killed after the run connected ends the run, failed',
      () async {
        final dt = await startDevTool(
          workspace: _macosExample.moduleRoot,
          target: ':app',
          device: 'macos',
        );
        await dt.waitForEvent('app.started');
        await dt.waitForHttpControl();

        // The app is the tool's own child: the tool starts the executable
        // itself, so its process is the one the death is read from.
        final children = await Process.run('pgrep', [
          '-P',
          '${dt.process.pid}',
        ]);
        final pids = '${children.stdout}'
            .split('\n')
            .where((l) => l.trim().isNotEmpty)
            .map(int.parse)
            .toList();
        expect(pids, isNotEmpty, reason: 'the run has no child process');
        for (final pid in pids) {
          Process.killPid(pid, ProcessSignal.sigkill);
        }

        await expectRunFailedWithAppDeath(
          dt,
          appId: dt.appId!,
          platformWords: 'killed by signal 9',
        );
      },
      skip: !Platform.isMacOS ? 'macOS only' : null,
    );
  }, tags: 'macos');

  group('iOS Simulator', () {
    const bundleId = 'com.rulesflutter.ios.example';

    /// The booted simulators. Which one the run chose is the tool's business,
    /// and the app is on exactly one of them.
    Future<List<String>> bootedUdids() async {
      final listed = await Process.run('xcrun', [
        'simctl',
        'list',
        'devices',
        'booted',
        '-j',
      ]);
      return [
        for (final runtime
            in (jsonDecode('${listed.stdout}')['devices'] as Map).values)
          for (final d in runtime as List) (d as Map)['udid'] as String,
      ];
    }

    /// The app's pid, from the simulator's launchd, which started it.
    Future<int> appPid() async {
      final pids = <int>[];
      for (final udid in await bootedUdids()) {
        final listed = await Process.run('xcrun', [
          'simctl',
          'spawn',
          udid,
          'launchctl',
          'list',
        ]);
        for (final line in '${listed.stdout}'.split('\n')) {
          final fields = line.split('\t');
          if (fields.length == 3 &&
              fields[2].startsWith('UIKitApplication:$bundleId[')) {
            final pid = int.tryParse(fields[0]);
            if (pid != null) pids.add(pid);
          }
        }
      }
      expect(
        pids,
        hasLength(1),
        reason: 'the app runs on exactly one simulator',
      );
      return pids.single;
    }

    test(
      'an app that crashes after the run connected ends the run, failed',
      () async {
        final dt = await startDevTool(
          workspace: _iosExample.moduleRoot,
          target: ':app',
          device: 'ios-simulator',
        );
        await dt.waitForEvent('app.started');
        await dt.waitForHttpControl();

        // The simulator's processes are the host's: a segmentation fault
        // delivered to it is the same death a native crash is.
        Process.killPid(await appPid(), ProcessSignal.sigsegv);

        await expectRunFailedWithAppDeath(
          dt,
          appId: dt.appId!,
          platformWords: 'killed by signal 11 (SIGSEGV)',
        );
      },
      skip: !Platform.isMacOS ? 'macOS only (needs Xcode Simulator)' : null,
    );

    // Upstream's `flutter run` ends with status 0 when its app goes away; a
    // close is not a crash, so this run does too.
    test(
      'an app closed after the run connected ends the run, cleanly',
      () async {
        final dt = await startDevTool(
          workspace: _iosExample.moduleRoot,
          target: ':app',
          device: 'ios-simulator',
        );
        await dt.waitForEvent('app.started');
        await dt.waitForHttpControl();

        var terminated = 0;
        for (final udid in await bootedUdids()) {
          final result = await Process.run('xcrun', [
            'simctl',
            'terminate',
            udid,
            bundleId,
          ]);
          if (result.exitCode == 0) terminated++;
        }
        expect(terminated, 1, reason: 'the app runs on exactly one simulator');

        final code = await dt.exitCodeWithin(
          const Duration(seconds: 90),
          stillRunning:
              'the app the run was connected to was closed, and the run did '
              'not end',
        );
        expect(code, 0, reason: 'a closed app is not a failed run');
        final stop = await dt.waitForEventWhere(
          'app.stop',
          test: (params) => params['appId'] == dt.appId,
          what: 'an app.stop for the closed app',
          timeout: const Duration(seconds: 5),
        );
        expect((stop['params'] as Map).containsKey('error'), isFalse);
      },
      skip: !Platform.isMacOS ? 'macOS only (needs Xcode Simulator)' : null,
    );
  }, tags: 'ios_sim');
}
