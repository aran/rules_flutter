@Tags(['e2e', 'android'])
/// What a hot restart of an Android app builds, and when it replaces the process.
///
/// Packaging an APK (dex, resources, zip, sign) was most of a restart's cost:
/// the restart rebuilt its whole launch target to find out whether a native
/// library or an asset had moved, and neither had. A restart whose edit is
/// Dart alone has to build nothing of the APK, and one whose edit is a native
/// library has to, because a relaunch installs it.
///
/// `android_example` is the workspace for it: an Android app that bundles a
/// loose native library (`native/add.c`, through `native_deps`) and prints a
/// line from `main()`, which a restart runs again.
///
/// Run on an attached phone or emulator (`$ANDROID_SERIAL` picks one).
library;

import 'dart:convert';

import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import 'dev_tool_e2e_harness.dart';
import 'editable_workspace.dart';

/// The app under test.
const _app = E2eApp('android_example');

/// The line `main()` prints, whose suffix the Dart edit changes.
const _marker = "debugPrint('android_example shared=\$shared');";

void main() {
  final android = AndroidDeviceProbe.detect();

  group('Android hot restart', () {
    Future<DevToolProcess> launch(
      EditableWorkspace ws, {
      String target = ':app',
    }) async {
      final probe = android.require();
      print('e2e: Android device ${probe.serial} (via ${probe.adb})');
      final dt = await startDevTool(
        workspace: ws.root,
        target: target,
        device: 'android:${probe.serial}',
      );
      await dt.waitForEvent(
        'app.started',
        timeout: const Duration(minutes: 8),
      );
      await dt.waitForHttpControl();
      await dt.waitForAppLog('android_example shared=');
      // An edit inside the assembler's own build window is compiled into its
      // baseline, so nothing is edited before the pipeline is up.
      await dt.waitForStderr('frontend_server_ready');
      return dt;
    }

    /// The bazel `build` commands the tool ran after the [after]th line of its
    /// stderr, as it logged them.
    List<String> buildsSince(DevToolProcess dt, int after) => [
      for (final line in dt.stderrLines.skip(after))
        if (line.contains('"message":"bazel_command"') &&
            line.contains('"args":["build"'))
          line,
    ];

    test(
      'a Dart-only edit builds nothing of the APK and keeps the process',
      () async {
        final ws = await editableWorkspace(_app);
        final main = ws.file('lib/main.dart');
        final original = main.readAsStringSync();
        expect(original, contains(_marker), reason: 'fixture marker');

        final dt = await launch(ws);
        final appId = dt.appId!;
        final before = await dt.httpLogs(appId);
        expect(before['launch'], 1);

        main.writeAsStringSync(
          original.replaceFirst(
            _marker,
            "debugPrint('android_example shared=\$shared v2');",
          ),
        );
        final seen = dt.stderrLines.length;
        final restart = await dt.httpCommand('app.restart', {
          'appId': appId,
          'fullRestart': true,
        });
        final result = restart['result'] as Map<String, dynamic>?;
        expect(result, isNotNull, reason: 'app.restart: ${restart['error']}');
        expect(
          result!['relaunched'],
          isNot(isTrue),
          reason: 'no native library moved, so the process must stay: $result',
        );

        // The restart ran the edited `main()`.
        await dt.waitForAppLog(RegExp(r'shared=\d+ v2'));

        // The rebuild it did was of the bundle's parts alone. A build of the
        // launch target itself packages the APK, which is what this is about.
        final builds = buildsSince(dt, seen);
        expect(
          builds,
          isNotEmpty,
          reason:
              'the restart reads the native libraries, which is a build; if '
              'it logged none, this test is not looking at the right records',
        );
        for (final build in builds) {
          expect(
            build,
            contains('flutter_android_bundle_parts'),
            reason: 'a restart built more than the bundle parts: $build',
          );
        }
        await dt.sendCommand(1, 'daemon.shutdown');
      },
      timeout: const Timeout(Duration(minutes: 12)),
    );

    test('a native library edit builds the APK once and replaces the process', () async {
      final ws = await editableWorkspace(_app);
      final add = ws.file('native/add.c');
      final original = add.readAsStringSync();
      expect(original, contains('return a + b;'), reason: 'fixture marker');

      final dt = await launch(ws);
      final appId = dt.appId!;
      expect((await dt.httpLogs(appId))['launch'], 1);

      add.writeAsStringSync(
        original.replaceFirst('return a + b;', 'return a + b + 1;'),
      );
      final seen = dt.stderrLines.length;
      final restart = await dt.httpCommand('app.restart', {
        'appId': appId,
        'fullRestart': true,
      });
      final result = restart['result'] as Map<String, dynamic>?;
      expect(result, isNotNull, reason: 'app.restart: ${restart['error']}');
      expect(
        result!['relaunched'],
        isTrue,
        reason: 'a changed library must relaunch, not hot restart: $result',
      );
      expect((result['launch'] as Map)[appId], 2);

      // The APK was built for the relaunch to install, and only once: the
      // restart's own build of the parts does not stand in for it.
      final launchBuilds = [
        for (final build in buildsSince(dt, seen))
          if (!build.contains('flutter_android_bundle_parts')) build,
      ];
      expect(
        launchBuilds,
        hasLength(1),
        reason:
            'the launch target is built once: ${launchBuilds.map(json.encode)}',
      );

      // And the relaunched app is running, so its next restart finds nothing
      // changed and builds no APK.
      await dt.waitForAppLog('android_example shared=');
      final afterRelaunch = dt.stderrLines.length;
      final again = await dt.httpCommand('app.restart', {
        'appId': appId,
        'fullRestart': true,
      });
      expect(
        (again['result'] as Map<String, dynamic>?)?['relaunched'],
        isNot(isTrue),
        reason: '${again['error'] ?? again['result']}',
      );
      for (final build in buildsSince(dt, afterRelaunch)) {
        expect(build, contains('flutter_android_bundle_parts'));
      }
      await dt.sendCommand(1, 'daemon.shutdown');
    }, timeout: const Timeout(Duration(minutes: 15)));

    // The APK packages more than the application's own `native_deps`: a
    // `cc_library` listed on the `android_binary` is linked into a library of
    // the binary's own, and an AAR brings its `jni/` libraries. A restart that
    // watched only the application's libraries would run on stale machine code
    // after an edit to one of these, and say nothing.
    test(
      'an edit to a cc_library listed on the android_binary relaunches',
      () async {
        final ws = await editableWorkspace(_app);
        final extra = ws.file('native/extra.c');
        final original = extra.readAsStringSync();
        expect(original, contains('return 1;'), reason: 'fixture marker');

        final dt = await launch(ws, target: ':native_dep_app');
        final appId = dt.appId!;
        expect((await dt.httpLogs(appId))['launch'], 1);

        extra.writeAsStringSync(
          original.replaceFirst('return 1;', 'return 2;'),
        );
        final restart = await dt.httpCommand('app.restart', {
          'appId': appId,
          'fullRestart': true,
        });
        final result = restart['result'] as Map<String, dynamic>?;
        expect(result, isNotNull, reason: 'app.restart: ${restart['error']}');
        expect(
          result!['relaunched'],
          isTrue,
          reason:
              'a changed library on the android_binary must relaunch, not hot '
              'restart: $result',
        );
        expect((result['launch'] as Map)[appId], 2);
        await dt.sendCommand(1, 'daemon.shutdown');
      },
      timeout: const Timeout(Duration(minutes: 15)),
    );

    // The same for the library an AAR carries: the APK packages it under
    // `lib/<abi>/` without ever linking it, and a restart that read only the
    // libraries the build links would not see it move.
    test('an edit to a library an AAR carries relaunches', () async {
      final ws = await editableWorkspace(_app);
      final aar = ws.file('native/aar_native.c');
      final original = aar.readAsStringSync();
      expect(original, contains('return 1;'), reason: 'fixture marker');

      final dt = await launch(ws, target: ':native_dep_app');
      final appId = dt.appId!;
      expect((await dt.httpLogs(appId))['launch'], 1);

      aar.writeAsStringSync(original.replaceFirst('return 1;', 'return 2;'));
      final restart = await dt.httpCommand('app.restart', {
        'appId': appId,
        'fullRestart': true,
      });
      final result = restart['result'] as Map<String, dynamic>?;
      expect(result, isNotNull, reason: 'app.restart: ${restart['error']}');
      expect(
        result!['relaunched'],
        isTrue,
        reason:
            'a changed library inside an AAR must relaunch, not hot restart: '
            '$result',
      );
      expect((result['launch'] as Map)[appId], 2);
      await dt.sendCommand(1, 'daemon.shutdown');
    }, timeout: const Timeout(Duration(minutes: 15)));

    // A prebuilt library checked into the workspace and imported with
    // `cc_import` is a source file, not a build output. The APK packages it all
    // the same, so a restart has to notice it changed.
    test('an edit to a checked-in prebuilt library relaunches', () async {
      final ws = await editableWorkspace(_app);
      final prebuilt = ws.file('native/prebuilt/libprebuilt.so');
      final original = prebuilt.readAsBytesSync();

      final dt = await launch(ws, target: ':native_dep_app');
      final appId = dt.appId!;
      expect((await dt.httpLogs(appId))['launch'], 1);

      // Bytes after the end of an ELF file are never read, so the library
      // still loads and only its content differs.
      prebuilt.writeAsBytesSync([...original, 0]);
      final restart = await dt.httpCommand('app.restart', {
        'appId': appId,
        'fullRestart': true,
      });
      final result = restart['result'] as Map<String, dynamic>?;
      expect(result, isNotNull, reason: 'app.restart: ${restart['error']}');
      expect(
        result!['relaunched'],
        isTrue,
        reason:
            'a changed prebuilt library must relaunch, not hot restart: '
            '$result',
      );
      expect((result['launch'] as Map)[appId], 2);
      await dt.sendCommand(1, 'daemon.shutdown');
    }, timeout: const Timeout(Duration(minutes: 15)));

    // The same for a prebuilt static archive: the APK links it into the
    // binary's own library, so it is a source file that changes what the APK
    // carries without any file of the build changing but the link.
    test('an edit to a checked-in prebuilt archive relaunches', () async {
      final ws = await editableWorkspace(_app);
      final archive = ws.file('native/prebuilt/libprebuilt_static.a');
      // The same member built with another value, as a checked-in archive
      // that no target uses.
      final next = ws.file('native/prebuilt/libprebuilt_static_next.a');

      final dt = await launch(ws, target: ':native_dep_app');
      final appId = dt.appId!;
      expect((await dt.httpLogs(appId))['launch'], 1);

      archive.writeAsBytesSync(next.readAsBytesSync());
      final restart = await dt.httpCommand('app.restart', {
        'appId': appId,
        'fullRestart': true,
      });
      final result = restart['result'] as Map<String, dynamic>?;
      expect(result, isNotNull, reason: 'app.restart: ${restart['error']}');
      expect(
        result!['relaunched'],
        isTrue,
        reason:
            'a changed prebuilt archive must relaunch, not hot restart: '
            '$result',
      );
      expect((result['launch'] as Map)[appId], 2);
      await dt.sendCommand(1, 'daemon.shutdown');
    }, timeout: const Timeout(Duration(minutes: 15)));

    // `am start -W` returns once the first frame is drawn, and an app started
    // paused never draws one. The launch must not wait on it: the VM service is
    // announced, and held at PauseStart, until a debugger resumes it.
    test('an app started paused is found and held, not waited on', () async {
      final probe = android.require();
      final ws = await editableWorkspace(_app);
      final dt = await startDevTool(
        workspace: ws.root,
        target: ':app',
        device: 'android:${probe.serial}',
        extraArgs: ['--start-paused'],
      );
      final debugPort = await dt.waitForEvent(
        'app.debugPort',
        timeout: const Duration(minutes: 8),
      );
      final service = await vmServiceConnectUri(
        debugPort['params']?['wsUri'] as String,
      );
      addTearDown(service.dispose);
      final vm = await service.getVM();
      final main = vm.isolates!.firstWhere((i) => i.name == 'main');
      final isolate = await service.getIsolate(main.id!);
      expect(isolate.pauseEvent?.kind, EventKind.kPauseStart);

      await service.resume(main.id!);
      await dt.waitForAppLog('android_example shared=');
      await dt.sendCommand(1, 'daemon.shutdown');
    }, timeout: const Timeout(Duration(minutes: 15)));
  });
}
