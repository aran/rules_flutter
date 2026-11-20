import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_bazel_dev_tool/device.dart';
import 'package:flutter_bazel_dev_tool/web_bundle_facts.dart';
import 'package:flutter_bazel_dev_tool/key_press.dart';
import 'package:flutter_bazel_dev_tool/toolchain_info.dart';
import 'package:flutter_bazel_dev_tool/web_module_server.dart';
import 'package:flutter_bazel_dev_tool/web_options.dart';
import 'package:flutter_bazel_dev_tool/mdns_vm_service_discovery.dart';
import 'package:flutter_bazel_dev_tool/runfiles_helper.dart';
import 'package:flutter_bazel_dev_tool/screen.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fakes.dart';

/// The announcement every desktop launch waits for.
const _vmServiceLine =
    'The Dart VM service is listening on http://127.0.0.1:12345/test=/';

/// What `devicectl list devices` reports for one paired device.
String devicesJson(String transportType) => json.encode({
  'result': {
    'devices': [
      {
        'identifier': 'TEST-COREDEVICE-ID',
        'hardwareProperties': {'udid': 'TEST-UDID'},
        'deviceProperties': {'name': 'Test iPhone'},
        'connectionProperties': {
          'transportType': transportType,
          'pairingState': 'paired',
          'localHostnames': ['Test-iPhone.coredevice.local'],
        },
      },
    ],
  },
});

/// A display as `devicectl device info displays --json-output` describes it.
Map<String, Object?> display(
  String name, {
  String? uniqueId,
  int displayId = 1,
  bool? active,
  String type = 'integrated',
  bool primary = false,
}) => {
  'name': name,
  'displayId': displayId,
  'uniqueId': ?uniqueId,
  'active': ?active,
  'primary': primary,
  'nativeSize': [100, 200],
  'backlightState': 'unknown',
  'type': {type: <String, Object?>{}},
};

/// What a fake `devicectl` answers to `device info displays`: it writes the
/// JSON to the `--json-output` path, as the real one does.
ProcessResult displaysAnswer(
  List<String> args,
  List<Map<String, Object?>> displays,
) {
  File(args[args.indexOf('--json-output') + 1]).writeAsStringSync(
    json.encode({
      'info': {'outcome': 'success', 'jsonVersion': 5},
      'result': {'displays': displays},
    }),
  );
  return ProcessResult(0, 0, '', '');
}

/// A fake `devicectl` that reports [displays] and records every command line
/// it is given.
({ProcessRunSync run, List<List<String>> calls}) fakeDevicectl(
  List<Map<String, Object?>> Function() displays,
) {
  final calls = <List<String>>[];
  return (
    calls: calls,
    run: (exe, args) async {
      calls.add([exe, ...args]);
      if (args.contains('displays')) return displaysAnswer(args, displays());
      return ProcessResult(0, 0, '', '');
    },
  );
}

/// What a fake `simctl` answers: success, and for `simctl launch` the line
/// naming the pid it started, which a launch needs to find its own app's VM
/// service.
ProcessResult simctlOk(List<String> args, {int pid = 1234}) =>
    args.length > 3 && args[0] == 'simctl' && args[1] == 'launch'
    ? ProcessResult(0, 0, '${args[3]}: $pid\n', '')
    : ProcessResult(0, 0, '', '');

/// What a fake `adb` answers: success, and for `pidof` the pid that the
/// fixtures' logcat announcements carry, so a launch takes them as its app's.
ProcessResult adbOk(List<String> args) => args.contains('pidof')
    ? ProcessResult(0, 0, '1234\n', '')
    : ProcessResult(0, 0, '', '');

void main() {
  group('vmServiceUriPattern', () {
    test('matches "Dart VM service is listening on http://..."', () {
      final line =
          'The Dart VM service is listening on http://127.0.0.1:9999/xyz/';
      final match = vmServiceUriPattern.firstMatch(line);
      expect(match, isNotNull);
      expect(match!.group(1), 'http://127.0.0.1:9999/xyz/');
    });

    test('does not match unrelated stdout', () {
      final line = 'Starting Flutter application...';
      final match = vmServiceUriPattern.firstMatch(line);
      expect(match, isNull);
    });

    test('does not match partial prefix', () {
      final line = 'Something listening on http://localhost:1234/';
      final match = vmServiceUriPattern.firstMatch(line);
      expect(match, isNull);
    });
  });

  group('detectDevice', () {
    test('returns a device for current platform', () {
      if (Platform.isMacOS || Platform.isLinux) {
        final device = detectDevice();
        expect(device, isNotNull);
      }
    });

    test('MacOSDevice has correct name', () {
      final device = MacOSDevice();
      expect(device.name, 'macOS');
    });

    test('LinuxDevice has correct name', () {
      final device = LinuxDevice();
      expect(device.name, 'Linux');
    });

    test('AndroidDevice name includes deviceId when provided', () {
      final device = AndroidDevice(
        startForceStopProcess: exitsAtOnce,
        adbPath: 'adb',
        aapt2Path: 'aapt2',
        deviceId: 'emulator-5554',
      );
      expect(device.name, 'Android (emulator-5554)');
    });

    test('AndroidDevice name is "Android" when no deviceId', () {
      final device = AndroidDevice(
        startForceStopProcess: exitsAtOnce,
        adbPath: 'adb',
        aapt2Path: 'aapt2',
      );
      expect(device.name, 'Android');
    });
  });

  group('buildArgs', () {
    test('MacOSDevice returns empty buildArgs', () {
      expect(MacOSDevice().buildArgs, isEmpty);
    });

    test('LinuxDevice returns platform flag when not on Linux', () {
      final device = LinuxDevice();
      if (!Platform.isLinux) {
        expect(device.buildArgs, [
          '--platforms=@rules_flutter//flutter/platforms:linux_x64',
        ]);
      } else {
        expect(device.buildArgs, isEmpty);
      }
    });

    test('WindowsDevice returns platform flag when not on Windows', () {
      final device = WindowsDevice();
      if (!Platform.isWindows) {
        expect(device.buildArgs, [
          '--platforms=@rules_flutter//flutter/platforms:windows_x64',
        ]);
      } else {
        expect(device.buildArgs, isEmpty);
      }
    });

    test('IOSSimulatorDevice returns ios_multi_cpus=sim_arm64', () {
      final device = IOSSimulatorDevice(udid: 'TEST');
      expect(device.buildArgs, ['--ios_multi_cpus=sim_arm64']);
    });

    test('AndroidDevice builds for the ABI it was told', () {
      expect(
        AndroidDevice(
          startForceStopProcess: exitsAtOnce,
          adbPath: 'adb',
          aapt2Path: 'aapt2',
          abi: 'arm64-v8a',
        ).buildArgs,
        [
          '--@rules_android//flags:android_platforms=@rules_android//:arm64-v8a',
        ],
      );
      expect(
        AndroidDevice(
          startForceStopProcess: exitsAtOnce,
          adbPath: 'adb',
          aapt2Path: 'aapt2',
          abi: 'x86_64',
        ).buildArgs,
        [
          '--@rules_android//flags:android_platforms=@rules_android//:x86_64',
        ],
      );
    });

    // An APK is dexed, linked, zipped and signed, and a macOS debug bundle's
    // App.framework is the whole program's kernel; a restart needs only the
    // libraries and assets that go into them, so each says where to read
    // those without building the artifact.
    test('AndroidDevice names the bundle parts a restart reads', () {
      final parts = AndroidDevice(
        startForceStopProcess: exitsAtOnce,
        adbPath: 'adb',
        aapt2Path: 'aapt2',
        abi: 'x86_64',
      ).launchBundleParts;
      expect(parts, isNotNull);
      expect(parts!.aspect, contains('android_bundle_parts.bzl'));
      expect(parts.assetsGroup, 'flutter_android_bundle_parts');
      expect(parts.nativeLibsGroup, 'flutter_android_native_libs');
    });

    test('MacOSDevice names the bundle parts a restart reads', () {
      final parts = MacOSDevice().launchBundleParts;
      expect(parts, isNotNull);
      expect(parts!.aspect, contains('macos_bundle_parts.bzl'));
      expect(parts.assetsGroup, 'flutter_macos_bundle_parts');
      expect(parts.nativeLibsGroup, 'flutter_macos_native_libs');
    });

    // An iOS debug App.framework, a Linux or Windows debug bundle's kernel and
    // an iOS app's signing are all rebuilt by every Dart edit, so a restart
    // reads the parts of each the way it does a macOS bundle's.
    for (final (label, device, file, platform) in [
      ('IOSSimulatorDevice', IOSSimulatorDevice(udid: 'TEST'), 'ios', 'ios'),
      ('IOSDevice', IOSDevice(udid: 'TEST'), 'ios', 'ios'),
      ('LinuxDevice', LinuxDevice(), 'linux', 'linux'),
      ('WindowsDevice', WindowsDevice(), 'windows', 'windows'),
    ]) {
      test('$label names the bundle parts a restart reads', () {
        final parts = device.launchBundleParts;
        expect(parts, isNotNull);
        expect(
          parts!.aspect,
          '@rules_flutter//flutter:${file}_bundle_parts.bzl%'
          'flutter_${file}_bundle_parts_aspect',
        );
        expect(parts.assetsGroup, 'flutter_${platform}_bundle_parts');
        expect(parts.nativeLibsGroup, 'flutter_${platform}_native_libs');
      });
    }

    test('a web device names no parts: it has no bundle to read', () {
      expect(WebDevice().launchBundleParts, isNull);
    });

    test('AndroidDevice does not guess an ABI it has not been told', () {
      expect(
        () => AndroidDevice(
          startForceStopProcess: exitsAtOnce,
          adbPath: 'adb',
          aapt2Path: 'aapt2',
        ).buildArgs,
        throwsStateError,
      );
    });

    group('AndroidDevice asks the device its ABI', () {
      Future<(List<String>, AndroidDevice)> resolved(
        String abiList, {
        String? deviceId,
      }) async {
        final calls = <String>[];
        final device = AndroidDevice(
          startForceStopProcess: exitsAtOnce,
          aapt2Path: 'aapt2',
          deviceId: deviceId,
          adbPath: 'adb',
          runProcess: (exe, args) async {
            calls.add('$exe ${args.join(' ')}');
            return ProcessResult(0, 0, '$abiList\n', '');
          },
        );
        await device.resolveBuildArgs();
        return (calls, device);
      }

      test('a phone builds for its own ABI', () async {
        final (calls, device) = await resolved(
          'arm64-v8a,armeabi-v7a,armeabi',
          deviceId: 'PIXEL',
        );
        expect(calls, ['adb -s PIXEL shell getprop ro.product.cpu.abilist']);
        expect(device.buildArgs, [
          '--@rules_android//flags:android_platforms=@rules_android//:arm64-v8a',
        ]);
      });

      test(
        'an x86_64 emulator builds for x86_64, not the ABI it translates',
        () async {
          final (_, device) = await resolved('x86_64,arm64-v8a,x86');
          expect(device.buildArgs, [
            '--@rules_android//flags:android_platforms=@rules_android//:x86_64',
          ]);
        },
      );

      test('a 32-bit ARM device builds for armeabi-v7a', () async {
        final (_, device) = await resolved('armeabi-v7a,armeabi');
        expect(device.buildArgs, [
          '--@rules_android//flags:android_platforms=@rules_android//:armeabi-v7a',
        ]);
      });

      test(
        'a device that runs no ABI we build for is refused by name',
        () async {
          expect(
            resolved('armeabi,mips'),
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'message',
                allOf(
                  contains('armeabi, mips'),
                  contains('armeabi-v7a'),
                  contains('arm64-v8a'),
                ),
              ),
            ),
          );
        },
      );

      test('a told ABI is not asked again', () async {
        final calls = <String>[];
        final device = AndroidDevice(
          startForceStopProcess: exitsAtOnce,
          aapt2Path: 'aapt2',
          abi: 'x86_64',
          adbPath: 'adb',
          runProcess: (exe, args) async {
            calls.add(args.join(' '));
            return ProcessResult(0, 0, '', '');
          },
        );
        await device.resolveBuildArgs();
        expect(calls, isEmpty);
      });

      test('an adb failure is reported with the device it asked', () async {
        final device = AndroidDevice(
          startForceStopProcess: exitsAtOnce,
          aapt2Path: 'aapt2',
          deviceId: 'PIXEL',
          adbPath: 'adb',
          runProcess: (exe, args) async =>
              ProcessResult(0, 1, '', 'device offline'),
        );
        expect(
          device.resolveBuildArgs(),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(contains('PIXEL'), contains('device offline')),
            ),
          ),
        );
      });
    });

    test('WebDevice returns empty buildArgs', () {
      expect(WebDevice().buildArgs, isEmpty);
    });
  });

  group('IOSSimulatorDevice', () {
    // `simctl`'s own `booted` picks whichever booted simulator it finds first.
    // With several booted, a stop or screenshot addressed that way reached a
    // different simulator from the one the app was launched on.
    test('a booted device addresses the simulator it launched on, after '
        'launch', () async {
      final calls = <String>[];
      final device = IOSSimulatorDevice.booted(
        runProcess: (exe, args) async {
          calls.add(args.join(' '));
          if (args.take(3).join(' ') == 'simctl list devices') {
            return ProcessResult(
              0,
              0,
              '{"devices":{"iOS":[{"udid":"SIM-FIRST"},{"udid":"SIM-2"}]}}',
              '',
            );
          }
          if (args.contains('displays')) {
            return displaysAnswer(args, [
              display('LCD', uniqueId: 'SCREEN-1', primary: true),
            ]);
          }
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async =>
            throw StateError('stop the launch here'),
      );
      expect(device.udid, 'booted');
      await expectLater(
        device.launch('/build/Runner.app'),
        throwsA(isA<StateError>()),
      );
      expect(device.udid, 'SIM-FIRST');
      expect(device.name, 'iOS Simulator (SIM-FIRST)');

      calls.clear();
      await device.screenshot(
        AppInstance(process: FakeProcess()),
        '/tmp/shot.png',
      );
      expect(calls, hasLength(2));
      expect(
        calls.first,
        startsWith('devicectl device info displays --device SIM-FIRST'),
      );
      expect(
        calls.last,
        startsWith(
          'devicectl device capture screenshot --device SIM-FIRST '
          '--destination /tmp/shot.png',
        ),
      );
    });

    test('has correct name with udid', () {
      final device = IOSSimulatorDevice(udid: 'ABC-123');
      expect(device.name, 'iOS Simulator (ABC-123)');
    });

    test('calls simctl install and launch', () async {
      final calls = <(String, List<String>)>[];
      final fakeLog = FakeProcess();
      final sim = FakeSimulatorLog(endStreamsAtLaunch: true);

      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: sim.run((exe, args) async {
          calls.add((exe, args));
          return simctlOk(args);
        }),
        startProcess: sim.start((exe, args) async {
          calls.add((exe, args));
          return fakeLog;
        }),
      );

      await device.launch('/path/to/MyApp.app');

      // Should have: boot (waited for), install, log stream spawn, launch.
      final xcrunCalls = calls.where((c) => c.$1 == 'xcrun').toList();
      expect(xcrunCalls.length, greaterThanOrEqualTo(4));

      final bootCall = xcrunCalls.firstWhere(
        (c) => c.$2.contains('bootstatus'),
      );
      expect(bootCall.$2, containsAllInOrder(['TEST-UDID', '-b']));
      expect(
        xcrunCalls.indexOf(bootCall),
        lessThan(xcrunCalls.indexWhere((c) => c.$2.contains('install'))),
        reason: 'nothing is installed before the boot has finished',
      );

      final installCall = xcrunCalls.firstWhere(
        (c) => c.$2.contains('install'),
      );
      expect(installCall.$2, contains('TEST-UDID'));
      expect(installCall.$2, contains('/path/to/MyApp.app'));

      final launchCall = xcrunCalls.firstWhere((c) => c.$2.contains('launch'));
      expect(launchCall.$2, contains('com.example.test'));
    });

    // Measured against `xcrun simctl` (Xcode 27.2): `bootstatus -b` on a device
    // that is already booted exits 0 at once, which is the ordinary case of
    // every run after the first on a simulator someone left booted.
    test('a simulator that is already booted is launched on', () async {
      final calls = <String>[];
      final sim = FakeSimulatorLog();
      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: sim.run((exe, args) async {
          calls.add(args.join(' '));
          return simctlOk(args);
        }),
        startProcess: sim.start((exe, args) async {
          final p = FakeProcess();
          if (args.contains('ndjson')) {
            unawaited(
              p.outputAttached.then(
                (_) => p.emitStdout(
                  json.encode({
                    'processID': 1234,
                    'eventMessage': _vmServiceLine,
                  }),
                ),
              ),
            );
          }
          return p;
        }),
      );

      final instance = await device.launch('/path/to/MyApp.app');

      expect(instance.vmServiceUri, isNotNull);
      expect(
        calls.where((c) => c.startsWith('simctl install')),
        hasLength(1),
        reason: 'the app has to be installed on the booted device',
      );
    });

    test('throws on simctl install failure', () async {
      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: (exe, args) async {
          if ((args as List).contains('install')) {
            return ProcessResult(0, 1, '', 'INSTALL_FAILED');
          }
          return simctlOk(args);
        },
        startProcess: (exe, args) async => FakeProcess(),
      );

      expect(() => device.launch('/path/to/MyApp.app'), throwsStateError);
    });

    // An .ipa is unpacked into a temp folder before anything else happens, and
    // only a launch that succeeds hands that folder to the AppInstance whose
    // stop deletes it. Every failure past the unpack has to delete it itself,
    // or each failed launch leaves an app's worth of files in TMPDIR.
    group('a failed launch leaves no unpacked app behind', () {
      /// Runs a simulator launch of an .ipa whose step [failAt] fails, and
      /// returns the folder the .ipa was unpacked into.
      Future<({String unpacked, List<FakeProcess> started})> failLaunch(
        String failAt,
      ) async {
        late String unpacked;
        final started = <FakeProcess>[];
        final device = IOSSimulatorDevice(
          udid: 'TEST-UDID',
          runProcess: (exe, args) async {
            if (exe == 'unzip') {
              unpacked = args.last;
              Directory(
                '$unpacked/Payload/Runner.app',
              ).createSync(recursive: true);
            }
            if (args.contains(failAt)) {
              return ProcessResult(0, 1, '', '$failAt failed');
            }
            return simctlOk(args);
          },
          startProcess: (exe, args) async {
            final process = FakeProcess();
            started.add(process);
            return process;
          },
        );
        await expectLater(
          device.launch('/path/to/app.ipa'),
          throwsA(isA<StateError>()),
        );
        return (unpacked: unpacked, started: started);
      }

      test('when the install fails', () async {
        final r = await failLaunch('install');
        expect(Directory(r.unpacked).existsSync(), isFalse);
      });

      // Past the install the two `log stream` helpers are running too, and a
      // launch that gives up must not leave them tailing the simulator's log.
      test('when the bundle id cannot be read', () async {
        final r = await failLaunch('read');
        expect(Directory(r.unpacked).existsSync(), isFalse);
        expect(r.started, hasLength(2));
        for (final process in r.started) {
          expect(process.killed, isTrue);
        }
      });
    });

    test('stop calls simctl terminate when bundleId is set', () async {
      final calls = <(String, List<String>)>[];
      final fakeLog = FakeProcess();

      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: (exe, args) async {
          calls.add((exe, args));
          return simctlOk(args);
        },
        startProcess: (exe, args) async => fakeLog,
      );

      final instance = AppInstance(process: fakeLog);
      await device.stop(instance);

      final terminateCall = calls.firstWhere((c) => c.$2.contains('terminate'));
      expect(terminateCall.$2, contains('com.example.test'));
    });

    // The usual device — `-d ios-simulator` names no bundle id — learns it
    // from the bundle at launch. Stop has to use that one: skipping the
    // terminate left the app running after the run ended, measured on an
    // iOS 27 simulator a quarter of an hour after `daemon.shutdown` answered.
    test(
      'stop terminates the bundle it launched when none was named',
      () async {
        final calls = <List<String>>[];
        final fakeLog = FakeProcess();
        final sim = FakeSimulatorLog(endStreamsAtLaunch: true);
        final device = IOSSimulatorDevice(
          udid: 'TEST-UDID',
          runProcess: sim.run((exe, args) async {
            calls.add([exe, ...args]);
            if (exe == 'defaults') {
              return ProcessResult(0, 0, 'com.example.fromplist\n', '');
            }
            return simctlOk(args);
          }),
          startProcess: sim.start((exe, args) async => fakeLog),
        );

        final instance = await device.launch('/path/to/MyApp.app');
        await device.stop(instance);

        expect(
          calls,
          contains(
            equals([
              'xcrun',
              'simctl',
              'terminate',
              'TEST-UDID',
              'com.example.fromplist',
            ]),
          ),
        );
      },
    );

    test('extracts .app from .ipa before install', () async {
      final calls = <(String, List<String>)>[];
      final fakeLog = FakeProcess();
      final sim = FakeSimulatorLog(endStreamsAtLaunch: true);

      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: sim.run((exe, args) async {
          calls.add((exe, args));
          if (exe == 'unzip') {
            // Simulate unzip by creating Payload/app.app directory.
            final dest = args.last;
            Directory('$dest/Payload/app.app').createSync(recursive: true);
            File('$dest/Payload/app.app/Info.plist').writeAsStringSync('');
          }
          return simctlOk(args);
        }),
        startProcess: sim.start((exe, args) async {
          calls.add((exe, args));
          return fakeLog;
        }),
      );

      final app = await device.launch('/path/to/app.ipa');
      addTearDown(app.disposeScratchDirs);

      // Should have called unzip.
      final unzipCall = calls.firstWhere((c) => c.$1 == 'unzip');
      expect(unzipCall.$2, contains('/path/to/app.ipa'));

      // simctl install should receive the extracted .app, not the .ipa.
      final installCall = calls.firstWhere(
        (c) => c.$1 == 'xcrun' && c.$2.contains('install'),
      );
      expect(installCall.$2.last, endsWith('.app'));
      expect(installCall.$2.last, isNot(endsWith('.ipa')));
    });

    test(
      'installs the extracted bundle with fresh modification times',
      () async {
        // Bazel writes every file into the .ipa with the same fixed 1980 mtime.
        // The simulator's installer keeps an already-installed file whose size
        // and mtime both match, so a rebuilt native library that kept its size
        // was silently left at the old machine code. Measured on an iOS 27
        // simulator: `simctl install` of the new bundle left the old `add`, and
        // the same install after a `touch` replaced it.
        final fakeLog = FakeProcess();
        final sim = FakeSimulatorLog(endStreamsAtLaunch: true);
        DateTime? mtimeAtInstall;
        late String extractedLib;

        final device = IOSSimulatorDevice(
          udid: 'TEST-UDID',
          bundleId: 'com.example.test',
          runProcess: sim.run((exe, args) async {
            if (exe == 'unzip') {
              final dest = args.last;
              extractedLib =
                  '$dest/Payload/app.app/Frameworks/add.framework/add';
              File(extractedLib)
                ..createSync(recursive: true)
                ..writeAsBytesSync([1, 2, 3])
                ..setLastModifiedSync(DateTime.utc(1980));
            }
            if (exe == 'xcrun' && args.contains('install')) {
              mtimeAtInstall = File(extractedLib).lastModifiedSync();
            }
            return simctlOk(args);
          }),
          startProcess: sim.start((exe, args) async => fakeLog),
        );
        final before = DateTime.now().subtract(const Duration(seconds: 5));
        final app = await device.launch('/path/to/app.ipa');
        addTearDown(app.disposeScratchDirs);

        expect(mtimeAtInstall, isNotNull);
        expect(mtimeAtInstall!.isAfter(before), isTrue);
      },
    );

    test('discovers VM service URI from log stream', () async {
      // launch() starts two `log stream` processes: a discovery stream
      // matching only the VM-service announcement (`--style ndjson`), then the
      // app's own output stream (`--style json`). They need separate fakes. The announcement
      // has to be written once the *discovery* pump is reading — a single
      // shared fake signals "attached" when the output-log pump subscribes,
      // which happens first, and FakeProcess's controllers are broadcast, so
      // the line would be delivered to the log drain and dropped for
      // discovery.
      final sim = FakeSimulatorLog();
      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: sim.run((exe, args) async => simctlOk(args)),
        startProcess: sim.start((exe, args) async {
          final p = FakeProcess();
          if (args.contains('ndjson')) {
            unawaited(
              p.outputAttached.then(
                (_) => p.emitStdout(
                  json.encode({
                    'processID': 1234,
                    'eventMessage':
                        'flutter: The Dart VM service is listening on '
                        'http://127.0.0.1:54321/abc=/',
                  }),
                ),
              ),
            );
          }
          return p;
        }),
      );

      final instance = await device.launch('/path/to/MyApp.app');
      expect(instance.vmServiceUri, isNotNull);
      expect(instance.vmServiceUri.toString(), 'http://127.0.0.1:54321/abc=/');
    });
  });

  group('WebDevice', () {
    test('has correct name', () {
      final device = WebDevice();
      expect(device.name, 'Chrome');
    });

    test('refuses to hand out a reload strategy', () {
      // A browser's strategy is built by the web assemblers from the run's
      // module server, never from the device. Inheriting `Device`'s answer
      // would hand a web run `VmServiceReloadStrategy` — the native one — and
      // every reload would go looking for a VM service the browser does not
      // have and blame it for being absent. Refused by name instead.
      expect(
        () => WebDevice().createReloadStrategy(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('WebPipelineAssembler'), contains('Chrome')),
          ),
        ),
      );
    });
  });

  group('WebDevice running a named browser', () {
    test('needs that browser and no other, so a missing one is not made up for '
        'by the host\'s own Chrome', () async {
      final tools = await WebDevice(
        chromePath: '/no/such/chrome',
      ).requiredHostTools();

      expect(tools, hasLength(1));
      expect(tools.single.candidates, ['/no/such/chrome']);
      expect(tools.single.pathNames, isEmpty);
      expect(
        tools.single.require,
        throwsA(
          isA<MissingHostToolException>().having(
            (e) => e.message,
            'message',
            contains('/no/such/chrome'),
          ),
        ),
      );
    });

    test('picks the bundle directory out of what the build made, whatever '
        'order the outputs come in', () async {
      final out = await Directory.systemTemp.createTemp('web_outputs_');
      addTearDown(() => out.delete(recursive: true));
      final bundle = Directory(p.join(out.path, 'app_web'))..createSync();
      final serving = File(p.join(out.path, 'app_web.serving.json'))
        ..writeAsStringSync('{}');
      final dev = File(p.join(out.path, 'app.dev_config.json'))
        ..writeAsStringSync('{}');

      for (final order in [
        [bundle.path, serving.path, dev.path],
        [serving.path, dev.path, bundle.path],
      ]) {
        expect(WebDevice().pickArtifact(order), bundle.path);
      }
    });

    test('says so when the build made no bundle directory', () {
      expect(
        () => WebDevice().pickArtifact(['/out/app_web.serving.json']),
        throwsA(
          isA<NotAWebBundle>().having(
            (e) => e.message,
            'message',
            contains('_web'),
          ),
        ),
      );
    });

    test('says how Chrome ended when it did, and nothing when it is still '
        'running', () async {
      final process = FakeProcess();
      final instance = AppInstance(process: process);
      final device = WebDevice();

      fakeAsync((async) {
        String? whileRunning = 'unset';
        device.whyAppExited(instance).then((r) => whileRunning = r);
        async.elapse(const Duration(minutes: 1));
        expect(whileRunning, isNull);
      });

      process.complete(139);
      final why = await device.whyAppExited(instance);
      expect(why, allOf(contains('Chrome'), contains('exited with code 139')));
    });
  });

  group('findChrome', () {
    test('returns a string or null', () {
      // Just verifies it doesn't throw.
      final result = findChrome();
      expect(result, anyOf(isNull, isA<String>()));
    });
  });

  group('pressKeyOverCdp', () {
    const appUrl = 'http://localhost:8080';

    /// A browser's DevTools endpoint with the app's page on it: `/json` lists
    /// the page, and the page's socket records what it is sent and answers
    /// the focus probe with [pageState].
    Future<(HttpServer, List<Map<String, dynamic>>)> fakeBrowser(
      Map<String, Object> pageState,
    ) async {
      final received = <Map<String, dynamic>>[];
      final server = await HttpServer.bind('127.0.0.1', 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        if (request.uri.path == '/json') {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            json.encode([
              {
                'type': 'page',
                'url': 'about:blank',
                'webSocketDebuggerUrl': 'ws://blank',
              },
              {
                'type': 'page',
                'url': '$appUrl/',
                'webSocketDebuggerUrl': 'ws://127.0.0.1:${server.port}/page',
              },
            ]),
          );
          await request.response.close();
          return;
        }
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((data) {
          final message = json.decode(data as String) as Map<String, dynamic>;
          received.add(message);
          socket.add(
            json.encode({
              'id': message['id'],
              'result': message['method'] == 'Runtime.evaluate'
                  ? {
                      'result': {'value': pageState},
                    }
                  : <String, Object>{},
            }),
          );
        });
      });
      return (server, received);
    }

    test('reads the focus first, then sends the chord in order on the app '
        'page', () async {
      final (server, received) = await fakeBrowser({
        'focus': 'flutter-view > input',
        'editable': true,
        'visible': true,
      });

      final press = await pressKeyOverCdp(
        cdpPort: server.port,
        appUrl: appUrl,
        chord: KeyChord.parse('Control+K', controlOrMetaIsMeta: true),
        macCommands: true,
      );

      expect(received.first['method'], 'Runtime.evaluate');
      final keys = received.skip(1).toList();
      expect(
        keys.map((m) => m['method']),
        everyElement('Input.dispatchKeyEvent'),
      );
      expect(
        keys.map((m) => '${m['params']['type']} ${m['params']['code']}'),
        [
          'rawKeyDown ControlLeft',
          'rawKeyDown KeyK',
          'keyUp KeyK',
          'keyUp ControlLeft',
        ],
      );
      expect(keys[1]['params']['commands'], ['deleteToEndOfParagraph']);
      expect(press.sent, [for (final m in keys) m['params']]);
      expect(press.focus, 'flutter-view > input');
      expect(press.focusIsEditable, isTrue);
      expect(press.pageVisible, isTrue);
    });

    test('reports a page with no field focused, and a hidden page', () async {
      final (server, _) = await fakeBrowser({
        'focus': 'flutter-view',
        'editable': false,
        'visible': false,
      });

      final press = await pressKeyOverCdp(
        cdpPort: server.port,
        appUrl: appUrl,
        chord: KeyChord.parse('a', controlOrMetaIsMeta: true),
        macCommands: false,
      );

      expect(press.focusIsEditable, isFalse);
      expect(press.pageVisible, isFalse);
      expect(press.sent.first['commands'], isEmpty);
    });
  });

  group('AndroidDevice.launch', () {
    // As `flutter run` does (flutter_tools' `AndroidDevice.startApp`).
    test('stops the app before it installs and starts it', () async {
      final calls = <List<String>>[];
      final fakeLogcat = FakeProcess();
      Future<ProcessResult> adb(String exe, List<String> args) async {
        calls.add(args);
        return ProcessResult(0, 0, '', '');
      }

      final device = AndroidDevice(
        startForceStopProcess: answeringAs(adb),
        aapt2Path: 'aapt2',
        packageName: 'com.example.app',
        adbPath: 'adb',
        runProcess: adb,
        startProcess: (exe, args) async => fakeLogcat,
      );
      unawaited(fakeLogcat.outputAttached.then((_) => fakeLogcat.complete(0)));

      await device.launch('/path/to/app.apk');

      final stop = calls.indexWhere(
        (c) => c.join(' ') == 'shell am force-stop com.example.app',
      );
      expect(stop, isNot(-1), reason: '$calls');
      expect(stop, lessThan(calls.indexWhere((c) => c.contains('install'))));
      expect(
        stop,
        lessThan(
          calls.indexWhere((c) => c.contains('am') && c.contains('start')),
        ),
      );
    });

    // flutter_tools' `stopApp` logs a failed stop and goes on, and so does
    // this: the install stops a running copy itself, so the stop is never what
    // a launch depends on.
    group('a stop that does not work', () {
      AndroidDevice deviceWhoseStop(
        Future<Process> Function() onStop,
        List<List<String>> calls,
        FakeProcess logcat,
      ) => AndroidDevice(
        startForceStopProcess: (exe, args) {
          calls.add(args);
          return onStop();
        },
        aapt2Path: 'aapt2',
        packageName: 'com.example.app',
        adbPath: 'adb',
        runProcess: (exe, args) async {
          calls.add(args);
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async => logcat,
      );

      test('is reported, and the launch goes on', () async {
        final records = <LogRecord>[];
        final sub = Logger.root.onRecord.listen(records.add);
        addTearDown(sub.cancel);
        final calls = <List<String>>[];
        final logcat = FakeProcess();
        unawaited(logcat.outputAttached.then((_) => logcat.complete(0)));
        final device = deviceWhoseStop(
          () => answeringAs(
            (_, _) async => ProcessResult(0, 1, '', 'Error: device offline'),
          )('adb', const []),
          calls,
          logcat,
        );

        await device.launch('/path/to/app.apk');

        expect(calls.any((c) => c.contains('install')), isTrue);
        expect(
          records.map((r) => '${(r.object as Map)['text']}'),
          contains(contains('device offline')),
        );
      });

      test('that never answers is given up on after 30 s', () {
        fakeAsync((async) {
          final calls = <List<String>>[];
          final logcat = FakeProcess();
          unawaited(logcat.outputAttached.then((_) => logcat.complete(0)));
          final wedged = FakeProcess();
          final device = deviceWhoseStop(() async => wedged, calls, logcat);

          // What follows the install reads real files, which fake time does
          // not reach; that the install is reached is what this asks.
          unawaited(
            device
                .launch('/path/to/app.apk')
                .then((_) {}, onError: (Object _) {}),
          );
          async.elapse(const Duration(seconds: 29));
          expect(calls.any((c) => c.contains('install')), isFalse);

          async.elapse(const Duration(seconds: 2));
          expect(calls.any((c) => c.contains('install')), isTrue);
          expect(
            wedged.signals,
            [ProcessSignal.sigkill],
            reason: 'an adb left running holds the tool open after the run',
          );
        });
      });
    });

    test('calls adb install with -r and device flag', () async {
      final calls = <(String, List<String>)>[];
      final fakeLogcat = FakeProcess();

      final device = AndroidDevice(
        startForceStopProcess: exitsAtOnce,
        aapt2Path: 'aapt2',
        deviceId: 'emulator-5554',
        packageName: 'com.example.app',
        adbPath: 'adb',
        runProcess: (exe, args) async {
          calls.add((exe, args));
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async {
          calls.add((exe, args));
          return fakeLogcat;
        },
      );

      unawaited(fakeLogcat.outputAttached.then((_) => fakeLogcat.complete(0)));

      await device.launch('/path/to/app.apk');

      final runCalls = calls.where((c) => c.$1 == 'adb').toList();
      expect(runCalls.length, greaterThanOrEqualTo(3));

      final installCall = runCalls.firstWhere((c) => c.$2.contains('install'));
      expect(installCall.$2, contains('-s'));
      expect(installCall.$2, contains('emulator-5554'));
      expect(installCall.$2, contains('-r'));
      expect(installCall.$2, contains('/path/to/app.apk'));
    });

    test(
      '--start-paused rides on the launch intent as a boolean extra',
      () async {
        // `--ez start-paused true` is where the Android embedder reads it; the
        // activity is started by an intent, so there is no argv to put it on.
        final calls = <(String, List<String>)>[];
        final fakeLogcat = FakeProcess();
        final device = AndroidDevice(
          startForceStopProcess: exitsAtOnce,
          aapt2Path: 'aapt2',
          packageName: 'com.example.app',
          activityName: '.FlutterActivity',
          adbPath: 'adb',
          runProcess: (exe, args) async {
            calls.add((exe, args));
            return ProcessResult(0, 0, '', '');
          },
          startProcess: (exe, args) async => fakeLogcat,
        )..startPaused = true;
        unawaited(
          fakeLogcat.outputAttached.then((_) => fakeLogcat.complete(0)),
        );

        await device.launch('/path/to/app.apk');

        final startCall = calls.firstWhere(
          (c) => c.$2.contains('am') && c.$2.contains('start'),
        );
        expect(
          startCall.$2,
          containsAllInOrder(['--ez', 'start-paused', 'true']),
        );
      },
    );

    test('an ordinary launch carries no start-paused extra', () async {
      final calls = <(String, List<String>)>[];
      final fakeLogcat = FakeProcess();
      final device = AndroidDevice(
        startForceStopProcess: exitsAtOnce,
        aapt2Path: 'aapt2',
        packageName: 'com.example.app',
        adbPath: 'adb',
        runProcess: (exe, args) async {
          calls.add((exe, args));
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async => fakeLogcat,
      );
      unawaited(fakeLogcat.outputAttached.then((_) => fakeLogcat.complete(0)));

      await device.launch('/path/to/app.apk');

      final startCall = calls.firstWhere(
        (c) => c.$2.contains('am') && c.$2.contains('start'),
      );
      expect(startCall.$2, isNot(contains('start-paused')));
    });

    test('calls adb shell am start with package/activity', () async {
      final calls = <(String, List<String>)>[];
      final fakeLogcat = FakeProcess();

      final device = AndroidDevice(
        startForceStopProcess: exitsAtOnce,
        aapt2Path: 'aapt2',
        packageName: 'com.example.app',
        activityName: '.FlutterActivity',
        adbPath: 'adb',
        runProcess: (exe, args) async {
          calls.add((exe, args));
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async => fakeLogcat,
      );

      unawaited(fakeLogcat.outputAttached.then((_) => fakeLogcat.complete(0)));

      await device.launch('/path/to/app.apk');

      final startCall = calls.firstWhere(
        (c) => c.$2.contains('am') && c.$2.contains('start'),
      );
      expect(startCall.$2, contains('shell'));
      expect(startCall.$2, contains('am'));
      expect(startCall.$2, contains('start'));
      expect(startCall.$2, contains('-n'));
      expect(startCall.$2, contains('com.example.app/.FlutterActivity'));
    });

    test('defaults activityName to .MainActivity', () async {
      final calls = <(String, List<String>)>[];
      final fakeLogcat = FakeProcess();

      final device = AndroidDevice(
        startForceStopProcess: exitsAtOnce,
        aapt2Path: 'aapt2',
        packageName: 'com.example.app',
        adbPath: 'adb',
        runProcess: (exe, args) async {
          calls.add((exe, args));
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async => fakeLogcat,
      );

      unawaited(fakeLogcat.outputAttached.then((_) => fakeLogcat.complete(0)));

      await device.launch('/path/to/app.apk');

      final startCall = calls.firstWhere(
        (c) => c.$2.contains('am') && c.$2.contains('start'),
      );
      expect(startCall.$2, contains('com.example.app/.MainActivity'));
    });

    test('throws on adb install failure', () async {
      final device = AndroidDevice(
        startForceStopProcess: exitsAtOnce,
        aapt2Path: 'aapt2',
        packageName: 'com.example.app',
        adbPath: 'adb',
        runProcess: (exe, args) async {
          return ProcessResult(0, 1, '', 'INSTALL_FAILED');
        },
        startProcess: (exe, args) async => FakeProcess(),
      );

      expect(
        () => device.launch('/path/to/app.apk'),
        throwsStateError,
      );
    });

    /// `INSTALL_FAILED_INSUFFICIENT_STORAGE` is the one install failure a
    /// Flutter developer hits without having done anything wrong: a debug APK
    /// carries the whole debug engine, and a stock AVD's 6 GB data partition
    /// cannot take it. adb's own message — `Failure
    /// [INSTALL_FAILED_INSUFFICIENT_STORAGE: Failed to override installation
    /// location]` — names neither size, so it reads as a bug in the tool
    /// rather than as a device that is out of room.
    test('a failed adb command names the device it addressed', () async {
      // adb's own errors name neither the serial nor the flag that carried it,
      // and some of them are *about* the serial: `unknown host service
      // '<tail>:features'` is what it answers when the `-s` value has a colon.
      // A reader who cannot see the serial the tool used has nothing to compare
      // against the one they would have typed.
      final device = AndroidDevice(
        startForceStopProcess: exitsAtOnce,
        aapt2Path: 'aapt2',
        deviceId: '58051JEBF01271',
        packageName: 'com.example.app',
        adbPath: 'adb',
        runProcess: (exe, args) async => args.contains('install')
            ? ProcessResult(0, 1, '', "adb: unknown host service 'x:features'")
            : ProcessResult(0, 0, '', ''),
        startProcess: (exe, args) async => FakeProcess(),
      );

      await expectLater(
        device.launch('/tmp/app.apk'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('adb -s 58051JEBF01271'),
              contains('unknown host service'),
            ),
          ),
        ),
      );
    });

    test('a launch that named no device does not invent one', () async {
      // `-d android` lets adb choose, and its message says which it chose or
      // why it would not. Quoting a serial we never passed would be a fiction.
      final device = AndroidDevice(
        startForceStopProcess: exitsAtOnce,
        aapt2Path: 'aapt2',
        packageName: 'com.example.app',
        adbPath: 'adb',
        runProcess: (exe, args) async => args.contains('install')
            ? ProcessResult(0, 1, '', 'adb: more than one device/emulator')
            : ProcessResult(0, 0, '', ''),
        startProcess: (exe, args) async => FakeProcess(),
      );

      await expectLater(
        device.launch('/tmp/app.apk'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('more than one device'),
              isNot(contains('adb -s')),
            ),
          ),
        ),
      );
    });

    group('insufficient storage', () {
      late Directory sandbox;
      late String apkPath;

      setUp(() {
        sandbox = Directory.systemTemp.createTempSync('android_storage_test');
        apkPath = p.join(sandbox.path, 'app.apk');
        // Size is read off the real file, so the message can only ever quote
        // a number that is true of the APK being installed.
        File(apkPath).writeAsBytesSync(List.filled(3 * 1024 * 1024, 0));
      });

      tearDown(() => sandbox.deleteSync(recursive: true));

      /// A device whose `adb install` fails for want of space, whose `df`
      /// reports [availableKb] free, and whose `pm path` says the package is
      /// installed only when [alreadyInstalled].
      AndroidDevice outOfSpace({
        required int availableKb,
        bool alreadyInstalled = false,
      }) => AndroidDevice(
        startForceStopProcess: exitsAtOnce,
        aapt2Path: 'aapt2',
        packageName: 'com.example.app',
        adbPath: 'adb',
        runProcess: (exe, args) async {
          if (args.contains('install')) {
            return ProcessResult(
              0,
              1,
              '',
              'adb: failed to install $apkPath: '
                  'Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE: Failed to '
                  'override installation location]',
            );
          }
          if (args.contains('df')) {
            return ProcessResult(0, 0, '''
Filesystem       1K-blocks    Used Available Use% Mounted on
/dev/block/dm-54   6082144 3266184   $availableKb  55% /data/user/0
''', '');
          }
          if (args.contains('path')) {
            return alreadyInstalled
                ? ProcessResult(0, 0, 'package:/data/app/base.apk\n', '')
                : ProcessResult(0, 1, '', '');
          }
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async => FakeProcess(),
      );

      test('reports the APK size, the free space and how to get room', () async {
        await expectLater(
          outOfSpace(availableKb: 2673748).launch(apkPath),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                // The two numbers adb never prints, which are the whole
                // diagnosis: 3 MB of APK against 2.5 GB free.
                contains('3.0 MB'),
                contains('2.5 GB'),
                // The remedy is a larger data partition, and the message names
                // the APK it measured rather than making a flat claim about
                // debug APKs in general.
                contains('640 MB debug APK'),
                contains('disk.dataPartition.size'),
                contains('config.ini'),
                // `-partition-size` is a no-op on userdata, so it appears only
                // as the trap it is — never as the remedy.
                contains('-partition-size flag does not resize userdata'),
              ),
            ),
          ),
        );
      });

      test('offers uninstall only when a copy is already installed', () async {
        await expectLater(
          outOfSpace(availableKb: 2673748, alreadyInstalled: true).launch(
            apkPath,
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('adb uninstall com.example.app'),
            ),
          ),
        );
        await expectLater(
          outOfSpace(availableKb: 2673748).launch(apkPath),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                isNot(contains('uninstall')),
                // Nothing to remove is itself worth saying: it rules out the
                // reading that a stale copy is holding the space.
                contains('not currently installed'),
              ),
            ),
          ),
        );
      });

      test('every other install failure keeps adb\'s own words', () async {
        // The diagnosis above is specific to running out of room. Anything
        // else — a bad signature, an ABI mismatch — is passed through
        // unembellished rather than dressed up as a storage problem.
        final device = AndroidDevice(
          startForceStopProcess: exitsAtOnce,
          aapt2Path: 'aapt2',
          packageName: 'com.example.app',
          adbPath: 'adb',
          runProcess: (exe, args) async => args.contains('force-stop')
              ? ProcessResult(0, 0, '', '')
              : args.contains('install')
              ? ProcessResult(0, 1, '', 'Failure [INSTALL_FAILED_INVALID_APK]')
              : fail('nothing but the stop and the install is asked of adb'),
          startProcess: (exe, args) async => FakeProcess(),
        );
        await expectLater(
          device.launch(apkPath),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('INSTALL_FAILED_INVALID_APK'),
                isNot(contains('data partition')),
              ),
            ),
          ),
        );
      });
    });

    /// A logcat launch whose `adb forward` behaves as [onForward] says.
    /// Everything else adb is asked to do succeeds with no output.
    AndroidDevice launchableDevice(
      FakeProcess logcat,
      ProcessResult Function() onForward,
    ) => AndroidDevice(
      startForceStopProcess: exitsAtOnce,
      aapt2Path: 'aapt2',
      packageName: 'com.example.app',
      adbPath: 'adb',
      runProcess: (exe, args) async =>
          args.contains('forward') ? onForward() : adbOk(args),
      startProcess: (exe, args) async => logcat,
    );

    /// The announcement a debug app writes to logcat. Its port is the
    /// *device's*, which is the whole reason a forward exists.
    void announceVmService(FakeProcess logcat) {
      unawaited(
        logcat.outputAttached.then(
          (_) => logcat.emitStdout(
            '01-02 03:04:05.678 I/flutter ( 1234): The Dart VM service is '
            'listening on http://127.0.0.1:12345/abc=/',
          ),
        ),
      );
    }

    test('dials the discovered VM service through the adb forward', () async {
      final fakeLogcat = FakeProcess();
      final device = launchableDevice(
        fakeLogcat,
        () => ProcessResult(0, 0, '41234\n', ''),
      );
      announceVmService(fakeLogcat);

      final instance = await device.launch('/path/to/app.apk');
      // 41234, not the announced 12345: the announced port is device-local and
      // the host reaches it only through the port adb allocated.
      expect(instance.vmServiceUri.toString(), 'http://127.0.0.1:41234/abc=/');
    });

    test('throws naming adb when the forward fails', () async {
      final fakeLogcat = FakeProcess();
      final device = launchableDevice(
        fakeLogcat,
        () => ProcessResult(0, 1, '', 'error: device offline'),
      );
      announceVmService(fakeLogcat);

      await expectLater(
        device.launch('/path/to/app.apk'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('adb forward'), contains('device offline')),
          ),
        ),
      );
    });

    // A launch that fails returns no AppInstance, so nothing would ever stop
    // its logcat: an `adb logcat` left running after the tool has gone.
    test('stops its logcat when the launch fails', () async {
      final fakeLogcat = FakeProcess();
      final device = launchableDevice(
        fakeLogcat,
        () => ProcessResult(0, 1, '', 'error: device offline'),
      );
      announceVmService(fakeLogcat);

      await expectLater(
        device.launch('/path/to/app.apk'),
        throwsA(isA<StateError>()),
      );
      expect(fakeLogcat.killed, isTrue);
    });

    test('abandoning a launch in flight stops its logcat', () async {
      final fakeLogcat = FakeProcess();
      final device = launchableDevice(
        fakeLogcat,
        () => ProcessResult(0, 0, '41234\n', ''),
      );
      // No announcement: the launch waits for the VM service, which is where
      // a teardown finds it.
      final launched = device.launch('/path/to/app.apk');
      await fakeLogcat.outputAttached;

      await device.abandonLaunch();
      expect(fakeLogcat.killed, isTrue);
      // What the kill does to a real logcat's pipes, and the launch's cue to
      // stop waiting.
      fakeLogcat.complete(-1);
      expect((await launched).vmServiceUri, isNull);
    });

    test(
      'abandoning a launch that returned leaves its logcat to stop',
      () async {
        final fakeLogcat = FakeProcess();
        final device = launchableDevice(
          fakeLogcat,
          () => ProcessResult(0, 0, '41234\n', ''),
        );
        announceVmService(fakeLogcat);
        await device.launch('/path/to/app.apk');

        await device.abandonLaunch();
        expect(fakeLogcat.killed, isFalse);
      },
    );

    test(
      'throws when the forward reports success but allocates no port',
      () async {
        final fakeLogcat = FakeProcess();
        final device = launchableDevice(
          fakeLogcat,
          () => ProcessResult(0, 0, '', ''),
        );
        announceVmService(fakeLogcat);

        // Exit 0 with nothing on stdout is adb breaking its own contract for
        // `tcp:0`. Handing the device-local URI on instead would have turned it
        // into a connect timeout against whatever the host has on port 12345.
        await expectLater(
          device.launch('/path/to/app.apk'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('no port to reach the VM service on'),
            ),
          ),
        );
      },
    );

    // The VM service of an app on a handset or emulator comes up when the app
    // does, and a first launch on a busy host takes minutes. Logcat does not
    // end when the app does, so what bounds the wait is the app's process:
    // present, the launch waits (and says so); gone, it fails at once with the
    // log's last words.
    group('waiting for the VM service', () {
      /// What `am start -W` prints for a launch that completed.
      const started =
          'Starting: Intent { cmp=com.example.app/.MainActivity }\n'
          'Status: ok\nLaunchState: COLD\nActivity: com.example.app/.MainActivity\n'
          'TotalTime: 765\nWaitTime: 768\nComplete\n';

      /// Launches on a device whose `pidof` answers [pids] on the n-th ask
      /// (counting from 0), whose `am start -W` answers [amStart], and whose
      /// forward succeeds. The launch's outcome is read off [launching] once the
      /// fake clock has moved.
      ({AndroidDevice device, FakeProcess logcat, List<List<String>> calls})
      deviceWith(
        String Function(int ask) pids, {
        Future<ProcessResult> Function()? amStart,
      }) {
        final logcat = FakeProcess();
        final calls = <List<String>>[];
        var asked = 0;
        final device = AndroidDevice(
          startForceStopProcess: exitsAtOnce,
          aapt2Path: 'aapt2',
          packageName: 'com.example.app',
          adbPath: 'adb',
          runProcess: (exe, args) async {
            calls.add(args);
            if (args.contains('pidof')) {
              return ProcessResult(0, 0, pids(asked++), '');
            }
            if (args.contains('forward')) {
              return ProcessResult(0, 0, '41234\n', '');
            }
            if (args.contains('am') && args.contains('start')) {
              return amStart == null
                  ? ProcessResult(0, 0, started, '')
                  : amStart();
            }
            return ProcessResult(0, 0, '', '');
          },
          startProcess: (exe, args) async => logcat,
        );
        return (device: device, logcat: logcat, calls: calls);
      }

      /// The launch of [device], its settled value or error visible as fake
      /// time passes.
      ({bool Function() done, Object? Function() error, Uri? Function() uri})
      launching(AndroidDevice device) {
        var done = false;
        Object? error;
        Uri? uri;
        device
            .launch('/path/to/app.apk')
            .then(
              (instance) {
                uri = instance.vmServiceUri;
                done = true;
              },
              onError: (Object e) {
                error = e;
                done = true;
              },
            );
        return (done: () => done, error: () => error, uri: () => uri);
      }

      /// Moves the fake clock by [by]. The streams a launch cancels hand back
      /// futures completed in the real zone, which fake time cannot run, so the
      /// real event loop is given a turn after each step.
      Future<void> pass(FakeAsync async, Duration by) async {
        async.elapse(by);
        for (var i = 0; i < 3; i++) {
          await Future<void>.delayed(Duration.zero);
          async.flushMicrotasks();
        }
      }

      /// Starts [start] inside [async]'s zone.
      T inside<T>(FakeAsync async, T Function() start) {
        late T result;
        async.run((_) => result = start());
        async.flushMicrotasks();
        return result;
      }

      Matcher stateErrorSaying(List<String> parts) => isA<StateError>().having(
        (e) => e.message,
        'message',
        allOf([for (final part in parts) contains(part)]),
      );

      test('starts the activity with -W, which reports whether the launch '
          'completed', () async {
        final async = FakeAsync();
        final w = deviceWith((_) => '777\n');
        inside(async, () => launching(w.device));
        await pass(async, const Duration(seconds: 1));
        final start = w.calls.firstWhere(
          (c) => c.contains('am') && c.contains('start'),
        );
        expect(start, contains('-W'));
      });

      test('an app that is alive and silent is waited for past 30 s, and '
          'its announcement is taken whenever it comes', () async {
        final async = FakeAsync();
        final w = deviceWith((_) => '777\n');
        final launch = inside(async, () => launching(w.device));

        await pass(async, const Duration(minutes: 5));
        expect(
          launch.done(),
          isFalse,
          reason: 'a slow start is not a failed one: the app is running',
        );

        w.logcat.emitStdout(
          '01-02 03:04:05.678 I/flutter (  777): The Dart VM service is '
          'listening on http://127.0.0.1:12345/abc=/',
        );
        await pass(async, const Duration(seconds: 1));
        expect(launch.error(), isNull);
        expect(launch.uri().toString(), 'http://127.0.0.1:41234/abc=/');
      });

      test('an app whose process goes away before announcing fails the '
          'launch at once, quoting the log', () async {
        final async = FakeAsync();
        // Running for the first two asks, then gone: it crashed.
        final w = deviceWith((ask) => ask < 2 ? '777\n' : '\n');
        final launch = inside(async, () => launching(w.device));
        w.logcat.emitStdout(
          '01-02 03:04:05.678 E/AndroidRuntime(  777): FATAL EXCEPTION: main',
        );

        await pass(async, const Duration(seconds: 20));
        expect(launch.done(), isTrue);
        expect(
          launch.error(),
          stateErrorSaying([
            'com.example.app',
            'exited before announcing a VM service',
            'FATAL EXCEPTION',
          ]),
        );
      });

      // The launch reported complete, so there was a process; one that is not
      // there at the next ask has died, and no count of asks is needed to say so.
      test('a launch that completed and left no process fails at the next '
          'ask', () async {
        final async = FakeAsync();
        final w = deviceWith((_) => '\n');
        final launch = inside(async, () => launching(w.device));

        await pass(async, const Duration(seconds: 3));
        expect(launch.done(), isTrue);
        expect(
          launch.error(),
          stateErrorSaying(['com.example.app', 'exited before announcing']),
        );
      });

      // What a Pixel (Android 16) printed for an app whose `onCreate` threw,
      // read off the device: the activity was launched, so the status is ok,
      // and the process died before the launch could name how it started, so
      // the state is UNKNOWN. A crash on start is not a launch that failed to
      // start; the dead process is what says so.
      test('a launch whose app crashed on start (Status: ok, LaunchState: '
          'UNKNOWN) fails when its process is gone', () async {
        final async = FakeAsync();
        final w = deviceWith(
          (_) => '\n',
          amStart: () async => ProcessResult(
            0,
            0,
            'Starting: Intent { cmp=com.example.app/.MainActivity }\n'
                'Status: ok\nLaunchState: UNKNOWN (0)\n'
                'Activity: com.example.app/.MainActivity\n'
                'WaitTime: 694\nComplete\n',
            '',
          ),
        );
        final launch = inside(async, () => launching(w.device));

        await pass(async, const Duration(seconds: 3));
        expect(
          launch.error(),
          stateErrorSaying(['com.example.app', 'exited before announcing']),
        );
      });

      // An exception after the engine started (`onCreate` throwing once
      // `super.onCreate` has returned) comes after the VM service is announced,
      // so the launch succeeds and the connection to the dead service is what
      // fails. That failure has to say the app exited, not blame the service.
      test('an app that announced its VM service and died is said to have '
          'exited, with the log', () async {
        final w = deviceWith((_) => '\n');
        final instance = AppInstance(process: w.logcat);
        instance.logs.add('E/AndroidRuntime( 7960): FATAL EXCEPTION: main');

        final why = await w.device.whyAppExited(instance);

        expect(
          why,
          allOf(
            contains('com.example.app exited'),
            contains('FATAL EXCEPTION'),
          ),
        );
      });

      test('an app still running is not said to have exited', () async {
        final w = deviceWith((_) => '777\n');

        expect(
          await w.device.whyAppExited(AppInstance(process: w.logcat)),
          isNull,
        );
      });

      // `am start -W` returns once the first frame is drawn. An app started
      // paused never draws one, so it has not answered, and no process is yet
      // proof of nothing: waiting for it is the only honest thing to do.
      test('a launch `am` has not answered is not judged by a clock', () async {
        final async = FakeAsync();
        final pending = Completer<ProcessResult>();
        final w = deviceWith((_) => '\n', amStart: () => pending.future);
        final launch = inside(async, () => launching(w.device));

        await pass(async, const Duration(minutes: 10));
        expect(launch.done(), isFalse);
        expect(launch.error(), isNull);

        // When `am` does answer that the launch completed, there was a process,
        // and its absence at the next ask is a death.
        pending.complete(ProcessResult(0, 0, started, ''));
        // Completed from outside the fake zone, so its listeners run on the
        // real event loop.
        await Future<void>.delayed(Duration.zero);
        await pass(async, const Duration(seconds: 3));
        expect(
          launch.error(),
          stateErrorSaying(['com.example.app', 'exited before announcing']),
        );
      });

      test(
        'a launch `am` reports failed is failed, with what it said',
        () async {
          final async = FakeAsync();
          final w = deviceWith(
            (_) => '\n',
            amStart: () async => ProcessResult(
              0,
              0,
              'Starting: Intent { cmp=com.example.app/.MainActivity }\n'
                  'Error type 3\n'
                  'Error: Activity class {com.example.app/com.example.app.MainActivity} does not exist.\n',
              '',
            ),
          );
          final launch = inside(async, () => launching(w.device));

          await pass(async, const Duration(seconds: 1));
          expect(launch.done(), isTrue);
          expect(
            launch.error(),
            stateErrorSaying(['am start', 'does not exist']),
          );
        },
      );

      test(
        'a launch with a status other than ok is failed, naming it',
        () async {
          final async = FakeAsync();
          final w = deviceWith(
            (_) => '777\n',
            amStart: () async => ProcessResult(
              0,
              0,
              'Status: canceled\nLaunchState: UNKNOWN (0)\n',
              '',
            ),
          );
          final launch = inside(async, () => launching(w.device));

          await pass(async, const Duration(seconds: 1));
          expect(launch.error(), stateErrorSaying(['canceled']));
        },
      );

      // `am` stops waiting after its own bound. That says the first frame was
      // not drawn in time, which a loaded host does, not that nothing started.
      test('a launch `am` gave up waiting for is not failed by that', () async {
        final async = FakeAsync();
        final w = deviceWith(
          (_) => '777\n',
          amStart: () async => ProcessResult(
            0,
            0,
            'Starting: Intent { cmp=com.example.app/.MainActivity }\n'
                'Status: timeout\nLaunchState: UNKNOWN (-1)\n'
                'Activity: com.example.app/.MainActivity\n'
                'WaitTime: 10170\nComplete\n',
            '',
          ),
        );
        final launch = inside(async, () => launching(w.device));

        await pass(async, const Duration(minutes: 3));
        expect(launch.done(), isFalse);
      });

      // The VM service of a process that was already running was announced
      // before this launch, and nothing will announce it again.
      test('a launch that found the app already running says why no '
          'announcement can come', () async {
        final async = FakeAsync();
        final w = deviceWith(
          (_) => '777\n',
          amStart: () async => ProcessResult(
            0,
            0,
            'Status: ok\nLaunchState: WARM\nActivity: com.example.app/.MainActivity\n',
            '',
          ),
        );
        final launch = inside(async, () => launching(w.device));

        await pass(async, const Duration(seconds: 1));
        expect(
          launch.error(),
          stateErrorSaying(['already running', 'WARM']),
        );
      });

      test('a release app has no VM service to wait for', () async {
        final async = FakeAsync();
        final w = deviceWith((_) => '777\n');
        w.device.buildMode = BuildMode.release;
        final launch = inside(async, () => launching(w.device));

        await pass(async, Duration.zero);
        expect(launch.done(), isTrue, reason: 'nothing is announced');
        expect(launch.error(), isNull);
        expect(launch.uri(), isNull);
      });

      test(
        'a release app whose launch failed is failed all the same',
        () async {
          final async = FakeAsync();
          final w = deviceWith(
            (_) => '777\n',
            amStart: () async =>
                ProcessResult(0, 0, 'Error: Activity not started\n', ''),
          );
          w.device.buildMode = BuildMode.release;
          final launch = inside(async, () => launching(w.device));

          await pass(async, const Duration(seconds: 1));
          expect(launch.error(), stateErrorSaying(['not started']));
        },
      );
    });

    test('stop calls force-stop when packageName is set', () async {
      final calls = <(String, List<String>)>[];
      final fakeLogcat = FakeProcess();

      final device = AndroidDevice(
        startForceStopProcess: exitsAtOnce,
        aapt2Path: 'aapt2',
        packageName: 'com.example.app',
        adbPath: 'adb',
        runProcess: (exe, args) async {
          calls.add((exe, args));
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async => fakeLogcat,
      );

      final instance = AppInstance(process: fakeLogcat);
      await device.stop(instance);

      final stopCall = calls.firstWhere((c) => c.$2.contains('force-stop'));
      expect(stopCall.$2, contains('com.example.app'));
    });

    /// A launchable device that records every adb argument list it is given,
    /// and answers `adb forward tcp:0` with [hostPort].
    ///
    /// `--remove` also contains 'forward', and answering it with a port would
    /// be nonsense, so the two are told apart on `--remove` rather than by
    /// the substring the existing helper matches on.
    (AndroidDevice, List<List<String>>) recordingDevice(
      FakeProcess logcat, {
      String hostPort = '41234',
    }) {
      final calls = <List<String>>[];
      final device = AndroidDevice(
        startForceStopProcess: exitsAtOnce,
        aapt2Path: 'aapt2',
        packageName: 'com.example.app',
        adbPath: 'adb',
        runProcess: (exe, args) async {
          calls.add(args);
          return args.contains('forward') && !args.contains('--remove')
              ? ProcessResult(0, 0, '$hostPort\n', '')
              : adbOk(args);
        },
        startProcess: (exe, args) async => logcat,
      );
      return (device, calls);
    }

    test(
      'stop removes the forward this launch created, by its host port',
      () async {
        final fakeLogcat = FakeProcess();
        final (device, calls) = recordingDevice(fakeLogcat);
        announceVmService(fakeLogcat);

        final instance = await device.launch('/path/to/app.apk');
        await device.stop(instance);

        // `adb forward` writes a rule into the adb server, not into any process
        // this tool owns, so a run that does not remove it leaves a host port
        // bound to the device until the server restarts.
        expect(calls, anyElement(equals(['forward', '--remove', 'tcp:41234'])));
      },
    );

    test('stop never clears another session\'s forwards', () async {
      final fakeLogcat = FakeProcess();
      final (device, calls) = recordingDevice(fakeLogcat);
      announceVmService(fakeLogcat);

      await device.stop(await device.launch('/path/to/app.apk'));

      // Every forward on the host lives in the same adb server and nothing in
      // a rule says which run created it, so the wholesale removal would take
      // a concurrent session's VM service down with this one's.
      expect(calls.expand((args) => args), isNot(contains('--remove-all')));
    });

    // A teardown that arrives after `launch` returned but before the launcher
    // registered a session — during the VM-service connect, which can take
    // minutes — reaches the device only through [Device.abandonLaunch]. The
    // forward is adb-server state, so nothing else would ever remove it.
    test(
      'abandoning a launch force-stops the app and removes its forward',
      () async {
        final fakeLogcat = FakeProcess();
        final (device, calls) = recordingDevice(fakeLogcat);
        announceVmService(fakeLogcat);

        await device.launch('/path/to/app.apk');
        await device.abandonLaunch();

        expect(
          calls,
          anyElement(equals(['shell', 'am', 'force-stop', 'com.example.app'])),
        );
        expect(calls, anyElement(equals(['forward', '--remove', 'tcp:41234'])));
      },
    );

    test('stop removes nothing when the launch forwarded nothing', () async {
      final fakeLogcat = FakeProcess();
      final (device, calls) = recordingDevice(fakeLogcat);
      // No announcement: a release or profile launch has no VM service, so
      // `launch` never reaches the forward. Discovery gives up on its own.
      unawaited(fakeLogcat.outputAttached.then((_) => fakeLogcat.complete(0)));

      await device.stop(await device.launch('/path/to/app.apk'));

      expect(calls.expand((args) => args), isNot(contains('--remove')));
    });
  });

  // The dev tool drives programs it does not own. Each device declares which
  // ones its launch needs, so a misconfigured host is reported by name before
  // any work happens — and so no device is made to install another platform's
  // toolchain.
  group('requiredHostTools', () {
    Future<List<String>> namesFor(Device device) async => [
      for (final tool in await device.requiredHostTools()) tool.name,
    ];

    test('a desktop run needs nothing installed', () async {
      expect(await namesFor(MacOSDevice()), isEmpty);
      expect(await namesFor(LinuxDevice()), isEmpty);
      expect(await namesFor(WindowsDevice()), isEmpty);
    });

    // Its adb and aapt2 are the workspace's SDK's, built before the device
    // exists, so there is nothing on the host to look for.
    test('an Android run needs nothing installed', () async {
      expect(
        await namesFor(
          AndroidDevice(
            startForceStopProcess: exitsAtOnce,
            adbPath: '/sdk/adb',
            aapt2Path: '/sdk/aapt2',
          ),
        ),
        isEmpty,
      );
    });

    // Asked per device: a web run must not be refused for want of an Android
    // SDK.
    test('a Chrome run needs Chrome and nothing else', () async {
      expect(await namesFor(WebDevice()), ['Chrome']);
    });

    test('preflight names a tool that is not installed', () async {
      final device = _ToolsDevice([
        HostTool(
          name: 'nonexistent-tool',
          purpose: 'prove the point',
          remedy: 'Install nonexistent-tool.',
          environment: const {'PATH': ''},
        ),
      ]);

      await expectLater(
        device.preflight(),
        throwsA(
          isA<MissingHostToolException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('nonexistent-tool'),
              contains('Install nonexistent-tool.'),
            ),
          ),
        ),
      );
    });

    test('preflight passes when every tool is present', () async {
      final device = _ToolsDevice([
        HostTool(
          name: 'dart',
          purpose: 'prove the point',
          remedy: 'unreachable',
          candidates: [Platform.resolvedExecutable],
        ),
      ]);
      await device.preflight();
    });
  });

  // A cabled device's VM service is reached through an iproxy forward; a
  // wireless one is dialed at its own address. Requiring iproxy for the latter
  // would refuse a run that works.
  group('IOSDevice.requiredHostTools', () {
    IOSDevice deviceOn(String transportType) => IOSDevice(
      udid: 'TEST-UDID',
      runProcess: (exe, args) async {
        final out = args[args.indexOf('--json-output') + 1];
        File(out).writeAsStringSync(devicesJson(transportType));
        return ProcessResult(0, 0, '', '');
      },
      startProcess: (exe, args, env) async => FakeProcess(),
    );

    Future<List<String>> namesFor(Device device) async => [
      for (final tool in await device.requiredHostTools()) tool.name,
    ];

    test('a cabled device needs lldb and a port forwarder', () async {
      expect(await namesFor(deviceOn('wired')), ['lldb', 'iproxy']);
    });

    test('a wireless device needs no port forwarder', () async {
      expect(await namesFor(deviceOn('localNetwork')), ['lldb']);
    });

    // Only a JIT app needs the debugger; an AOT one is launched running.
    test('a profile build needs no debugger', () async {
      final device = deviceOn('wired')..buildMode = BuildMode.profile;
      expect(await namesFor(device), ['iproxy']);
    });

    // A release app has no VM service to forward to.
    test('a release build needs neither', () async {
      final device = deviceOn('wired')..buildMode = BuildMode.release;
      expect(await namesFor(device), isEmpty);
    });

    // Resolving the device is part of the preflight, so "no phone attached" is
    // also reported before a build rather than after one.
    test('reports an unattached device', () async {
      final device = IOSDevice(
        udid: 'OTHER-UDID',
        runProcess: (exe, args) async {
          final out = args[args.indexOf('--json-output') + 1];
          File(out).writeAsStringSync(devicesJson('wired'));
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args, env) async => FakeProcess(),
      );

      await expectLater(
        device.preflight(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('No attached iOS device with UDID OTHER-UDID'),
          ),
        ),
      );
    });
  });

  group('AndroidDevice launch preconditions', () {
    test(
      'fails loudly when aapt2 cannot read the APK, and installs nothing',
      () async {
        final calls = <String>[];
        final device = AndroidDevice(
          startForceStopProcess: exitsAtOnce,
          adbPath: 'adb',
          aapt2Path: 'aapt2',
          runProcess: (exe, args) async {
            calls.add(exe);
            return ProcessResult(0, 1, '', 'ERROR: dump failed');
          },
          startProcess: (exe, args) async {
            calls.add(exe);
            return FakeProcess();
          },
        );

        await expectLater(
          device.launch('/path/to/app.apk'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(contains('aapt2'), contains('ERROR: dump failed')),
            ),
          ),
        );
        // An app that cannot be named cannot be started, so nothing after the
        // aapt2 dump runs.
        expect(calls, ['aapt2']);
      },
    );

    test(
      'fails when the artifact is not an APK and no package was given',
      () async {
        final device = AndroidDevice(
          startForceStopProcess: exitsAtOnce,
          adbPath: 'adb',
          aapt2Path: 'aapt2',
          runProcess: (exe, args) async => ProcessResult(0, 0, '', ''),
          startProcess: (exe, args) async => FakeProcess(),
        );

        await expectLater(
          device.launch('/path/to/app_deploy.jar'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(contains('app_deploy.jar'), contains('not an APK')),
            ),
          ),
        );
      },
    );

    test(
      'reads the package and activity out of the APK when not given',
      () async {
        final calls = <(String, List<String>)>[];
        final fakeLogcat = FakeProcess();
        final device = AndroidDevice(
          startForceStopProcess: exitsAtOnce,
          adbPath: 'adb',
          aapt2Path: 'aapt2',
          runProcess: (exe, args) async {
            calls.add((exe, args));
            if (exe == 'aapt2') {
              return ProcessResult(
                0,
                0,
                "package: name='com.example.myapp' versionCode='1'\n"
                    "launchable-activity: name='com.example.myapp.Main'\n",
                '',
              );
            }
            return ProcessResult(0, 0, '', '');
          },
          startProcess: (exe, args) async => fakeLogcat,
        );

        unawaited(
          fakeLogcat.outputAttached.then((_) => fakeLogcat.complete(0)),
        );
        await device.launch('/path/to/app.apk');

        final start = calls.firstWhere(
          (c) => c.$2.contains('am') && c.$2.contains('start'),
        );
        expect(start.$2, contains('com.example.myapp/com.example.myapp.Main'));
      },
    );
  });

  group('AndroidDevice INTERNET preflight', () {
    // Realistic `dumpsys package <pkg>` excerpt. The requested-permissions
    // section is omitted entirely when the APK requests no permissions.
    String dumpsysOutput({
      required String package,
      required List<String> requestedPermissions,
    }) {
      final buf = StringBuffer()
        ..writeln('Packages:')
        ..writeln('  Package [$package] (5b7a1c2):')
        ..writeln('    userId=10190')
        ..writeln('    codePath=/data/app/~~q3zA==/$package-r7Yw==');
      if (requestedPermissions.isNotEmpty) {
        buf.writeln('    requested permissions:');
        for (final perm in requestedPermissions) {
          buf.writeln('      $perm');
        }
      }
      buf
        ..writeln('    install permissions:')
        ..writeln('      android.permission.VIBRATE: granted=true')
        ..writeln('    User 0: ceDataInode=73543 installed=true');
      return buf.toString();
    }

    AndroidDevice makeDevice({
      required List<(String, List<String>)> calls,
      required Future<ProcessResult> Function(List<String> args) onDumpsys,
      required FakeProcess logcat,
    }) {
      return AndroidDevice(
        startForceStopProcess: exitsAtOnce,
        aapt2Path: 'aapt2',
        packageName: 'com.example.app',
        adbPath: 'adb',
        runProcess: (exe, args) async {
          calls.add((exe, args));
          if (args.contains('dumpsys')) return onDumpsys(args);
          // `tcp:0` makes adb allocate the host port and print it; a launch
          // that reaches the forward at all needs one to go on with.
          if (args.contains('forward'))
            return ProcessResult(0, 0, '41234\n', '');
          return adbOk(args);
        },
        startProcess: (exe, args) async {
          calls.add((exe, args));
          return logcat;
        },
      )..expectsVmService = true;
    }

    test('proceeds when the installed package requests INTERNET', () async {
      final calls = <(String, List<String>)>[];
      final fakeLogcat = FakeProcess();
      final device = makeDevice(
        calls: calls,
        logcat: fakeLogcat,
        onDumpsys: (args) async => ProcessResult(
          0,
          0,
          dumpsysOutput(
            package: 'com.example.app',
            requestedPermissions: [
              'android.permission.INTERNET',
            ],
          ),
          '',
        ),
      );

      unawaited(
        fakeLogcat.outputAttached.then(
          (_) => fakeLogcat.emitStdout(
            '01-02 03:04:05.678 I/flutter ( 1234): The Dart VM service is '
            'listening on http://127.0.0.1:12345/abc=/',
          ),
        ),
      );

      final instance = await device.launch('/path/to/app.apk');
      expect(instance.vmServiceUri, isNotNull);

      final dumpsysCall = calls.firstWhere((c) => c.$2.contains('dumpsys'));
      expect(
        dumpsysCall.$2,
        containsAllInOrder(['shell', 'dumpsys', 'package', 'com.example.app']),
      );
      // The activity was started (check passed, launch proceeded).
      expect(
        calls.any((c) => c.$2.contains('am') && c.$2.contains('start')),
        isTrue,
      );
    });

    test('fails fast with diagnostic when INTERNET is missing', () async {
      final calls = <(String, List<String>)>[];
      final device = makeDevice(
        calls: calls,
        logcat: FakeProcess(),
        onDumpsys: (args) async => ProcessResult(
          0,
          0,
          dumpsysOutput(
            package: 'com.example.app',
            requestedPermissions: [
              'android.permission.VIBRATE',
            ],
          ),
          '',
        ),
      );

      Object? caught;
      try {
        await device.launch('/path/to/app.apk');
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<StateError>());
      final message = caught.toString();
      expect(message, contains('com.example.app'));
      expect(message, contains('/path/to/app.apk'));
      expect(message, contains('android.permission.INTERNET'));
      expect(message, contains('Dart VM service'));
      expect(message, contains('android/app/src/debug/AndroidManifest.xml'));
      expect(message, contains('debug_manifest'));

      // Failed before starting the activity or tailing logcat.
      expect(
        calls.any((c) => c.$2.contains('am') && c.$2.contains('start')),
        isFalse,
      );
      expect(calls.any((c) => c.$2.contains('logcat')), isFalse);
    });

    test('fails when the package requests no permissions at all', () async {
      final device = makeDevice(
        calls: [],
        logcat: FakeProcess(),
        onDumpsys: (args) async => ProcessResult(
          0,
          0,
          dumpsysOutput(
            package: 'com.example.app',
            requestedPermissions: const [],
          ),
          '',
        ),
      );

      expect(
        () => device.launch('/path/to/app.apk'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('android.permission.INTERNET'),
          ),
        ),
      );
    });

    test('surfaces dumpsys query failure instead of skipping', () async {
      final device = makeDevice(
        calls: [],
        logcat: FakeProcess(),
        onDumpsys: (args) async =>
            ProcessResult(0, 1, '', 'error: device offline'),
      );

      expect(
        () => device.launch('/path/to/app.apk'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('dumpsys'), contains('error: device offline')),
          ),
        ),
      );
    });

    test('surfaces missing package record as an error', () async {
      final device = makeDevice(
        calls: [],
        logcat: FakeProcess(),
        onDumpsys: (args) async =>
            ProcessResult(0, 0, 'Unable to find package: com.example.app', ''),
      );

      expect(
        () => device.launch('/path/to/app.apk'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('dumpsys'), contains('com.example.app')),
          ),
        ),
      );
    });

    test('does not run when the launch expects no VM service', () async {
      final calls = <(String, List<String>)>[];
      final fakeLogcat = FakeProcess();
      final device = AndroidDevice(
        startForceStopProcess: exitsAtOnce,
        aapt2Path: 'aapt2',
        packageName: 'com.example.app',
        adbPath: 'adb',
        runProcess: (exe, args) async {
          calls.add((exe, args));
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async => fakeLogcat,
      );
      expect(device.expectsVmService, isFalse);

      unawaited(fakeLogcat.outputAttached.then((_) => fakeLogcat.complete(0)));

      await device.launch('/path/to/app.apk');

      expect(calls.any((c) => c.$2.contains('dumpsys')), isFalse);
      expect(
        calls.any((c) => c.$2.contains('am') && c.$2.contains('start')),
        isTrue,
      );
    });
  });

  group('MacOSDevice.launch', () {
    test('extracts .app from .zip before launching', () async {
      final calls = <(String, List<String>)>[];
      final fakeAppProcess = FakeProcess();

      final device = MacOSDevice(
        runProcess: (exe, args) async {
          calls.add((exe, args));
          if (exe == 'unzip') {
            // Simulate unzip by creating an .app directory.
            final dest = args.last;
            Directory(
              '$dest/MyApp.app/Contents/MacOS',
            ).createSync(recursive: true);
            File('$dest/MyApp.app/Contents/MacOS/MyApp').writeAsStringSync('');
          }
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async {
          calls.add((exe, args));
          return fakeAppProcess;
        },
      );

      // Emit VM service URI then complete the process so launch doesn't hang.
      unawaited(
        fakeAppProcess.outputAttached.then(
          (_) => fakeAppProcess.emitStdout(
            'The Dart VM service is listening on '
            'http://127.0.0.1:12345/test=/',
          ),
        ),
      );

      await device.launch('/path/to/app.zip');

      // Should have called unzip.
      final unzipCall = calls.firstWhere((c) => c.$1 == 'unzip');
      expect(unzipCall.$2, contains('/path/to/app.zip'));

      // Should have started the extracted executable.
      final startCalls = calls
          .where((c) => c.$1 != 'unzip' && c.$1 != 'xcrun' && c.$1 != 'open')
          .toList();
      expect(startCalls, isNotEmpty);
      expect(startCalls.last.$1, contains('MyApp'));
    });

    // The extracted .app is handed to the AppInstance only by a launch that
    // succeeds; a launch that throws after the unzip must delete it itself.
    test(
      'a launch that fails after the unzip deletes the extracted app',
      () async {
        late String extracted;
        final device = MacOSDevice(
          runProcess: (exe, args) async {
            if (exe == 'unzip') {
              extracted = args.last;
              Directory(
                '$extracted/MyApp.app/Contents/MacOS',
              ).createSync(recursive: true);
            }
            return ProcessResult(0, 0, '', '');
          },
          startProcess: (exe, args) async =>
              throw const ProcessException('MyApp', [], 'Exec format error'),
        );

        await expectLater(
          device.launch('/path/to/app.zip'),
          throwsA(isA<ProcessException>()),
        );
        expect(Directory(extracted).existsSync(), isFalse);
      },
    );

    test('launches .app bundle directly', () async {
      final calls = <(String, List<String>)>[];
      final fakeAppProcess = FakeProcess();

      final device = MacOSDevice(
        runProcess: (exe, args) async => ProcessResult(0, 0, '', ''),
        startProcess: (exe, args) async {
          calls.add((exe, args));
          return fakeAppProcess;
        },
      );

      // Emit VM service URI so launch doesn't hang waiting for it.
      unawaited(
        fakeAppProcess.outputAttached.then(
          (_) => fakeAppProcess.emitStdout(
            'The Dart VM service is listening on '
            'http://127.0.0.1:12345/test=/',
          ),
        ),
      );

      await device.launch('/path/to/MyApp.app');

      expect(calls, hasLength(1));
      expect(calls[0].$1, '/path/to/MyApp.app/Contents/MacOS/MyApp');
    });

    // A process started as a bare executable is not made frontmost, and with
    // Stage Manager its window sits in the strip as a thumbnail. `open` on the
    // running bundle activates it.
    test('brings the app to the front once it is up', () async {
      final opened = <List<String>>[];
      final fakeAppProcess = FakeProcess();
      final device = MacOSDevice(
        runProcess: (exe, args) async {
          if (exe == 'open') opened.add(args);
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async => fakeAppProcess,
      );
      unawaited(
        fakeAppProcess.outputAttached.then(
          (_) => fakeAppProcess.emitStdout(
            'The Dart VM service is listening on '
            'http://127.0.0.1:12345/test=/',
          ),
        ),
      );

      await device.launch('/path/to/MyApp.app');

      expect(opened, [
        ['/path/to/MyApp.app'],
      ]);
    });

    // A MacOSDevice whose `open` and `osascript` are scripted, with the app's
    // own VM service announced so the launch completes. Returns what the
    // activation did.
    ({
      MacOSDevice device,
      List<String> osascriptArgs,
      FakeProcess osascript,
      FakeProcess app,
    })
    activationRig({
      required ProcessResult open,
      void Function(FakeProcess osascript)? script,
    }) {
      final app = FakeProcess();
      final osascript = FakeProcess();
      final osascriptArgs = <String>[];
      final device = MacOSDevice(
        runProcess: (exe, args) async =>
            exe == 'open' ? open : ProcessResult(0, 0, '', ''),
        startProcess: (exe, args) async => app,
        startActivationProcess: (exe, args) async {
          expect(exe, 'osascript');
          osascriptArgs.addAll(args);
          script?.call(osascript);
          return osascript;
        },
      );
      unawaited(
        app.outputAttached.then(
          (_) => app.emitStdout(
            'The Dart VM service is listening on '
            'http://127.0.0.1:12345/test=/',
          ),
        ),
      );
      return (
        device: device,
        osascriptArgs: osascriptArgs,
        osascript: osascript,
        app: app,
      );
    }

    // `open` needs LaunchServices to know the process: over ssh it answers
    // -600 and the app stays where it started. System Events does not need it.
    test('falls back to System Events by pid when open cannot find the '
        'app', () async {
      final rig = activationRig(
        open: ProcessResult(
          0,
          1,
          '',
          '_LSOpenURLsWithCompletionHandler() failed with error -600.',
        ),
        script: (p) => unawaited(p.outputAttached.then((_) => p.complete(0))),
      );

      await rig.device.launch('/path/to/MyApp.app');

      expect(rig.osascriptArgs.last, contains('unix id is ${rig.app.pid}'));
      expect(rig.osascriptArgs.last, contains('System Events'));
      expect(rig.osascriptArgs.last, contains('frontmost'));
    });

    test('does not touch System Events when open worked', () async {
      final rig = activationRig(open: ProcessResult(0, 0, '', ''));

      await rig.device.launch('/path/to/MyApp.app');

      expect(rig.osascriptArgs, isEmpty);
    });

    test('a failure of both does not fail the launch, and says why in '
        'fields a JSON log keeps', () async {
      final records = <LogRecord>[];
      final sub = Logger.root.onRecord.listen(records.add);
      addTearDown(sub.cancel);
      final rig = activationRig(
        open: ProcessResult(
          0,
          1,
          '',
          '_LSOpenURLsWithCompletionHandler() failed with error -600.',
        ),
        script: (p) => unawaited(
          p.outputAttached.then((_) {
            p.emitStderr('not allowed assistive access');
            p.complete(1);
          }),
        ),
      );

      final instance = await rig.device.launch('/path/to/MyApp.app');

      expect(instance.vmServiceUri, isNotNull);
      final warning = records
          .map((r) => r.object)
          .whereType<Map<Object?, Object?>>()
          .singleWhere((o) => o['message'] == 'macos_app_not_activated');
      // `text` is dropped from JSON output, so the reasons are fields.
      expect(warning['bundle'], '/path/to/MyApp.app');
      expect(warning['pid'], rig.app.pid);
      expect(warning['openExitCode'], 1);
      expect(warning['openStderr'], contains('-600'));
      expect(warning['systemEventsExitCode'], 1);
      expect(warning['systemEventsStderr'], contains('assistive access'));
    });

    // With the Automation permission undecided the AppleEvent blocks rather
    // than fails, so an unbounded wait would hang every launch.
    test('a System Events that never answers is killed after the bound, and '
        'the launch carries on', () async {
      final records = <LogRecord>[];
      final sub = Logger.root.onRecord.listen(records.add);
      addTearDown(sub.cancel);
      final rig = activationRig(
        open: ProcessResult(0, 1, '', 'error -600'),
        // Never completes.
      );
      rig.device.activationBound = const Duration(milliseconds: 100);

      final instance = await rig.device.launch('/path/to/MyApp.app');

      expect(instance.vmServiceUri, isNotNull);
      expect(rig.osascript.killed, isTrue);
      final warning = records
          .map((r) => r.object)
          .whereType<Map<Object?, Object?>>()
          .singleWhere((o) => o['message'] == 'macos_app_not_activated');
      expect(warning['systemEventsError'], contains('did not answer'));
    });
  });

  // The app's stdout and stderr keep flowing after `_discoverVmServiceUri`
  // matches the VM-service announcement, and the OS pipes stay drained.
  // Parameterised over the three desktop devices, which share the launch path.
  group('desktop app output forwarding', () {
    // A real bundle on disk: WindowsDevice copies it out of bazel-out before
    // launching, so a made-up path would fail there for reasons that have
    // nothing to do with log forwarding.
    late Directory bundleRoot;
    setUp(() {
      bundleRoot = Directory.systemTemp.createTempSync('desktop_launch_test');
      Directory(p.join(bundleRoot.path, 'MyApp.app')).createSync();
      File(
        p.join(bundleRoot.path, 'MyApp.app', 'MyApp.app.exe'),
      ).writeAsStringSync('exe');
    });
    tearDown(() => bundleRoot.deleteSync(recursive: true));

    /// Builds [device] with an injected [FakeProcess], drives it through a
    /// launch, and hands the test the live instance.
    Future<(AppInstance, FakeProcess)> launchWith(
      Device Function(ProcessStarter) build, {
      List<AppLogLine>? sink,
    }) async {
      final proc = FakeProcess();
      final device = build((exe, args) async => proc);
      final pending = device.launch(
        p.join(bundleRoot.path, 'MyApp.app'),
        onLog: sink == null ? null : sink.add,
      );
      // The launch must be listening before the announcement is emitted;
      // FakeProcess streams are live, not replayed.
      await proc.outputAttached;
      proc.emitStdout(_vmServiceLine);
      final instance = await pending;
      return (instance, proc);
    }

    final devices = <String, Device Function(ProcessStarter)>{
      'MacOSDevice': (start) => MacOSDevice(
        runProcess: (exe, args) async => ProcessResult(0, 0, '', ''),
        startProcess: start,
      ),
      'LinuxDevice': (start) => LinuxDevice(startProcess: start),
      // Staged inside `bundleRoot` so the tearDown takes it: these tests never
      // reach `stop()`, and the default staging directory lands in the system
      // temp root.
      'WindowsDevice': (start) => WindowsDevice(
        startProcess: start,
        makeStagingDir: () =>
            Directory(p.join(bundleRoot.path, 'staged')).absolute
              ..createSync(recursive: true),
      ),
    };

    devices.forEach((name, build) {
      group(name, () {
        test(
          'keeps forwarding stdout after the VM service is discovered',
          () async {
            final (instance, proc) = await launchWith(build);
            expect(
              instance.vmServiceUri,
              isNotNull,
              reason: 'discovery itself must still work',
            );

            proc.emitStdout('flutter: after discovery');
            proc.emitStdout('flutter: still going');
            await pumpEventQueue();

            final texts = instance.logs.read(0).lines.map((l) => l.text);
            expect(texts, contains('flutter: after discovery'));
            expect(texts, contains('flutter: still going'));
          },
        );

        test(
          'keeps forwarding stderr after the VM service is discovered',
          () async {
            final (instance, proc) = await launchWith(build);

            proc.emitStderr('NSLog-style native message\n');
            await pumpEventQueue();

            final line = instance.logs
                .read(0)
                .lines
                .firstWhere((l) => l.text.contains('NSLog-style'));
            expect(
              line.isError,
              isTrue,
              reason: 'stderr output must be flagged as an error channel',
            );
          },
        );

        test('delivers output emitted before discovery completes', () async {
          final sink = <AppLogLine>[];
          final proc = FakeProcess();
          final device = build((exe, args) async => proc);
          final pending = device.launch(
            p.join(bundleRoot.path, 'MyApp.app'),
            onLog: sink.add,
          );
          await proc.outputAttached;

          // A startup print that lands before the announcement — the case that
          // matters most when an app dies before ever binding a VM service.
          proc.emitStdout('flutter: early startup line');
          await pumpEventQueue();
          expect(
            sink.map((l) => l.text),
            contains('flutter: early startup line'),
            reason:
                'output must reach the sink during launch, not be held '
                'until launch() returns',
          );

          proc.emitStdout(_vmServiceLine);
          await pending;
        });

        test('onLog receives post-discovery lines exactly once', () async {
          final sink = <AppLogLine>[];
          final (_, proc) = await launchWith(build, sink: sink);

          proc.emitStdout('flutter: only once');
          await pumpEventQueue();

          expect(
            sink.where((l) => l.text == 'flutter: only once'),
            hasLength(1),
          );
        });

        test(
          'buffers output so a late reader still sees startup lines',
          () async {
            final (instance, proc) = await launchWith(build);
            proc.emitStdout('flutter: printed before anyone read');
            await pumpEventQueue();

            // A consumer attaching now (the HTTP /logs endpoint, say) still sees
            // everything from the beginning of the run.
            final texts = instance.logs.read(0).lines.map((l) => l.text);
            expect(texts, contains(_vmServiceLine));
            expect(texts, contains('flutter: printed before anyone read'));
          },
        );

        test('stop() closes the log stream', () async {
          final (instance, _) = await launchWith(build);
          final device = build((exe, args) async => FakeProcess());

          await device.stop(instance);
          expect(instance.logs.isClosed, isTrue);
        });

        test('stop() stops reading the process\'s pipes', () async {
          // An app can leave a helper behind holding the write ends of its
          // output pipes; a reader waiting for their end-of-file would keep
          // this tool's process from exiting after the run is over.
          final (instance, proc) = await launchWith(build);
          final device = build((exe, args) async => FakeProcess());

          await device.stop(instance);

          expect(proc.stdoutHasListener, isFalse);
          expect(proc.stderrHasListener, isFalse);
        });
      });
    });
  });

  // `adb logcat` carries the whole device's logging, so the dev tool filters
  // host-side (as flutter_tools does). An adb-level `flutter:I *:S` filter
  // hides Java crashes and VM messages entirely.
  group('androidLogFilter', () {
    String? filter(String line) => androidLogFilter(line);

    test('keeps Dart print output', () {
      expect(
        filter('01-02 03:04:05.678 I/flutter ( 1234): hello'),
        'I/flutter ( 1234): hello',
      );
    });

    test('strips the -v time timestamp prefix', () {
      expect(
        filter('01-02 03:04:05.678 I/flutter ( 1234): hello'),
        isNot(startsWith('01-02')),
      );
    });

    test('keeps the VM-service announcement, so discovery still works', () {
      const announcement =
          'The Dart VM service is listening on http://127.0.0.1:1234/abc=/';
      final kept = filter(
        '01-02 03:04:05.678 I/flutter ( 1234): $announcement',
      );
      expect(kept, isNotNull);
      expect(vmServiceUriPattern.hasMatch(kept!), isTrue);
    });

    test('keeps uncaught Java exceptions', () {
      expect(
        filter('01-02 03:04:05.678 E/AndroidRuntime( 1234): FATAL EXCEPTION'),
        'E/AndroidRuntime( 1234): FATAL EXCEPTION',
        reason: 'a fatal-exception line must survive the filter',
      );
    });

    test('keeps DartVM messages', () {
      expect(
        filter('01-02 03:04:05.678 I/DartVM  ( 1234): vm message'),
        isNotNull,
      );
    });

    test('keeps Java stderr', () {
      expect(
        filter('01-02 03:04:05.678 W/System.err( 1234): trace line'),
        isNotNull,
      );
    });

    test('keeps any fatal log regardless of tag', () {
      expect(
        filter('01-02 03:04:05.678 F/libc    ( 1234): Fatal signal 11'),
        isNotNull,
      );
    });

    test('drops unrelated system logging', () {
      expect(
        filter('01-02 03:04:05.678 I/WifiService( 999): scan results'),
        isNull,
      );
      expect(
        filter('01-02 03:04:05.678 D/SensorManager( 42): reading'),
        isNull,
      );
    });

    test('drops logcat boundary banners', () {
      expect(filter('--------- beginning of main'), isNull);
    });

    test('drops known-inactionable noise that would otherwise match', () {
      expect(
        filter(
          '01-02 03:04:05.678 F/SurfaceSyncer( 22636): '
          'Failed to find sync for id=9',
        ),
        isNull,
      );
    });

    test('is case-insensitive on the flutter tag', () {
      expect(filter('01-02 03:04:05.678 I/Flutter ( 1234): hi'), isNotNull);
    });

    test('keeps ActivityManager lines only when they mention the app', () {
      expect(
        filter(
          '01-02 03:04:05.678 W/ActivityManager( 42): '
          'Force stopping com.example.flutter app',
        ),
        isNotNull,
      );
      expect(
        filter(
          '01-02 03:04:05.678 W/ActivityManager( 42): '
          'Unrelated service churn',
        ),
        isNull,
      );
    });

    test('drops informational lines from allowlisted crash tags', () {
      // AndroidRuntime is only interesting at W/E/F.
      expect(
        filter('01-02 03:04:05.678 I/AndroidRuntime( 1): starting'),
        isNull,
      );
    });
  });

  group('parseLogcatLine', () {
    test('splits level, tag and message from a -v time record', () {
      final line = parseLogcatLine(
        '01-02 03:04:05.678 E/AndroidRuntime( 1234): boom',
      )!;
      expect(line.level, 'E');
      expect(line.tag, 'AndroidRuntime');
      expect(line.message, 'boom');
    });

    test('handles a space-padded pid', () {
      final line = parseLogcatLine('01-02 03:04:05.678 I/flutter (  987): hi')!;
      expect(line.tag, 'flutter');
      expect(line.message, 'hi');
    });

    test('handles a dotted tag', () {
      expect(
        parseLogcatLine('01-02 03:04:05.678 W/System.err( 1): x')!.tag,
        'System.err',
      );
    });

    test('display drops the timestamp but keeps level, tag and pid', () {
      expect(
        parseLogcatLine('01-02 03:04:05.678 I/flutter ( 1234): hello')!.display,
        'I/flutter ( 1234): hello',
      );
    });

    test('returns null for a banner', () {
      expect(parseLogcatLine('--------- beginning of main'), isNull);
    });

    test('returns null for an unparseable line', () {
      expect(parseLogcatLine('garbage'), isNull);
    });
  });

  // A simulator or Android device is shared: every Flutter app on it
  // announces its VM service on the same log. Taking the first announcement
  // attached a run to another project's app that started meanwhile.
  group('VM service discovery on a shared log', () {
    String announce(int port) =>
        'The Dart VM service is listening on http://127.0.0.1:$port/k=/';

    /// One `log stream --style ndjson` record.
    String ndjson(int pid, String message) => json.encode({
      'eventType': 'logEvent',
      'processImagePath': '/sim/Bundle/app.app/app',
      'processID': pid,
      'eventMessage': 'flutter: $message',
    });

    test('passes over another process and takes its own', () async {
      final logs = AppLogStream()
        ..add('I/flutter (  555): ${announce(1111)}')
        ..add('I/flutter (  777): ${announce(2222)}');
      final uri = await discoverOwnVmServiceUri(
        logs,
        parse: parseLogcatAnnouncement,
        isOwnProcess: (pid) async => pid == 777,
      );
      expect(uri, Uri.parse('http://127.0.0.1:2222/k=/'));
    });

    test('takes nothing when only another process announced', () async {
      final logs = AppLogStream()..add('I/flutter (  555): ${announce(1111)}');
      final pending = discoverOwnVmServiceUri(
        logs,
        parse: parseLogcatAnnouncement,
        isOwnProcess: (pid) async => pid == 777,
      );
      await logs.close();
      expect(await pending, isNull);
    });

    test(
      'keeps to the order lines arrived in, however long a check takes',
      () async {
        final first = Completer<bool>();
        final logs = AppLogStream()
          ..add(ndjson(1, announce(1111)))
          ..add(ndjson(2, announce(2222)));
        final pending = discoverOwnVmServiceUri(
          logs,
          parse: parseUnifiedLoggingAnnouncement,
          isOwnProcess: (pid) => pid == 1 ? first.future : Future.value(true),
        );
        await Future<void>.delayed(Duration.zero);
        first.complete(true);
        expect(await pending, Uri.parse('http://127.0.0.1:1111/k=/'));
      },
    );

    test('a failed check fails discovery', () async {
      final logs = AppLogStream()..add('I/flutter (  555): ${announce(1111)}');
      await expectLater(
        discoverOwnVmServiceUri(
          logs,
          parse: parseLogcatAnnouncement,
          isOwnProcess: (_) async => throw StateError('adb gone'),
        ),
        throwsStateError,
      );
    });

    test('parseUnifiedLoggingAnnouncement reads the pid and URI', () {
      expect(
        parseUnifiedLoggingAnnouncement(ndjson(23143, announce(52226))),
        (pid: 23143, uri: Uri.parse('http://127.0.0.1:52226/k=/')),
      );
    });

    test('parseUnifiedLoggingAnnouncement skips the banner quoting its '
        'filter', () {
      expect(
        parseUnifiedLoggingAnnouncement(
          'Filtering the log data using "composedMessage CONTAINS '
          '"Dart VM service""',
        ),
        isNull,
      );
      expect(parseUnifiedLoggingAnnouncement(ndjson(1, 'hello')), isNull);
    });

    test('parseLogcatAnnouncement reads the pid and URI', () {
      expect(
        parseLogcatAnnouncement('I/flutter ( 4321): ${announce(40000)}'),
        (pid: 4321, uri: Uri.parse('http://127.0.0.1:40000/k=/')),
      );
      expect(parseLogcatAnnouncement('I/flutter ( 4321): hello'), isNull);
    });

    test('simctlLaunchedPid reads the pid simctl launch prints', () {
      expect(
        simctlLaunchedPid('com.example.app: 21879\n', 'com.example.app'),
        21879,
      );
      expect(
        simctlLaunchedPid('com.example.app.second: 5\n', 'com.example.app'),
        isNull,
      );
      expect(simctlLaunchedPid('', 'com.example.app'), isNull);
    });

    test('an iOS Simulator launch attaches to the app it launched', () async {
      final sim = FakeSimulatorLog();
      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: sim.run(
          (exe, args) async => args.contains('launch')
              ? ProcessResult(0, 0, 'com.example.test: 1234\n', '')
              : ProcessResult(0, 0, '', ''),
        ),
        startProcess: sim.start((exe, args) async {
          final p = FakeProcess();
          if (args.contains('ndjson')) {
            unawaited(
              p.outputAttached.then((_) {
                p.emitStdout(ndjson(999, announce(1111)));
                p.emitStdout(ndjson(1234, announce(2222)));
              }),
            );
          }
          return p;
        }),
      );
      final instance = await device.launch('/path/to/MyApp.app');
      expect(instance.vmServiceUri, Uri.parse('http://127.0.0.1:2222/k=/'));
    });

    // The race this closes: `log stream` delivers only what is logged after
    // it attaches, and its banner is no proof that it has. Here the discovery
    // stream attaches only after the launch's first marker: an app launched
    // then announces its VM service into nothing, and the run waits for good
    // on an app that is up.
    test('an iOS Simulator app is launched only once every log stream has '
        'shown it is listening', () async {
      final streams = <FakeProcess>[];
      var markersLogged = 0;
      // A stream sees what is logged once it is attached, and nothing before.
      bool attached(int stream) => stream > 0 || markersLogged >= 2;
      void log(String line) {
        for (final (i, s) in streams.indexed) {
          if (attached(i)) s.emitStdout(line);
        }
      }

      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: (exe, args) async {
          if (args.contains('syslog')) {
            markersLogged++;
            // In both styles: the output stream is `--style json`.
            log(json.encode({'eventMessage': args.last}));
            log('  "eventMessage" : ${json.encode(args.last)},');
          } else if (args.contains('launch')) {
            log(ndjson(1234, announce(2222)));
            return ProcessResult(0, 0, 'com.example.test: 1234\n', '');
          }
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async {
          final p = FakeProcess();
          streams.add(p);
          Timer.run(() => p.emitStdout('Filtering the log data using "..."'));
          return p;
        },
      );

      final instance = await device.launch('/path/to/MyApp.app');

      expect(markersLogged, greaterThanOrEqualTo(2));
      expect(instance.vmServiceUri, Uri.parse('http://127.0.0.1:2222/k=/'));
    });

    test('an iOS Simulator launch that reports no pid fails', () async {
      final sim = FakeSimulatorLog();
      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: sim.run((exe, args) async => ProcessResult(0, 0, '', '')),
        startProcess: sim.start((exe, args) async => FakeProcess()),
      );
      await expectLater(
        device.launch('/path/to/MyApp.app'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('did not say which process it started'),
          ),
        ),
      );
    });

    test('an Android launch attaches to its own package', () async {
      final logcat = FakeProcess();
      final forwards = <String>[];
      final device = AndroidDevice(
        startForceStopProcess: exitsAtOnce,
        aapt2Path: 'aapt2',
        packageName: 'com.example.app',
        adbPath: 'adb',
        runProcess: (exe, args) async {
          if (args.contains('pidof')) return ProcessResult(0, 0, '777\n', '');
          if (args.contains('forward')) {
            forwards.add(args.last);
            return ProcessResult(0, 0, '40001\n', '');
          }
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async => logcat,
      );
      unawaited(
        logcat.outputAttached.then((_) {
          logcat.emitStdout(
            '01-02 03:04:05.678 I/flutter (  555): ${announce(1111)}',
          );
          logcat.emitStdout(
            '01-02 03:04:05.679 I/flutter (  777): ${announce(2222)}',
          );
        }),
      );
      final instance = await device.launch('/path/to/app.apk');
      expect(forwards, ['tcp:2222']);
      expect(instance.vmServiceUri, Uri.parse('http://127.0.0.1:40001/k=/'));
    });

    // `-T 1` starts at whatever is last in the log when logcat gets round to
    // reading it, and the app is launched alongside: on a busy host the app
    // can announce its VM service first, and the run then waits for good. The
    // log is read instead from the last record before the launch, which the
    // device keeps, so nothing logged after it can be missed.
    test(
      'an Android launch reads the log from before the app started',
      () async {
        final calls = <List<String>>[];
        final device = AndroidDevice(
          startForceStopProcess: exitsAtOnce,
          aapt2Path: 'aapt2',
          packageName: 'com.example.app',
          adbPath: 'adb',
          runProcess: (exe, args) async {
            calls.add(args);
            if (args.contains('logcat') && args.contains('-t')) {
              return ProcessResult(
                0,
                0,
                '--------- beginning of main\n'
                    '11-06 15:31:53.862 I/adbd    ( 1418): adbd service '
                    'requested\n',
                '',
              );
            }
            return adbOk(args);
          },
          startProcess: (exe, args) async {
            calls.add(args);
            return FakeProcess()..complete(0);
          },
        );
        await device.launch('/path/to/app.apk');

        final last = calls.indexWhere((c) => c.contains('-t'));
        final follow = calls.indexWhere(
          (c) => c.contains('logcat') && !c.contains('-t'),
        );
        final start = calls.indexWhere((c) => c.contains('start'));
        expect(last, isNonNegative);
        expect(last, lessThan(follow));
        expect(follow, lessThan(start));
        expect(calls[follow], containsAllInOrder(['-T', '11-06 15:31:53.862']));
      },
    );

    test('an Android launch on an empty log reads all of it', () async {
      final calls = <List<String>>[];
      final device = AndroidDevice(
        startForceStopProcess: exitsAtOnce,
        aapt2Path: 'aapt2',
        packageName: 'com.example.app',
        adbPath: 'adb',
        runProcess: (exe, args) async {
          calls.add(args);
          return adbOk(args);
        },
        startProcess: (exe, args) async {
          calls.add(args);
          return FakeProcess()..complete(0);
        },
      );
      await device.launch('/path/to/app.apk');
      final follow = calls.firstWhere(
        (c) => c.contains('logcat') && !c.contains('-t'),
      );
      expect(follow, isNot(contains('-T')));
    });

    test(
      'an Android launch that cannot read the log fails, saying so',
      () async {
        final device = AndroidDevice(
          startForceStopProcess: exitsAtOnce,
          aapt2Path: 'aapt2',
          packageName: 'com.example.app',
          adbPath: 'adb',
          runProcess: (exe, args) async {
            if (args.contains('logcat')) {
              return ProcessResult(0, 1, '', 'error: closed');
            }
            return adbOk(args);
          },
          startProcess: (exe, args) async => FakeProcess(),
        );
        await expectLater(
          device.launch('/path/to/app.apk'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(contains('logcat'), contains('error: closed')),
            ),
          ),
        );
      },
    );
  });

  group('iOS Simulator log capture', () {
    test('the output predicate scopes to the app process', () {
      final predicate = iosSimulatorLogPredicate('MyApp');
      expect(predicate, contains('processImagePath ENDSWITH "MyApp"'));
      expect(predicate, contains('eventType = logEvent'));
    });

    test('the output predicate filters known noise', () {
      final predicate = iosSimulatorLogPredicate('MyApp');
      expect(
        predicate,
        contains('NOT(eventMessage BEGINSWITH "assertion failed: ")'),
      );
      expect(predicate, contains('libxpc.dylib'));
    });

    test('the output predicate admits Flutter engine messages', () {
      expect(
        iosSimulatorLogPredicate('MyApp'),
        contains('senderImagePath ENDSWITH "/Flutter"'),
      );
    });

    test('parseUnifiedLoggingLine extracts the message', () {
      expect(
        parseUnifiedLoggingLine('  "eventMessage" : "flutter: 21",'),
        'flutter: 21',
      );
    });

    test('parseUnifiedLoggingLine unescapes JSON string content', () {
      expect(
        parseUnifiedLoggingLine(r'  "eventMessage" : "a \"quoted\" word",'),
        'a "quoted" word',
      );
    });

    test('parseUnifiedLoggingLine ignores other JSON fields', () {
      expect(
        parseUnifiedLoggingLine('  "processImagePath" : "/x/MyApp",'),
        isNull,
      );
      expect(parseUnifiedLoggingLine('{'), isNull);
    });

    test('parseUnifiedLoggingLine survives malformed JSON', () {
      expect(
        parseUnifiedLoggingLine('  "eventMessage" : "unterminated'),
        isNull,
      );
    });

    test('launch spawns separate log streams for app output and for how '
        'the app ends', () async {
      final started = <(String, List<String>)>[];
      final sim = FakeSimulatorLog(endStreamsAtLaunch: true);
      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: sim.run((exe, args) async => simctlOk(args)),
        startProcess: sim.start((exe, args) async {
          started.add((exe, args));
          return FakeProcess();
        }),
      );

      await device.launch('/path/to/MyApp.app');

      final logStreams = started.where((c) => c.$2.contains('stream')).toList();
      expect(
        logStreams,
        hasLength(3),
        reason:
            'one narrow stream for discovery, one for app output, one for '
            "the simulator's record of the app's end",
      );

      // Discovery keeps its content match; output gets the process-scoped
      // predicate. Merging them would make discovery depend on the output
      // predicate's NOT(...) clauses.
      expect(
        logStreams.any((c) => c.$2.any((a) => a.contains('Dart VM service'))),
        isTrue,
      );
      expect(
        logStreams.any((c) => c.$2.any((a) => a.contains('processImagePath'))),
        isTrue,
      );
      expect(
        logStreams.any(
          (c) => c.$2.any(
            (a) =>
                a.contains('termination reported by launchd') &&
                a.contains('com.example.test'),
          ),
        ),
        isTrue,
      );
    });

    test('--start-paused is passed to the app, after the bundle id', () async {
      // simctl treats everything after the bundle id as the app's argv, which
      // is where the iOS embedder reads engine switches from.
      final runs = <(String, List<String>)>[];
      // Ending the discovery stream is what lets launch return.
      final sim = FakeSimulatorLog(endStreamsAtLaunch: true);
      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: sim.run((exe, args) async {
          runs.add((exe, args));
          return simctlOk(args);
        }),
        startProcess: sim.start((exe, args) async => FakeProcess()),
      )..startPaused = true;

      await device.launch('/path/to/MyApp.app');

      final launchCall = runs.firstWhere(
        (c) => c.$2.contains('launch') && c.$2.contains('simctl'),
      );
      expect(launchCall.$2.last, '--start-paused');
      expect(launchCall.$2[launchCall.$2.length - 2], 'com.example.test');
    });

    test('the app-output stream is killed on stop', () async {
      final spawned = <FakeProcess>[];
      // The launch spawns the discovery stream first and the app-output
      // stream second, and only subscribes to discovery after the simctl
      // launch call — so the test has to wait for both to exist *and* both to
      // be listening before it emits anything into these broadcast streams.
      final bothSpawned = Completer<void>();
      final sim = FakeSimulatorLog();
      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: sim.run((exe, args) async => simctlOk(args)),
        startProcess: sim.start((exe, args) async {
          final p = FakeProcess();
          spawned.add(p);
          if (spawned.length == 2 && !bothSpawned.isCompleted) {
            bothSpawned.complete();
          }
          return p;
        }),
      );

      final pending = device.launch('/path/to/MyApp.app');
      await bothSpawned.future;
      await Future.wait([for (final p in spawned) p.outputAttached]);
      // Announce on the discovery stream, as the launched app, so launch
      // returns.
      spawned.first.emitStdout(
        json.encode({'processID': 1234, 'eventMessage': _vmServiceLine}),
      );
      final instance = await pending;

      expect(
        instance.auxiliaryProcesses,
        isNotEmpty,
        reason: 'the second stream must be tracked so stop() can kill it',
      );

      await device.stop(instance);
      for (final aux in instance.auxiliaryProcesses) {
        await expectLater(aux.exitCode, completes);
      }
    });
  });

  group('MacOSDevice.screenshot', () {
    test(
      'throws structured error when bundled helper binary is missing',
      () async {
        // The macOS native screenshot path invokes a bundled Swift binary via
        // runfiles (analogous to WindowsDevice). Under unit-test runfiles the
        // binary isn't reachable, so the observable contract is the error that
        // points at the build target.
        final device = MacOSDevice();
        Object? caught;
        try {
          await device.screenshot(
            AppInstance(process: FakeProcess()),
            '/tmp/macos.png',
          );
        } catch (e) {
          caught = e;
        }
        expect(caught, isA<StateError>());
        expect(
          caught.toString(),
          contains('bazel build //tools/dev_tool:flutter_bazel'),
        );
      },
    );
  });

  group('runProcessBounded', () {
    test(
      'kills a helper that never answers, and quotes what it did say',
      () async {
        // The capture runs inside an HTTP handler, so a helper that never exits
        // is a request held open forever — the caller learns nothing at all,
        // which is worse than any error it could have been told. `Process.run`
        // could not express this: no bound, and no handle to kill through.
        final helper = FakeProcess();
        final started = <(String, List<String>, Map<String, String>)>[];

        final pending = runProcessBounded(
          (exe, args, env) async {
            started.add((exe, args, env));
            return helper;
          },
          '/bundled/screenshot',
          const ['--pid', '4242'],
          environment: const {'RUNFILES_MANIFEST_FILE': '/manifest'},
          bound: const Duration(milliseconds: 50),
          what: 'The bundled macOS screenshot helper',
        );

        // Said before the wedge, and only reachable because both streams are
        // drained from the moment the process exists: a read started after the
        // deadline would have lost this.
        await helper.outputAttached;
        helper.emitStderr('enumerating windows');

        await expectLater(
          pending,
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('The bundled macOS screenshot helper'),
                contains('did not answer within 50ms and was killed'),
                contains('enumerating windows'),
              ),
            ),
          ),
        );
        expect(helper.signals, [ProcessSignal.sigkill]);
        expect(started.single.$1, '/bundled/screenshot');
        expect(started.single.$3['RUNFILES_MANIFEST_FILE'], '/manifest');
      },
    );

    test('says so plainly when the helper wedged without a word', () async {
      final helper = FakeProcess();

      await expectLater(
        runProcessBounded(
          (exe, args, env) async => helper,
          '/bundled/screenshot',
          const [],
          environment: const {},
          bound: const Duration(milliseconds: 50),
          what: 'The bundled macOS screenshot helper',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('on stderr: (nothing)'),
          ),
        ),
      );
    });

    test('a helper that answers in time is reported whole', () async {
      final helper = FakeProcess();

      final pending = runProcessBounded(
        (exe, args, env) async => helper,
        '/bundled/screenshot',
        const [],
        environment: const {},
        bound: const Duration(seconds: 30),
        what: 'The bundled macOS screenshot helper',
      );

      await helper.outputAttached;
      helper.emitStdout('wrote /tmp/shot.png');
      helper.emitStderr('skipped one zero-sized window');
      helper.complete(0);

      final result = await pending;
      expect(result.exitCode, 0);
      expect(result.stdout, contains('wrote /tmp/shot.png'));
      expect(result.stderr, contains('skipped one zero-sized window'));
      expect(helper.killed, isFalse);
    });
  });

  group('LinuxDevice.screenshot', () {
    test('captures the X display itself when no vmClient', () async {
      final calls = <(String, Map<String, String>)>[];

      final device = LinuxDevice(
        captureX11: (outputPath, {required environment}) async {
          calls.add((outputPath, environment));
        },
      )..environment = {'DISPLAY': ':42'};

      final instance = AppInstance(process: FakeProcess());
      await device.screenshot(instance, '/tmp/linux.png');

      expect(calls, hasLength(1));
      expect(calls[0].$1, '/tmp/linux.png');
      expect(calls[0].$2, {'DISPLAY': ':42'});
    });

    test(
      'captures the display of this process without an environment',
      () async {
        Map<String, String>? seen;
        final device = LinuxDevice(
          captureX11: (outputPath, {required environment}) async {
            seen = environment;
          },
        );

        await device.screenshot(
          AppInstance(process: FakeProcess()),
          '/tmp/l.png',
        );

        expect(seen, Platform.environment);
      },
    );

    test('a capture that fails is the error of the screenshot', () async {
      final device = LinuxDevice(
        captureX11: (outputPath, {required environment}) async =>
            throw StateError('DISPLAY is not set'),
      );

      await expectLater(
        device.screenshot(AppInstance(process: FakeProcess()), '/tmp/l.png'),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('LinuxDevice.launch', () {
    // A test that Bazel ends while the app is starting runs its teardown before
    // `launch` has returned an instance, so the device hears of the app only
    // through [Device.abandonLaunch]. The app is a window on a display: it may
    // not outlive the run.
    test('abandoning a launch in flight stops the app', () async {
      final started = Completer<FakeProcess>();
      final device = LinuxDevice(
        // The app starts and never announces a VM service.
        startProcess: (exe, args) async {
          final proc = FakeProcess();
          started.complete(proc);
          return proc;
        },
      );
      unawaited(device.launch('/bundle/app').then((_) {}, onError: (_) {}));
      final app = await started.future;
      await app.outputAttached;

      await device.abandonLaunch();

      expect(app.killed, isTrue);
    });

    test('abandoning a launch that returned leaves the app to stop', () async {
      final app = FakeProcess();
      final device = LinuxDevice(startProcess: (exe, args) async => app);
      final launch = device.launch('/bundle/app');
      await app.outputAttached;
      app.emitStdout(_vmServiceLine);
      await launch;

      await device.abandonLaunch();

      expect(app.killed, isFalse);
    });

    test('an app given an environment runs in it, with the engine switches '
        'of the launch, and nothing else of the host\'s', () {
      final device = LinuxDevice()
        ..environment = const {'DISPLAY': ':4', 'HOME': '/h'}
        ..startPaused = true;

      final env = device.launchEnvironment;

      expect(env['DISPLAY'], ':4');
      expect(env['HOME'], '/h');
      expect(env['FLUTTER_VM_SERVICE_PORT'], '0');
      expect(env['FLUTTER_ENGINE_SWITCH_1'], 'start-paused=true');
      expect(env.keys, isNot(contains('PATH')));
    });
  });

  group('WindowsDevice.launch staging', () {
    // Windows keeps an exclusive lock on a running executable image, so an app
    // launched straight out of `bazel-out` makes the next bundling action fail
    // with "failed to delete output files ... app.exe (Permission denied)" —
    // which is every `app.restart` that follows a real source edit. The launch
    // must therefore come from a copy.
    late Directory sandbox;
    late Directory bundle;

    setUp(() {
      sandbox = Directory.systemTemp.createTempSync('win_stage_test');
      bundle = Directory(p.join(sandbox.path, 'bazel-out', 'app'))
        ..createSync(recursive: true);
      File(p.join(bundle.path, 'app.exe')).writeAsStringSync('exe');
      Directory(
        p.join(bundle.path, 'data', 'flutter_assets'),
      ).createSync(recursive: true);
      File(
        p.join(bundle.path, 'data', 'flutter_assets', 'AssetManifest.json'),
      ).writeAsStringSync('{}');
    });

    tearDown(() => sandbox.deleteSync(recursive: true));

    /// A device whose staging directories are numbered, so a relaunch is
    /// distinguishable from a reuse.
    ({WindowsDevice device, List<String> launched, List<FakeProcess> procs})
    makeDevice() {
      final launched = <String>[];
      final procs = <FakeProcess>[];
      var n = 0;
      final device = WindowsDevice(
        makeStagingDir: () =>
            Directory(p.join(sandbox.path, 'staged${n++}'))..createSync(),
        startProcess: (exe, args) async {
          launched.add(exe);
          final proc = FakeProcess();
          procs.add(proc);
          Future<void>(() => proc.emitStdout(_vmServiceLine));
          return proc;
        },
      );
      return (device: device, launched: launched, procs: procs);
    }

    test('launches a copy, never the path bazel will rewrite', () async {
      final h = makeDevice();
      await h.device.launch(bundle.path);

      expect(
        p.isWithin(bundle.path, h.launched.single),
        isFalse,
        reason: 'must not run from bazel-out: ${h.launched.single}',
      );
      expect(File(h.launched.single).existsSync(), isTrue);
    });

    test('copies the whole bundle, not just the executable', () async {
      // The runner resolves `data/flutter_assets` relative to its own
      // executable, so a lone .exe copy renders nothing.
      final h = makeDevice();
      await h.device.launch(bundle.path);

      final asset = p.join(
        p.dirname(h.launched.single),
        'data',
        'flutter_assets',
        'AssetManifest.json',
      );
      expect(File(asset).existsSync(), isTrue);
    });

    test('a relaunch stages afresh and drops the previous copy', () async {
      // `app.restart` relaunches when native libraries changed. Reusing the
      // old directory would run the previous build's assets.
      final h = makeDevice();
      await h.device.launch(bundle.path);
      final first = h.launched.single;

      File(
        p.join(bundle.path, 'data', 'flutter_assets', 'AssetManifest.json'),
      ).writeAsStringSync('{"new":true}');
      await h.device.launch(bundle.path);
      final second = h.launched.last;

      expect(second, isNot(first));
      expect(
        File(first).existsSync(),
        isFalse,
        reason: 'the superseded copy must not be left behind',
      );
      final asset = p.join(
        p.dirname(second),
        'data',
        'flutter_assets',
        'AssetManifest.json',
      );
      expect(File(asset).readAsStringSync(), '{"new":true}');
    });

    test('stop removes the copy it made', () async {
      final h = makeDevice();
      await h.device.launch(bundle.path);
      final launched = h.launched.single;

      h.procs.single.complete(0);
      await h.device.stop(AppInstance(process: h.procs.single));

      expect(File(launched).existsSync(), isFalse);
    });

    // A test that Bazel ends while the app is starting runs its teardown before
    // `launch` has returned an instance, so the device hears of the app only
    // through [Device.abandonLaunch]. The app is a window on the desktop, and
    // its copy of the bundle is held open by it: neither may outlive the run.
    test(
      'abandoning a launch in flight stops the app and removes its copy',
      () async {
        final started = Completer<FakeProcess>();
        final launched = <String>[];
        final device = WindowsDevice(
          makeStagingDir: () =>
              Directory(p.join(sandbox.path, 'staged'))..createSync(),
          // The app starts and never announces a VM service.
          startProcess: (exe, args) async {
            launched.add(exe);
            final proc = FakeProcess();
            started.complete(proc);
            return proc;
          },
        );
        unawaited(device.launch(bundle.path));
        final app = await started.future;
        await app.outputAttached;

        await device.abandonLaunch();

        expect(app.killed, isTrue);
        expect(File(launched.single).existsSync(), isFalse);
      },
    );

    test('abandoning a launch that returned leaves the app to stop', () async {
      final h = makeDevice();
      await h.device.launch(bundle.path);

      await h.device.abandonLaunch();

      expect(h.procs.single.killed, isFalse);
      expect(File(h.launched.single).existsSync(), isTrue);
    });
  });

  group('WindowsDevice.screenshot', () {
    test(
      'throws structured error when bundled dxcam binary is missing',
      () async {
        // The implementation uses `resolveRunfileWithManifest` to locate
        // the bundled dxcam `py_binary` and shells to it directly via
        // `Process.run`; it doesn't go through the injected `runProcess`
        // hook. Under unit-test runfiles the tool isn't reachable, so the
        // observable contract is the actionable error that points at the
        // build target.
        final device = WindowsDevice();
        Object? caught;
        try {
          await device.screenshot(
            AppInstance(process: FakeProcess()),
            r'C:\tmp\win.png',
          );
        } catch (e) {
          caught = e;
        }
        expect(caught, isA<StateError>());
        expect(
          caught.toString(),
          contains('bazel build //tools/dev_tool:flutter_bazel'),
        );
      },
    );
  });

  group('AndroidDevice.screenshot', () {
    test('uses adb screencap when no vmClient', () async {
      final calls = <(String, List<String>)>[];

      final device = AndroidDevice(
        startForceStopProcess: exitsAtOnce,
        aapt2Path: 'aapt2',
        deviceId: '58051JEBF01271',
        adbPath: 'adb',
        startScreenshotProcess: (exe, args) async {
          calls.add((exe, args));
          final adb = FakeProcess();
          // Answer only once the bounded runner is reading both channels;
          // output emitted before that is dropped by a broadcast controller.
          unawaited(adb.outputAttached.then((_) => adb.complete(0)));
          return adb;
        },
      );

      final instance = AppInstance(process: FakeProcess());
      await device.screenshot(instance, '/tmp/android.png');

      final adbCalls = calls.where((c) => c.$1 == 'adb').toList();
      expect(adbCalls.length, 3); // screencap, pull, rm
    });

    // The capture's only caller is an HTTP handler with no bound of its own
    // (`http_control_channel.dart`, `_handleNativeScreenshot`), so an `adb`
    // that never returns is a request held open forever — the caller is left
    // with nothing to act on, which is worse than any error it could be told.
    // `Process.run` cannot express the bound: no deadline, and no handle to
    // kill through.
    test(
      'kills an adb that never answers rather than holding the request',
      () async {
        final wedged = FakeProcess();
        final device = AndroidDevice(
          startForceStopProcess: exitsAtOnce,
          aapt2Path: 'aapt2',
          deviceId: '58051JEBF01271',
          adbPath: 'adb',
          startScreenshotProcess: (exe, args) async => wedged,
        )..screenshotBound = const Duration(milliseconds: 50);

        await expectLater(
          device.screenshot(AppInstance(process: FakeProcess()), '/tmp/a.png'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(contains('adb screencap'), contains('was killed')),
            ),
          ),
        );
        expect(wedged.signals, [ProcessSignal.sigkill]);
      },
    );

    /// On an emulator `adb screencap` can report success and return nothing,
    /// while the emulator console returns the real image.
    ///
    /// How much of the screen goes blank varies with the AVD and the GPU mode
    /// and is deliberately not relied on — see `AndroidDevice.screenshot`. The
    /// invariant these tests pin is only that an emulator is captured through
    /// its console and a physical device through `screencap`, decided by which
    /// kind of device it is rather than by looking at the pixels.
    group('on an emulator', () {
      late Directory captured;

      setUp(() {
        captured = Directory.systemTemp.createTempSync('emu_shot_test');
      });
      tearDown(() => captured.deleteSync(recursive: true));

      /// An emulator whose console capture writes [files] into the directory
      /// it is handed — the emulator names the file itself, so a caller can
      /// only look for what turned up.
      AndroidDevice emulator(List<String> files) => AndroidDevice(
        startForceStopProcess: exitsAtOnce,
        aapt2Path: 'aapt2',
        deviceId: 'emulator-5554',
        adbPath: 'adb',
        startScreenshotProcess: (exe, args) async {
          final dir = args.last;
          for (final f in files) {
            File(p.join(dir, f)).writeAsStringSync('png-bytes-$f');
          }
          final adb = FakeProcess();
          // `adb emu` answers OK even when it wrote nothing at all, so the
          // exit code says nothing; every case here completes 0 on purpose.
          unawaited(adb.outputAttached.then((_) => adb.complete(0)));
          return adb;
        },
      );

      test('captures through the emulator console, not screencap', () async {
        final out = p.join(captured.path, 'shot.png');
        await emulator(['Screenshot_1788460401.png']).screenshot(
          AppInstance(process: FakeProcess()),
          out,
        );
        expect(File(out).readAsStringSync(), contains('png-bytes'));
      });

      test('passes the console command a directory of its own', () async {
        final calls = <List<String>>[];
        final device = AndroidDevice(
          startForceStopProcess: exitsAtOnce,
          aapt2Path: 'aapt2',
          deviceId: 'emulator-5554',
          adbPath: 'adb',
          startScreenshotProcess: (exe, args) async {
            calls.add(args);
            File(p.join(args.last, 'Screenshot_1.png')).writeAsStringSync('p');
            final adb = FakeProcess();
            unawaited(adb.outputAttached.then((_) => adb.complete(0)));
            return adb;
          },
        );
        await device.screenshot(
          AppInstance(process: FakeProcess()),
          p.join(captured.path, 'shot.png'),
        );
        expect(calls.single.take(5), [
          '-s',
          'emulator-5554',
          'emu',
          'screenrecord',
          'screenshot',
        ]);
        // A fresh directory per capture is what makes "exactly one PNG"
        // mean "the one this call produced" rather than "whatever is lying
        // around from the last one".
        expect(Directory(calls.single.last).existsSync(), isFalse);
      });

      // `adb emu screenrecord screenshot /nonexistent/dir` prints OK and
      // exits 0, so neither the exit code nor the console's own word can be
      // trusted. What turned up on disk is the only evidence the capture
      // happened.
      test('fails when the console wrote no PNG despite saying OK', () async {
        await expectLater(
          emulator([]).screenshot(
            AppInstance(process: FakeProcess()),
            p.join(captured.path, 'shot.png'),
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(contains('no PNG'), contains('emulator-5554')),
            ),
          ),
        );
      });

      test('fails rather than guess between several PNGs', () async {
        await expectLater(
          emulator(['Screenshot_1.png', 'Screenshot_2.png']).screenshot(
            AppInstance(process: FakeProcess()),
            p.join(captured.path, 'shot.png'),
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('2 PNGs'),
            ),
          ),
        );
      });
    });

    test('the bound covers the whole capture, not each adb call', () async {
      // A capture is three adb calls. One deadline across all three is what
      // bounds what the caller actually waits for; a bound per call would let
      // the endpoint hold its request for three times the number written down.
      const budget = Duration(milliseconds: 500);
      final started = <FakeProcess>[];
      final device = AndroidDevice(
        startForceStopProcess: exitsAtOnce,
        aapt2Path: 'aapt2',
        deviceId: '58051JEBF01271',
        adbPath: 'adb',
        startScreenshotProcess: (exe, args) async {
          final adb = FakeProcess();
          started.add(adb);
          // The first two answer, but slowly enough to eat most of the
          // budget; only the third wedges.
          if (started.length < 3) {
            unawaited(
              adb.outputAttached
                  .then(
                    (_) =>
                        Future<void>.delayed(const Duration(milliseconds: 150)),
                  )
                  .then((_) => adb.complete(0)),
            );
          }
          return adb;
        },
      )..screenshotBound = budget;

      await expectLater(
        device.screenshot(AppInstance(process: FakeProcess()), '/tmp/a.png'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('adb rm of the captured file'),
              // The number the third call was killed on is what separates the
              // two designs: with one deadline it is whatever the first two
              // left, and it can never be the whole budget.
              isNot(contains('within ${budget.inMilliseconds}ms')),
            ),
          ),
        ),
      );
      expect(started, hasLength(3));
      expect(started.last.signals, [ProcessSignal.sigkill]);
    });
  });

  group('IOSSimulatorDevice.screenshot', () {
    final instance = AppInstance(process: FakeProcess());

    test('captures the one screen with devicectl', () async {
      final devicectl = fakeDevicectl(
        () => [display('LCD', uniqueId: 'SCREEN-1', primary: true)],
      );
      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        runProcess: devicectl.run,
      );

      await device.screenshot(instance, '/tmp/ios.png');

      expect(devicectl.calls, hasLength(2));
      expect(devicectl.calls[0].take(5), [
        'xcrun',
        'devicectl',
        'device',
        'info',
        'displays',
      ]);
      expect(devicectl.calls[0], containsAllInOrder(['--device', 'TEST-UDID']));
      expect(devicectl.calls[1], [
        'xcrun',
        'devicectl',
        'device',
        'capture',
        'screenshot',
        '--device',
        'TEST-UDID',
        '--destination',
        '/tmp/ios.png',
        '--display-unique-id',
        'SCREEN-1',
        '--timeout',
        '30',
        '--quiet',
      ]);
    });

    test('on a two-screen simulator captures the active screen', () async {
      var open = false;
      final devicectl = fakeDevicectl(
        () => [
          display(
            'LCD',
            uniqueId: 'INNER',
            displayId: 1,
            active: !open,
            primary: true,
          ),
          display('LCD-1', uniqueId: 'OUTER', displayId: 3, active: open),
        ],
      );
      final device = IOSSimulatorDevice(
        udid: 'DUO',
        runProcess: devicectl.run,
      );

      await device.screenshot(instance, '/tmp/folded.png');
      open = true;
      await device.screenshot(instance, '/tmp/open.png');

      // Looked up for each screenshot: the posture changed between them.
      expect(
        devicectl.calls
            .where((c) => c.contains('capture'))
            .map((c) => c[c.indexOf('--display-unique-id') + 1]),
        ['INNER', 'OUTER'],
      );
    });

    test('--screen names a screen, by unique id, displayId or name', () async {
      final devicectl = fakeDevicectl(
        () => [
          display('LCD', uniqueId: 'INNER', displayId: 1, active: true),
          display('LCD-1', uniqueId: 'OUTER', displayId: 3, active: false),
        ],
      );
      final device = IOSSimulatorDevice(
        udid: 'DUO',
        runProcess: devicectl.run,
      );

      for (final name in ['OUTER', 'displayId:3', 'LCD-1']) {
        await device.screenshot(instance, '/tmp/x.png', screen: name);
      }

      expect(
        devicectl.calls
            .where((c) => c.contains('capture'))
            .map((c) => c[c.indexOf('--display-unique-id') + 1]),
        ['OUTER', 'OUTER', 'OUTER'],
      );
    });

    // Time in the tests below is the test's: `fakeAsync` moves it only when
    // `elapse` is called, so what has finished by an exact moment, which step
    // was waiting, how many times the device was asked and how many seconds
    // devicectl was handed are all plain assertions. The listing's own file
    // calls are synchronous so it can run here.
    group('under fake time', () {
      /// A devicectl that takes [list] to list the screens and [capture] to
      /// capture, and records the `--timeout` it was handed by each.
      ({ProcessRunSync run, List<int> listTimeouts, List<int> captureTimeouts})
      slow({
        Duration list = Duration.zero,
        Duration capture = Duration.zero,
        bool Function(int ask)? reported,
      }) {
        final listTimeouts = <int>[];
        final captureTimeouts = <int>[];
        return (
          listTimeouts: listTimeouts,
          captureTimeouts: captureTimeouts,
          run: (exe, args) async {
            final timeout = int.parse(args[args.indexOf('--timeout') + 1]);
            if (args.contains('displays')) {
              listTimeouts.add(timeout);
              await Future<void>.delayed(list);
              final known = reported?.call(listTimeouts.length) ?? true;
              return displaysAnswer(args, [
                display(
                  'LCD',
                  uniqueId: 'INNER',
                  active: known ? true : null,
                  primary: true,
                ),
                display(
                  'LCD-1',
                  uniqueId: 'OUTER',
                  displayId: 3,
                  active: known ? false : null,
                ),
              ]);
            }
            captureTimeouts.add(timeout);
            await Future<void>.delayed(capture);
            return ProcessResult(0, 0, '', '');
          },
        );
      }

      const ms = Duration(milliseconds: 1);

      test('waits out a posture not yet reported, then captures', () {
        fakeAsync((async) {
          final devicectl = slow(reported: (ask) => ask > 2);
          final device = IOSSimulatorDevice(
            udid: 'DUO',
            runProcess: devicectl.run,
          )..screenPollInterval = ms * 10;

          // Asked at 0, 10 and 20 ms; the third answer has a posture.
          final outcome = track(device.screenshot(instance, '/tmp/ios.png'));
          async.elapse(ms * 19);
          expect(outcome.done, isFalse);
          expect(devicectl.listTimeouts, hasLength(2));
          async.elapse(ms);

          expect(outcome.done, isTrue);
          expect(outcome.error, isNull);
          expect(devicectl.listTimeouts, hasLength(3));
          expect(devicectl.captureTimeouts, hasLength(1));
        });
      });

      test('a posture never reported ends at the deadline, having asked '
          'every interval', () {
        fakeAsync((async) {
          // Each listing takes 5 ms and the interval is 20: asks start at
          // 0, 25, 50 … The tenth ends at 230 ms with 20 ms left, which is not
          // enough for another interval, so that is where it gives up.
          final devicectl = slow(list: ms * 5, reported: (_) => false);
          final device =
              IOSSimulatorDevice(
                  udid: 'DUO',
                  runProcess: devicectl.run,
                )
                ..screenshotBound = ms * 250
                ..screenPollInterval = ms * 20;

          final outcome = track(device.screenshot(instance, '/tmp/ios.png'));
          async.elapse(ms * 229);
          expect(outcome.done, isFalse);
          async.elapse(ms);

          expect(outcome.done, isTrue);
          expect(
            outcome.error,
            isA<ScreenSelectionException>().having(
              (e) => e.message,
              'message',
              contains('waiting for the device to report which of its screens'),
            ),
          );
          expect(devicectl.listTimeouts, hasLength(10));
          expect(devicectl.captureTimeouts, isEmpty);
        });
      });

      test('a capture gets what the listing left and runs out in it', () {
        fakeAsync((async) {
          final devicectl = slow(list: ms * 150, capture: ms * 500);
          final device = IOSSimulatorDevice(
            udid: 'DUO',
            runProcess: devicectl.run,
          )..screenshotBound = ms * 300;

          final outcome = track(device.screenshot(instance, '/tmp/ios.png'));
          async.elapse(ms * 299);
          expect(outcome.done, isFalse);
          async.elapse(ms);

          // 300 ms in all: not the 150 for the listing and then 300 more.
          expect(outcome.done, isTrue);
          expect(
            outcome.error,
            isA<ScreenshotTimeout>().having(
              (e) => e.step,
              'step',
              'capturing LCD of iOS Simulator (DUO)',
            ),
          );
        });
      });

      test('a listing that outlasts the deadline is the step that ran out', () {
        fakeAsync((async) {
          final devicectl = slow(list: const Duration(seconds: 2));
          final device = IOSSimulatorDevice(
            udid: 'DUO',
            runProcess: devicectl.run,
          )..screenshotBound = ms * 100;

          final outcome = track(device.screenshot(instance, '/tmp/ios.png'));
          async.elapse(ms * 99);
          expect(outcome.done, isFalse);
          async.elapse(ms);

          expect(
            outcome.error,
            isA<ScreenshotTimeout>().having(
              (e) => e.step,
              'step',
              'listing the screens of iOS Simulator (DUO)',
            ),
          );
          expect(devicectl.captureTimeouts, isEmpty);
        });
      });

      test('devicectl is handed the seconds that are left', () {
        fakeAsync((async) {
          final devicectl = slow(list: ms * 1200);
          final device = IOSSimulatorDevice(
            udid: 'DUO',
            runProcess: devicectl.run,
          )..screenshotBound = const Duration(seconds: 3);

          final outcome = track(device.screenshot(instance, '/tmp/ios.png'));
          async.elapse(ms * 1200);

          // 3 s for the listing; then 3 s less its 1.2 s, rounded up.
          expect(outcome.done, isTrue);
          expect(outcome.error, isNull);
          expect(devicectl.listTimeouts, [3]);
          expect(devicectl.captureTimeouts, [2]);
        });
      });
    });

    test('a simulator devicectl does not know names the requirement', () async {
      final device = IOSSimulatorDevice(
        udid: 'SIM-1',
        runProcess: (exe, args) async => ProcessResult(
          0,
          1,
          '',
          'ERROR: The specified device was not found. (Name: SIM-1)',
        ),
      );
      await expectLater(
        device.screenshot(instance, '/tmp/ios.png'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('devicectl does not know the simulator SIM-1'),
              contains('Xcode 27 or later'),
              contains('devicectl list devices'),
            ),
          ),
        ),
      );
    });

    test('lists the screens it has', () async {
      final devicectl = fakeDevicectl(
        () => [display('LCD', uniqueId: 'SCREEN-1', primary: true)],
      );
      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        runProcess: devicectl.run,
      );
      final screens = await device.screens();
      expect(screens.single.id, 'SCREEN-1');
      expect(screens.single.name, 'LCD');
    });

    test('throws on a devicectl capture failure', () async {
      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        runProcess: (exe, args) async {
          if (args.contains('displays')) {
            return displaysAnswer(args, [
              display('LCD', uniqueId: 'SCREEN-1', primary: true),
            ]);
          }
          return ProcessResult(0, 1, '', 'SCREENSHOT_FAILED');
        },
      );

      expect(
        () => device.screenshot(instance, '/tmp/shot.png'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('SCREENSHOT_FAILED'),
          ),
        ),
      );
    });
  });

  group('Device.screenshot', () {
    test('throws UnsupportedError when no vmClient provided', () {
      final device = _MinimalDevice();
      final instance = AppInstance(process: FakeProcess());
      expect(
        () => device.screenshot(instance, '/tmp/shot.png'),
        throwsUnsupportedError,
      );
    });
  });

  // The physical-device launch is a six-step dance (devicectl --console →
  // pid lookup → lldb attach → resume → mDNS discovery), and the app's console
  // output rides the same devicectl process throughout. Faking the whole
  // sequence is the only way to prove output survives it.
  group('IOSDevice.launch', () {
    final sockets = <ServerSocket>[];
    tearDown(() async {
      for (final s in sockets) {
        await s.close();
      }
      sockets.clear();
    });

    /// The bundle `devicectl install` reports installing. Every process
    /// running inside that bundle has an `executable` beginning with this
    /// string, which is the only handle a launch has on the app's pid: an iOS
    /// executable path is `…/<uuid>/Runner.app/Runner` and never contains the
    /// bundle id. Shaped after the fixtures in flutter_tools'
    /// `test/general.shard/ios/core_devices_test.dart`.
    const installationUrl =
        'file:///private/var/containers/Bundle/Application/'
        '12345E6A-7F89-0C12-345E-F6A7E890CFF1/Runner.app/';

    /// What `devicectl install --json-output` writes when it works.
    const installedJson =
        '{"result":{"installedApplications":'
        '[{"installationURL":"$installationUrl"}]}}';

    /// The block lldb prints when the process stops, as it prints it.
    void emitLldbStop(FakeProcess lldb, String reason) {
      lldb.emitStdout('Process 4242 stopped');
      lldb.emitStdout(
        "* thread #1, queue = 'com.apple.main-thread', "
        'stop reason = $reason',
      );
      lldb.emitStdout('    frame #0: 0x000000011c3800c4');
      lldb.emitStdout('Target 0: (Runner) stopped.');
    }

    /// One entry of what `devicectl info processes --json-output` writes.
    Map<String, Object?> runningProcess({
      required int pid,
      String executable = '${installationUrl}Runner',
    }) => {'processIdentifier': pid, 'executable': executable};

    /// Everything one faked launch hands back to the test.
    ///
    /// [args] records every argument list passed to [Process.start], so a test
    /// can assert on what the launch actually asked devicectl to do.
    ///
    /// [installJson] is what `devicectl install` writes to its `--json-output`
    /// path; passing `null` makes it write nothing at all, which is one of the
    /// ways a launch can end up with no installationURL. [runningProcesses] is
    /// the list `info processes` answers with.
    Future<
      ({
        AppInstance instance,
        IOSDevice device,
        FakeProcess devicectl,
        FakeProcess lldb,
        List<List<String>> starts,
        List<Map<String, String>> environments,
        List<List<String>> runs,
      })
    >
    launchFaked({
      String transportType = 'wired',
      List<String> deviceAddresses = const [],
      bool consoleExitsAtLaunch = false,
      String? installJson = installedJson,
      List<Map<String, Object?>>? runningProcesses,
      TcpProbe? forwardProbe,
      FakeProcess? devicectlProcess,
      FakeProcess? lldbProcess,
      FakeProcess? iproxyProcess,
      Object? mdnsStartError,
      bool Function(FakeProcess lldb, String line)? lldbResponder,
      List<List<String>>? runsLog,
      void Function(IOSDevice device)? onDevice,
      String appPath = '/path/to/MyApp.app',
      void Function(String exe, List<String> args)? onRun,
      BuildMode buildMode = BuildMode.debug,
      List<String>? bonjourServices,
      List<String> consoleLines = const [],
      int silentMdnsAttempts = 0,
      AppLogListener? onLog,
    }) async {
      final devicectl = devicectlProcess ?? FakeProcess();
      final lldb = lldbProcess ?? FakeProcess();
      final iproxy = iproxyProcess ?? FakeProcess();
      final starts = <List<String>>[];
      final environments = <Map<String, String>>[];
      final runs = runsLog ?? <List<String>>[];

      // A wired launch port-forwards the advertised VM-service port through
      // iproxy and waits for that forward to accept connections before
      // returning. Stand a real listener up on the port the advertisement
      // names, so the test exercises the whole launch rather than stopping at
      // a missing iproxy.
      final forward = await ServerSocket.bind('127.0.0.1', 0);
      // The probe connects to confirm the forward is live; drop each
      // connection rather than leaving it queued in the accept backlog, which
      // would stall `close()` in tearDown.
      forward.listen((socket) => socket.destroy());
      final forwardPort = forward.port;
      sockets.add(forward);

      final mdns = MdnsVmServiceDiscovery(
        clientFactory: FakeMDnsClientFactory(
          records: dartVmServiceRecords(
            instance: 'com.example.test',
            host: 'Test-iPhone.local',
            port: forwardPort,
            authCode: 'test=',
            addresses: deviceAddresses,
          ),
          startError: mdnsStartError,
          silentAttempts: silentMdnsAttempts,
        ).call,
      );

      final device = IOSDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        mdns: mdns,
        forwardProbe: forwardProbe,
        runProcess: (exe, args) async {
          runs.add([exe, ...args.cast<String>()]);
          onRun?.call(exe, args.cast<String>());
          final out = args.contains('--json-output')
              ? args[args.indexOf('--json-output') + 1]
              : null;
          // What the app's Info.plist declares under NSBonjourServices; a key
          // that is not there is plutil's exit 1.
          if (exe == 'plutil') {
            return bonjourServices == null
                ? ProcessResult(0, 1, '', 'No value at that key path.')
                : ProcessResult(0, 0, json.encode(bonjourServices), '');
          }
          // `list devices`, `install app` and `info processes` all write their
          // answer to the file named by --json-output.
          if (args.contains('devices') && out != null) {
            File(out).writeAsStringSync(devicesJson(transportType));
          } else if (args.contains('install') && out != null) {
            if (installJson != null) File(out).writeAsStringSync(installJson);
          } else if (args.contains('processes') && out != null) {
            File(out).writeAsStringSync(
              json.encode({
                'result': {
                  'runningProcesses':
                      runningProcesses ?? [runningProcess(pid: 4242)],
                },
              }),
            );
          }
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args, env) async {
          starts.add([exe, ...args.cast<String>()]);
          environments.add(env);
          // A distinct fake per helper: a launch owns three of them at once,
          // and one shared fake cannot say which of them a teardown reached.
          return switch (exe) {
            'lldb' => lldb,
            'iproxy' => iproxy,
            _ => devicectl,
          };
        },
      );

      device.buildMode = buildMode;
      onDevice?.call(device);

      // Script the lldb side: each command the launch issues gets the reply
      // lldb itself prints. [lldbResponder] answers first, and returning true
      // means it has handled the line.
      lldb.stdinLines.listen((line) {
        if (lldbResponder?.call(lldb, line) ?? false) return;
        if (line.startsWith('breakpoint set')) {
          lldb.emitStdout('Breakpoint 1: where = Foo`NOTIFY...');
        } else if (line.startsWith('device process attach')) {
          emitLldbStop(lldb, 'signal SIGSTOP');
        } else if (line.startsWith('process continue')) {
          lldb.emitStdout('Process 4242 resuming');
        }
      });

      final pending = device.launch(appPath, onLog: onLog);
      // A launch that fails at the install step never starts devicectl at all,
      // so waiting on its output alone would hang out the test timeout on
      // exactly the failures these tests assert. Whichever settles first wins,
      // and a launch that threw rethrows here.
      await Future.any<Object?>([devicectl.outputAttached, pending]);

      if (consoleExitsAtLaunch) {
        // The console channel ends without ever printing a banner. The launch
        // gate is released by `onDone` instead.
        devicectl.complete(0);
      } else {
        // devicectl's banner releases the launch gate.
        devicectl.emitStdout('Launched application with com.example.test');
        consoleLines.forEach(devicectl.emitStdout);
      }

      return (
        instance: await pending,
        device: device,
        devicectl: devicectl,
        lldb: lldb,
        starts: starts,
        environments: environments,
        runs: runs,
      );
    }

    // The engine's announcement never reaches this host on a physical device,
    // so the URI has to come from the app's mDNS advertisement — including the
    // auth code, without which the VM service refuses the connection.
    test('takes the VM service from the mDNS advertisement', () async {
      final r = await launchFaked();
      expect(r.instance.vmServiceUri, isNotNull);
      expect(r.instance.vmServiceUri!.host, '127.0.0.1');
      expect(r.instance.vmServiceUri!.path, '/test=/');
    });

    // Bazel writes every file into the .ipa with the same fixed 1980 mtime,
    // and `devicectl device install app` keeps an installed file whose size
    // and mtime both match the new one. An AOT App.framework/App that kept its
    // size across a Dart edit installed as the old code.
    test(
      'installs the extracted bundle with fresh modification times',
      () async {
        late String extractedApp;
        DateTime? mtimeAtInstall;
        final before = DateTime.now().subtract(const Duration(seconds: 5));

        final r = await launchFaked(
          appPath: '/path/to/app.ipa',
          onRun: (exe, args) {
            if (exe == 'unzip') {
              extractedApp =
                  '${args.last}/Payload/app.app/Frameworks/App.framework/App';
              File(extractedApp)
                ..createSync(recursive: true)
                ..writeAsBytesSync([1, 2, 3])
                ..setLastModifiedSync(DateTime.utc(1980));
            }
            if (exe == 'xcrun' && args.contains('install')) {
              mtimeAtInstall = File(extractedApp).lastModifiedSync();
            }
          },
        );
        addTearDown(r.instance.disposeScratchDirs);

        expect(mtimeAtInstall, isNotNull);
        expect(mtimeAtInstall!.isAfter(before), isTrue);
      },
    );

    // The installationURL is what names the launched process, so a launch
    // that loses it has no way to recognise the app's pid and must fail at
    // the install step rather than search on.
    test('fails on install when devicectl writes no JSON at all', () async {
      await expectLater(
        launchFaked(installJson: null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('wrote no JSON'),
          ),
        ),
      );
    });

    test('fails on install when the JSON names no installationURL', () async {
      await expectLater(
        launchFaked(
          installJson:
              '{"result":{"installedApplications":[{"bundleID":'
              '"com.example.test"}]}}',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('named no installationURL'),
          ),
        ),
      );
    });

    test('fails on install when devicectl writes unreadable JSON', () async {
      await expectLater(
        launchFaked(installJson: 'not json at all'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('could not read'),
          ),
        ),
      );
    });

    // An app extension's executable lives inside the app bundle, so it
    // contains the installationURL too. Attaching the debugger to a widget
    // extension leaves the app itself stopped forever, waiting for a debugger
    // that went somewhere else — flutter/flutter#183263.
    test('skips app extensions when matching the launched process', () async {
      final r = await launchFaked(
        runningProcesses: [
          runningProcess(
            pid: 111,
            executable: '${installationUrl}PlugIns/Widget.appex/Widget',
          ),
          runningProcess(pid: 4242),
        ],
      );
      // The pid on the attach command is the only thing that says which
      // process the debugger went to. The scripted lldb answers *any* attach
      // with the same `Process 4242 stopped`, so a launch that merely reaches
      // a VM service proves nothing.
      expect(
        r.lldb.stdinBuffer.toString(),
        contains('device process attach --pid 4242'),
      );
      expect(
        r.lldb.stdinBuffer.toString(),
        isNot(contains('device process attach --pid 111')),
      );
      expect(r.instance.vmServiceUri, isNotNull);
    });

    test(
      'fails when no running process belongs to the installed bundle',
      () async {
        await expectLater(
          launchFaked(
            runningProcesses: [
              runningProcess(pid: 1, executable: 'file:///sbin/launchd'),
            ],
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('is the app installed at'),
            ),
          ),
        );
      },
    );

    // `stop` reaps every helper a launch starts, but it takes the AppInstance
    // a *successful* launch produced — so a launch that threw never reached it
    // and left whatever it had started running, with no handle anywhere to
    // reach them by.
    test(
      'a launch that fails before lldb still kills its console launcher',
      () async {
        final devicectl = FakeProcess();

        await expectLater(
          launchFaked(
            devicectlProcess: devicectl,
            runningProcesses: [
              runningProcess(pid: 1, executable: 'file:///sbin/launchd'),
            ],
          ),
          throwsA(isA<StateError>()),
        );

        // Left running, this keeps the app up on the phone and holds the only
        // channel its console output arrives on.
        expect(devicectl.killed, isTrue);
      },
    );

    // A forward that never binds is the likeliest way for a wired launch to
    // fail this late, and it is the one failure that happens *after* all three
    // helpers are up — so every one of them has to be reaped.
    test(
      'a wired launch whose forward never binds kills every helper',
      () async {
        final devicectl = FakeProcess();
        final lldb = FakeProcess();
        final iproxy = FakeProcess();

        // The wait's 10s budget runs on a clock the refused probe moves, so the
        // budget runs out on the first refusal and the test spends no time on
        // it. There is no shorter failure past iproxy — the lldb commands ahead
        // of it wait 30s each.
        var now = DateTime(2026);
        final probed = <int>[];
        await expectLater(
          withClock(
            Clock(() => now),
            () => launchFaked(
              forwardProbe: (port) async {
                probed.add(port);
                now = now.add(const Duration(seconds: 11));
                throw const SocketException('Connection refused');
              },
              devicectlProcess: devicectl,
              lldbProcess: lldb,
              iproxyProcess: iproxy,
            ),
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('iproxy forward for the iOS VM service'),
            ),
          ),
        );

        expect(probed, hasLength(1));
        expect(
          iproxy.killed,
          isTrue,
          reason: 'a surviving iproxy holds its host port indefinitely',
        );
        expect(
          lldb.killed,
          isTrue,
          reason: 'lldb holds the app itself, stopped, on the device',
        );
        expect(devicectl.killed, isTrue);
      },
    );

    test('a launch that fails after resuming the app terminates it', () async {
      // Discovery comes after the resume, so the app is up and running on the
      // phone when it fails; reaping the helpers alone leaves it there.
      final runs = <List<String>>[];
      await expectLater(
        launchFaked(
          mdnsStartError: const SocketException('No route to host'),
          runsLog: runs,
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        runs,
        contains(
          containsAllInOrder(['process', 'terminate', '--pid', '4242']),
        ),
      );
    });

    // Wired: the VM service binds to the device's loopback, so it is only
    // reachable through a forward.
    test('port-forwards the advertised port when wired', () async {
      final r = await launchFaked(transportType: 'wired');
      final iproxy = r.starts.where((a) => a.first == 'iproxy');
      expect(iproxy, hasLength(1));
      expect(iproxy.single, contains('TEST-UDID'));
      expect(r.instance.vmServiceUri!.host, '127.0.0.1');
    });

    // devicectl lists a CoreDevice UUID as `identifier` and the hardware UDID
    // separately. usbmuxd — which iproxy and lldb both go through — only knows
    // the hardware one; addressing it with the CoreDevice UUID yields a
    // forward that binds locally and then resets every connection, so the run
    // looks like it worked right up until DDS fails.
    test('addresses iproxy and lldb with the hardware UDID', () async {
      final r = await launchFaked(transportType: 'wired');
      expect(
        r.starts.firstWhere((a) => a.first == 'iproxy'),
        contains('TEST-UDID'),
      );
      expect(
        r.starts.firstWhere((a) => a.first == 'iproxy'),
        isNot(contains('TEST-COREDEVICE-ID')),
      );
    });

    // devicectl lets `--environment-variables` replace the `DEVICECTL_CHILD_*`
    // variables of its own environment, so passing it would cut off every
    // variable a caller sets that way. The launch's own variable goes in the
    // same way instead, added to the environment the caller's come from.
    test(
      'sets the app environment through DEVICECTL_CHILD_ variables',
      () async {
        final r = await launchFaked();
        final i = r.starts.indexWhere((a) => a.contains('launch'));
        expect(r.starts[i], isNot(contains('--environment-variables')));
        expect(r.environments[i], {
          'DEVICECTL_CHILD_OS_ACTIVITY_DT_MODE': 'enable',
        });
      },
    );

    // iOS refuses an app the local network until someone answers the Local
    // Network question on the phone, and the engine says so in the app's
    // console. Without that said plainly the launch only times out.
    group('an app refused the local network', () {
      Future<List<String>> launchLogging(List<String> consoleLines) async {
        final lines = <String>[];
        await launchFaked(
          consoleLines: consoleLines,
          // Long enough for the console to be read before discovery succeeds.
          silentMdnsAttempts: 1,
          onLog: (line) => lines.add(line.text),
        );
        return lines;
      }

      test('is said to need a tap on Allow', () async {
        final lines = await launchLogging([
          '2026-11-20 02:00:22.410632-0800 app_device[68971:4421414] Could '
              'not register as server for FlutterDartVMServicePublisher, '
              'permission denied. Check your \'Local Network\' permissions '
              'for this app in the Privacy section of the system Settings.',
        ]);
        expect(
          lines,
          contains(
            allOf(
              contains('com.example.test is running'),
              contains('tap Allow'),
              contains('Settings > Privacy & Security > Local Network'),
            ),
          ),
        );
      });

      test('is not suspected of an app that was not refused', () async {
        final lines = await launchLogging([
          'flutter: The Dart VM service is listening on '
              'http://127.0.0.1:50123/abc=/',
        ]);
        expect(lines, isNot(contains(contains('tap Allow'))));
      });
    });

    test('does not bind the VM service to all interfaces when wired', () async {
      final r = await launchFaked(transportType: 'wired');
      final launch = r.starts.firstWhere((a) => a.contains('launch'));
      expect(launch, isNot(contains('--vm-service-host=0.0.0.0')));
    });

    // Wireless: there is no cable to forward through, so the VM service has to
    // listen on all interfaces and gets dialed at the device's own address.
    // The two halves must agree or the session silently has no VM service.
    test('binds the VM service to all interfaces when wireless', () async {
      final r = await launchFaked(
        transportType: 'localNetwork',
        deviceAddresses: ['192.168.1.244'],
      );
      final launch = r.starts.firstWhere((a) => a.contains('launch'));
      expect(launch, contains('--vm-service-host=0.0.0.0'));
    });

    test('dials the device address directly when wireless', () async {
      final r = await launchFaked(
        transportType: 'localNetwork',
        deviceAddresses: ['192.168.1.244'],
      );
      expect(r.instance.vmServiceUri!.host, '192.168.1.244');
      expect(
        r.starts.where((a) => a.first == 'iproxy'),
        isEmpty,
        reason: 'there is no cable to forward through',
      );
    });

    test(
      'keeps forwarding console output after VM-service discovery',
      () async {
        final r = await launchFaked();
        expect(
          r.instance.vmServiceUri,
          isNotNull,
          reason: 'discovery must still work',
        );

        r.devicectl.emitStderr('flutter: printed well after launch\n');
        await pumpEventQueue();

        expect(
          r.instance.logs.read(0).lines.map((l) => l.text),
          contains('flutter: printed well after launch'),
        );
      },
    );

    test('does not flag devicectl stderr as error output', () async {
      final r = await launchFaked();

      // devicectl routes the app's ordinary console output to stderr, so
      // flagging that channel would mark every print() as an error.
      r.devicectl.emitStderr('flutter: an ordinary print\n');
      await pumpEventQueue();

      final line = r.instance.logs
          .read(0)
          .lines
          .firstWhere((l) => l.text.contains('an ordinary print'));
      expect(line.isError, isFalse);
    });

    test('keeps draining lldb after launch returns', () async {
      // lldb outlives launch() and holds the debugserver that keeps the app's
      // JIT alive. Stop reading its pipes and it blocks on write once its
      // stdout buffer fills; a blocked lldb never services the process it
      // controls, so the app hangs on device until the dev tool is killed.
      final r = await launchFaked();

      // Far more than a pipe buffer would hold. If nothing is draining, a
      // real lldb would be blocked by now.
      for (var i = 0; i < 2000; i++) {
        r.lldb.emitStdout('lldb chatter line $i with padding ${'x' * 200}');
      }
      await pumpEventQueue();

      // The fake cannot block, so assert the property that matters: a live
      // reader is still attached to both channels.
      expect(
        r.lldb.stdoutHasListener,
        isTrue,
        reason: 'lldb stdout must stay drained for the process lifetime',
      );
      expect(
        r.lldb.stderrHasListener,
        isTrue,
        reason: 'lldb stderr carries the reason for real lldb failures',
      );
    });

    test('lldb output reaches the app log stream', () async {
      // Upstream treats devicectl and lldb as one combined log source on a
      // CoreDevice under Xcode 26+, because the debugger carries output the
      // console stream may not.
      final r = await launchFaked();

      r.lldb.emitStdout('flutter: hello from the app');
      await pumpEventQueue();

      expect(
        r.instance.logs.read(0).lines.map((l) => l.text),
        contains('flutter: hello from the app'),
      );
    });

    test('lldb output survives devicectl exiting', () async {
      // devicectl --console exits when the app terminates, which is precisely
      // when lldb produces the output that explains why, so the shared stream
      // must outlive the first source to finish.
      final r = await launchFaked();

      r.devicectl.complete(0);
      await pumpEventQueue();

      r.lldb.emitStdout('flutter: Fatal error: index out of range');
      await pumpEventQueue();

      expect(
        r.instance.logs.read(0).lines.map((l) => l.text),
        contains('flutter: Fatal error: index out of range'),
        reason: 'the crash report arrives after the console channel is gone',
      );
    });

    test(
      'lldb output survives a console channel that ends before the attach',
      () async {
        // `devicectl --console` normally runs for the app's lifetime, but it can
        // end during the launch — the app was already running, or devicectl
        // detached — while the app itself stays up and `_findAppProcessId` still
        // answers. lldb attaches after that point, so if the console channel
        // being the only registered producer is enough to close the shared log
        // stream, every line for the rest of the run goes nowhere: mDNS
        // discovery does not read this stream, so nothing else fails and the run
        // proceeds in silence.
        final r = await launchFaked(consoleExitsAtLaunch: true);

        expect(
          r.instance.logs.isClosed,
          isFalse,
          reason: 'lldb is attached and is still a live source of output',
        );

        r.lldb.emitStdout('flutter: hello from the app');
        await pumpEventQueue();

        expect(
          r.instance.logs.read(0).lines.map((l) => l.text),
          contains('flutter: hello from the app'),
        );
      },
    );

    test(
      'the log stream closes once devicectl and lldb have both ended',
      () async {
        final r = await launchFaked();
        expect(r.instance.logs.isClosed, isFalse);

        r.devicectl.complete(0);
        await pumpEventQueue();
        expect(
          r.instance.logs.isClosed,
          isFalse,
          reason: 'lldb is still attached and still reporting',
        );

        r.lldb.complete(0);
        await pumpEventQueue();
        expect(
          r.instance.logs.isClosed,
          isTrue,
          reason: 'a reader must learn the run is over rather than hang',
        );
      },
    );

    // iOS 26+ runs JIT code only on pages the debugger has written, and the
    // NOTIFY_DEBUGGER_ABOUT_RX_PAGES breakpoint is how it learns of each one.
    // Letting lldb auto-continue that breakpoint (`return False` from the
    // script, asynchronous mode) loses hits when two threads allocate code at
    // once — llvm/llvm-project#190956. The app then runs a page nobody wrote,
    // stops on EXC_BAD_ACCESS (code=50) and its VM service goes silent.
    // Measured on an iOS 27 iPhone: about half of a dozen launches froze;
    // with the tool resuming each stop itself, 11 of 11 did not. The same
    // change is flutter_tools af06e99a29 (flutter/flutter#190307).
    test('runs lldb synchronously and leaves resuming to the tool', () async {
      final r = await launchFaked();
      final sent = r.lldb.stdinBuffer.toString();

      expect(sent, contains('script lldb.debugger.SetAsync(False)'));
      expect(sent, contains('NOTIFY_DEBUGGER_ABOUT_RX_PAGES'));
      expect(
        sent,
        isNot(contains('return False')),
        reason: 'the breakpoint script must not auto-continue',
      );
    });

    test('resumes the app after every breakpoint stop, silently', () async {
      final r = await launchFaked();
      final before = 'process continue'
          .allMatches(r.lldb.stdinBuffer.toString())
          .length;

      emitLldbStop(r.lldb, 'breakpoint 1.1');
      await pumpEventQueue();
      emitLldbStop(r.lldb, 'breakpoint 1.1');
      await pumpEventQueue();

      expect(
        'process continue'.allMatches(r.lldb.stdinBuffer.toString()).length,
        before + 2,
      );
      expect(
        r.instance.logs.read(0).lines.map((l) => l.text),
        isNot(contains(contains('stop reason = breakpoint'))),
        reason: 'a routine JIT page stop is not app output',
      );
    });

    test(
      'a stop that is not a breakpoint is reported, then detached',
      () async {
        final r = await launchFaked();

        emitLldbStop(r.lldb, 'EXC_BAD_ACCESS (code=50, address=0x11c3800c4)');
        await pumpEventQueue();

        final sent = r.lldb.stdinBuffer.toString();
        expect(sent, contains('thread backtrace all'));
        expect(sent, contains('detach'));
        expect(
          sent,
          contains('quit'),
          reason: 'the session ends with lldb, and the app is not coming back',
        );
        final logged = r.instance.logs.read(0).lines;
        final reason = logged.firstWhere(
          (l) => l.text.contains('EXC_BAD_ACCESS (code=50'),
        );
        expect(reason.isError, isTrue);
      },
    );

    group('an app that announced its VM service and then died', () {
      test(
        'is said to have exited, with what the debugger last said',
        () async {
          final processes = [runningProcess(pid: 4242)];
          final r = await launchFaked(runningProcesses: processes);
          emitLldbStop(r.lldb, 'EXC_BAD_ACCESS (code=1, address=0x0)');
          await pumpEventQueue();
          processes.clear();

          final why = await r.device.whyAppExited(r.instance);

          expect(
            why,
            allOf(
              contains('com.example.test (pid 4242)'),
              contains('exited after announcing its VM service'),
              contains('EXC_BAD_ACCESS (code=1'),
            ),
          );
        },
      );

      test('is not said to have exited while its process is listed', () async {
        final r = await launchFaked();

        expect(await r.device.whyAppExited(r.instance), isNull);
      });

      // The listing is the platform's word on what runs on the phone, so a
      // different process under the pid (the pid reused) is no evidence for
      // the app: it is gone.
      test('is gone when its pid now belongs to another process', () async {
        final processes = [runningProcess(pid: 4242)];
        final r = await launchFaked(runningProcesses: processes);
        processes
          ..clear()
          ..add(
            runningProcess(pid: 4242, executable: 'file:///usr/libexec/other'),
          );

        expect(
          await r.device.whyAppExited(r.instance),
          contains('exited after announcing'),
        );
      });

      // A phone that cannot be asked has not said the app is gone.
      test('is not declared gone when the phone cannot be asked', () async {
        var asking = false;
        final r = await launchFaked(
          onRun: (exe, args) {
            if (asking && args.contains('processes')) {
              throw ProcessException(exe, args, 'device unreachable');
            }
          },
        );
        asking = true;

        expect(await r.device.whyAppExited(r.instance), isNull);
      });
    });

    // The session lives as long as lldb, and lldb stays at its prompt after
    // the app it debugs exits. An app closed on the phone, or killed by the
    // system, would otherwise leave a run attached to nothing.
    test('an app that exits on its own ends the session', () async {
      final r = await launchFaked();

      r.lldb.emitStdout('Process 4242 exited with status = 0 (0x00000000)');
      await pumpEventQueue();

      expect(r.lldb.stdinBuffer.toString(), contains('quit'));
    });

    // The attach waits on a stop, and lldb's output is replayed to every
    // reader. A stop printed before the attach was asked for — a previous
    // command's, or an earlier line in the same buffer — must not answer it.
    test('does not take an earlier stop as the attach reply', () async {
      final attached = Completer<FakeProcess>();
      final pending = launchFaked(
        lldbResponder: (lldb, line) {
          if (line.startsWith('device select')) {
            // Printed before the attach, so it cannot be the attach's reply.
            emitLldbStop(lldb, 'signal SIGSTOP');
            return true;
          }
          if (line.startsWith('device process attach')) {
            attached.complete(lldb);
            return true;
          }
          return false;
        },
      );
      final held = await attached.future;
      await pumpEventQueue();
      expect(
        held.stdinBuffer.toString(),
        isNot(contains('process continue')),
        reason: 'the attach has not been answered yet',
      );

      emitLldbStop(held, 'signal SIGSTOP');
      final r = await pending;
      expect(r.lldb.stdinBuffer.toString(), contains('process continue'));
    });

    // Killing lldb does not kill the app on a physical device: debugserver
    // detaches and the app keeps running, holding its VM service port and
    // whatever the next launch expected to replace. Measured on an iOS 27
    // iPhone, where every stopped or failed run left its app up.
    test('stop terminates the app on the device', () async {
      final r = await launchFaked();

      final stopping = r.device.stop(r.instance);
      // lldb reports the terminated app as a stop; that is not a crash.
      emitLldbStop(r.lldb, 'signal SIGTERM');
      await stopping;

      expect(
        r.runs,
        contains(
          containsAllInOrder([
            'devicectl',
            'device',
            'process',
            'terminate',
            '--device',
            'TEST-UDID',
            '--pid',
            '4242',
          ]),
        ),
      );
      expect(
        r.lldb.stdinBuffer.toString(),
        isNot(contains('thread backtrace all')),
        reason: 'stopping the app on purpose is not a crash to report',
      );
    });

    // SIGTERM during a launch runs the teardown before any session exists, so
    // the device hears of it only through [Device.abandonLaunch]. Measured on
    // an iOS 27 iPhone before this: the tool exited in a second and left its
    // iproxy running under launchd, holding the VM service port.
    test('abandoning a launch in flight leaves no helper behind', () async {
      late IOSDevice device;
      final starts = <String>[];
      await expectLater(
        launchFaked(
          // The fakes do not exit when killed, so each reap would otherwise sit
          // out the real bound twice over.
          onDevice: (d) =>
              device = d..teardownBound = const Duration(milliseconds: 20),
          lldbResponder: (lldb, line) {
            if (line.startsWith('device process attach')) {
              // The teardown lands while the attach is outstanding.
              unawaited(device.abandonLaunch());
              emitLldbStop(lldb, 'signal SIGSTOP');
              return true;
            }
            return false;
          },
        ).then((r) {
          starts.addAll(r.starts.map((a) => a.first));
          return r;
        }),
        throwsA(isA<StateError>()),
      );
      expect(
        starts,
        isEmpty,
        reason: 'the launch must not complete after being abandoned',
      );
    });

    test('abandoning a launch that returned terminates its app', () async {
      final r = await launchFaked();

      await r.device.abandonLaunch();

      expect(r.lldb.killed, isTrue);
      expect(r.devicectl.killed, isTrue);
      expect(
        r.runs,
        contains(
          containsAllInOrder(['process', 'terminate', '--pid', '4242']),
        ),
      );
    });

    // An AOT app needs no debugger to run, and attaching one cost half of all
    // launches: lldb answered `process continue` with "N_SO not found for
    // N_OSO symbol" and never printed the resume line. flutter_tools attaches
    // lldb only in debug (`shouldAttachLLDBDebugger`).
    group('an AOT build', () {
      for (final mode in [BuildMode.profile, BuildMode.release]) {
        test('in ${mode.name} launches running, with no debugger', () async {
          final r = await launchFaked(buildMode: mode);
          expect(r.starts.map((a) => a.first), isNot(contains('lldb')));
          final launch = r.starts.singleWhere((a) => a.contains('launch'));
          expect(launch, isNot(contains('--start-stopped')));
          expect(launch, contains('--console'));
          expect(r.instance.process, same(r.devicectl));
        });
      }

      test('in release passes no debugging flags', () async {
        final r = await launchFaked(buildMode: BuildMode.release);
        final launch = r.starts.singleWhere((a) => a.contains('launch'));
        expect(launch, isNot(contains('--enable-checked-mode')));
      });

      test('in profile attaches to a VM service the app declares', () async {
        final r = await launchFaked(
          buildMode: BuildMode.profile,
          bonjourServices: ['_rulesflutterexample._tcp', '_dartVmService._tcp'],
        );
        expect(r.instance.vmServiceUri, isNotNull);
        expect(r.instance.vmServiceUri!.host, '127.0.0.1');
        expect(r.instance.vmServiceUri!.path, '/test=/');
        expect(r.starts.where((a) => a.first == 'iproxy'), hasLength(1));
      });

      // A `-c opt` build ships the release engine and leaves the VM service
      // keys out of its Info.plist, so there is nothing to wait five minutes
      // for: iOS will not let an app advertise a service it does not declare.
      test('in profile does not wait for a VM service the app does not '
          'declare', () async {
        final r = await launchFaked(
          buildMode: BuildMode.profile,
          bonjourServices: ['_rulesflutterexample._tcp'],
        );
        expect(r.instance.vmServiceUri, isNull);
        expect(r.starts.where((a) => a.first == 'iproxy'), isEmpty);
      });

      test('in profile reads an app with no Bonjour services as having no '
          'VM service', () async {
        final r = await launchFaked(buildMode: BuildMode.profile);
        expect(r.instance.vmServiceUri, isNull);
      });

      // flutter_tools does not look for one in release at all.
      test('in release never looks for a VM service', () async {
        final r = await launchFaked(
          buildMode: BuildMode.release,
          bonjourServices: ['_dartVmService._tcp'],
        );
        expect(r.instance.vmServiceUri, isNull);
        expect(r.starts.where((a) => a.first == 'iproxy'), isEmpty);
      });

      test('stop terminates the app and its console launcher', () async {
        final r = await launchFaked(buildMode: BuildMode.release);
        await r.device.stop(r.instance);
        expect(r.devicectl.killed, isTrue);
        expect(
          r.runs,
          contains(
            containsAllInOrder(['process', 'terminate', '--pid', '4242']),
          ),
        );
      });
    });

    // The .ipa is unpacked into a temp folder before the install, and only a
    // launch that returns hands it to the AppInstance whose stop deletes it.
    group('a failed launch leaves no unpacked app behind', () {
      /// Creates the bundle `unzip` would, and records where.
      void Function(String exe, List<String> args) unpackInto(
        void Function(String dir) record,
      ) => (exe, args) {
        if (exe != 'unzip') return;
        record(args.last);
        Directory('${args.last}/Payload/app.app').createSync(recursive: true);
      };

      test('when the install fails', () async {
        late String unpacked;
        await expectLater(
          launchFaked(
            appPath: '/path/to/app.ipa',
            installJson: null,
            onRun: unpackInto((dir) => unpacked = dir),
          ),
          throwsA(isA<StateError>()),
        );
        expect(Directory(unpacked).existsSync(), isFalse);
      });

      test('when the VM service is not found', () async {
        late String unpacked;
        await expectLater(
          launchFaked(
            appPath: '/path/to/app.ipa',
            mdnsStartError: const SocketException('No route to host'),
            onRun: unpackInto((dir) => unpacked = dir),
          ),
          throwsA(isA<StateError>()),
        );
        expect(Directory(unpacked).existsSync(), isFalse);
      });

      // A teardown in the middle of a launch reaches the device only through
      // abandonLaunch, and the tool may exit before the launch unwinds.
      test('when the launch is abandoned', () async {
        late String unpacked;
        late IOSDevice device;
        Future<void>? abandoned;
        await expectLater(
          launchFaked(
            appPath: '/path/to/app.ipa',
            onRun: unpackInto((dir) => unpacked = dir),
            onDevice: (d) =>
                device = d..teardownBound = const Duration(milliseconds: 20),
            lldbResponder: (lldb, line) {
              if (!line.startsWith('device process attach')) return false;
              abandoned = device.abandonLaunch();
              emitLldbStop(lldb, 'signal SIGSTOP');
              return true;
            },
          ),
          throwsA(isA<StateError>()),
        );
        await abandoned;
        expect(Directory(unpacked).existsSync(), isFalse);
      });

      test('but a launch that returns keeps it until stop', () async {
        late String unpacked;
        final r = await launchFaked(
          appPath: '/path/to/app.ipa',
          onRun: unpackInto((dir) => unpacked = dir),
        );
        await r.device.abandonLaunch();
        expect(Directory(unpacked).existsSync(), isTrue);
        await r.instance.disposeScratchDirs();
      });
    });

    // Every other launch failure is a StateError the launcher turns into a
    // reported command failure. Discovery threw its own type, which escaped as
    // an unhandled exception and took the tool down with a stack trace.
    test('a discovery failure fails the launch as a StateError', () async {
      await expectLater(
        launchFaked(
          mdnsStartError: const SocketException('No route to host'),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('mDNS socket'),
          ),
        ),
      );
    });
  });

  // `devicectl list devices` lists every device that has ever been paired,
  // including ones that are not attached now.
  group('parseDevicectlDevices', () {
    String devicesJson(List<Map<String, Object?>> devices) => json.encode({
      'result': {'devices': devices},
    });

    test('reads udid, name, transport and hostnames', () {
      final devices = parseDevicectlDevices(
        devicesJson([
          {
            'identifier': 'CORE-1',
            'hardwareProperties': {'udid': 'UDID-1'},
            'deviceProperties': {'name': 'Test iPhone'},
            'connectionProperties': {
              'transportType': 'wired',
              'localHostnames': [
                'Test-iPhone.coredevice.local',
                'UDID-1.coredevice.local',
              ],
            },
          },
        ]),
      );

      expect(devices, hasLength(1));
      expect(devices.single.udid, 'UDID-1');
      expect(devices.single.coreDeviceId, 'CORE-1');
      expect(devices.single.name, 'Test iPhone');
      expect(devices.single.transport, IOSDeviceTransport.wired);
      expect(
        devices.single.hostnames,
        contains('Test-iPhone.coredevice.local'),
      );
    });

    test('maps localNetwork to wireless', () {
      final devices = parseDevicectlDevices(
        devicesJson([
          {
            'identifier': 'CORE-1',
            'hardwareProperties': {'udid': 'UDID-1'},
            'connectionProperties': {'transportType': 'localNetwork'},
          },
        ]),
      );
      expect(devices.single.transport, IOSDeviceTransport.wireless);
    });

    // A device paired once and now sitting in a drawer still appears, with no
    // transport and `tunnelState: unavailable`. Choosing it produces a launch
    // that installs nothing and then waits out every timeout.
    test('drops a paired but unattached device', () {
      final devices = parseDevicectlDevices(
        devicesJson([
          {
            'identifier': 'CORE-GONE',
            'hardwareProperties': {'udid': 'GONE'},
            'connectionProperties': {
              'pairingState': 'paired',
              'tunnelState': 'unavailable',
            },
          },
          {
            'identifier': 'CORE-HERE',
            'hardwareProperties': {'udid': 'HERE'},
            'connectionProperties': {'transportType': 'wired'},
          },
        ]),
      );
      expect(devices.map((d) => d.udid), ['HERE']);
    });

    test('falls back to potentialHostnames when there are no local ones', () {
      final devices = parseDevicectlDevices(
        devicesJson([
          {
            'identifier': 'CORE-1',
            'hardwareProperties': {'udid': 'UDID-1'},
            'connectionProperties': {
              'transportType': 'wired',
              'potentialHostnames': ['Some-iPhone.coredevice.local'],
            },
          },
        ]),
      );
      expect(devices.single.hostnames, ['Some-iPhone.coredevice.local']);
    });
  });

  group('IOSDevice device selection', () {
    IOSDevice deviceListing(
      List<Map<String, Object?>> devices, {
      String? udid,
    }) => IOSDevice(
      udid: udid,
      bundleId: 'com.example.test',
      runProcess: (exe, args) async {
        if (args.contains('devices') && args.contains('--json-output')) {
          File(args[args.indexOf('--json-output') + 1]).writeAsStringSync(
            json.encode({
              'result': {'devices': devices},
            }),
          );
          return ProcessResult(0, 0, '', '');
        }
        // Selection is what these tests are about, so stop the launch at
        // the next step rather than driving the whole device dance.
        return ProcessResult(0, 1, '', 'INSTALL_FAILED');
      },
      startProcess: (exe, args, env) async => FakeProcess(),
    );

    test(
      'ignores a paired but unattached device when auto-detecting',
      () async {
        final device = deviceListing([
          {
            'identifier': 'CORE-GONE',
            'hardwareProperties': {'udid': 'GONE'},
            'connectionProperties': {'tunnelState': 'unavailable'},
          },
        ]);

        await expectLater(
          device.launch('/path/to/MyApp.app'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('No iOS device is attached'),
            ),
          ),
        );
      },
    );

    // Picking one silently would look like a working run against the wrong
    // phone.
    test('refuses to guess between two attached devices', () async {
      final device = deviceListing([
        {
          'identifier': 'CORE-ONE',
          'hardwareProperties': {'udid': 'ONE'},
          'connectionProperties': {'transportType': 'wired'},
        },
        {
          'identifier': 'CORE-TWO',
          'hardwareProperties': {'udid': 'TWO'},
          'connectionProperties': {'transportType': 'localNetwork'},
        },
      ]);

      await expectLater(
        device.launch('/path/to/MyApp.app'),
        throwsA(
          isA<StateError>()
              .having((e) => e.message, 'message', contains('-d ios:<udid>'))
              .having((e) => e.message, 'message', contains('ONE')),
        ),
      );
    });

    // `devicectl list devices` prints the CoreDevice UUID, so that is what a
    // user copying from it will pass; Xcode shows the hardware UDID. Both name
    // the same device.
    test(
      'accepts either the hardware UDID or the CoreDevice identifier',
      () async {
        for (final requested in ['UDID-1', 'CORE-1']) {
          final device = deviceListing([
            {
              'identifier': 'CORE-1',
              'hardwareProperties': {'udid': 'UDID-1'},
              'connectionProperties': {'transportType': 'wired'},
            },
          ], udid: requested);

          // Gets past selection and stops at the faked install.
          await expectLater(
            device.launch('/path/to/MyApp.app'),
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'message',
                contains('INSTALL_FAILED'),
              ),
            ),
          );
        }
      },
    );

    test(
      'says which devices are attached when the requested one is not',
      () async {
        final device = deviceListing([
          {
            'identifier': 'CORE-OTHER',
            'hardwareProperties': {'udid': 'OTHER'},
            'connectionProperties': {'transportType': 'wired'},
          },
        ], udid: 'MISSING');

        await expectLater(
          device.launch('/path/to/MyApp.app'),
          throwsA(
            isA<StateError>()
                .having((e) => e.message, 'message', contains('MISSING'))
                .having((e) => e.message, 'message', contains('OTHER')),
          ),
        );
      },
    );
  });

  group('IOSDevice', () {
    test('has correct name with udid', () {
      final device = IOSDevice(udid: 'TEST-UDID');
      expect(device.name, 'iOS (TEST-UDID)');
    });

    test('buildArgs is arm64 for physical device', () {
      final device = IOSDevice(udid: 'TEST-UDID');
      expect(device.buildArgs, ['--ios_multi_cpus=arm64']);
    });

    test('throws on devicectl install failure', () async {
      final device = IOSDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: (exe, args) async {
          if ((args as List).contains('install')) {
            return ProcessResult(0, 1, '', 'INSTALL_FAILED');
          }
          if (args.contains('devices') && args.contains('--json-output')) {
            File(args[args.indexOf('--json-output') + 1]).writeAsStringSync(
              json.encode({
                'result': {
                  'devices': [
                    {
                      'identifier': 'TEST-COREDEVICE-ID',
                      'hardwareProperties': {'udid': 'TEST-UDID'},
                      'connectionProperties': {'transportType': 'wired'},
                    },
                  ],
                },
              }),
            );
          }
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args, env) async => FakeProcess(),
      );

      expect(() => device.launch('/path/to/MyApp.app'), throwsStateError);
    });

    test('stop kills iproxy and devicectl', () async {
      final fakeDevicectl = FakeProcess();

      final device = IOSDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: (exe, args) async => ProcessResult(0, 0, '', ''),
        startProcess: (exe, args, env) async => fakeDevicectl,
      );

      final instance = AppInstance(process: fakeDevicectl);
      await device.stop(instance);

      // Process should have been killed.
      expect(await fakeDevicectl.exitCode, -1);
    });
  });

  group('Device.applyTimeout', () {
    /// An [IOSDevice] that has resolved a device of the given transport.
    Future<IOSDevice> launchedDevice(String transportType) async {
      final device = IOSDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: (exe, args) async {
          if (args.contains('devices') && args.contains('--json-output')) {
            File(args[args.indexOf('--json-output') + 1]).writeAsStringSync(
              json.encode({
                'result': {
                  'devices': [
                    {
                      'identifier': 'TEST-COREDEVICE-ID',
                      'hardwareProperties': {'udid': 'TEST-UDID'},
                      'connectionProperties': {'transportType': transportType},
                    },
                  ],
                },
              }),
            );
            return ProcessResult(0, 0, '', '');
          }
          return ProcessResult(0, 1, '', 'INSTALL_FAILED');
        },
        startProcess: (exe, args, env) async => FakeProcess(),
      );
      // Resolution happens on the way to the faked install failure.
      await expectLater(device.launch('/path/to/MyApp.app'), throwsStateError);
      return device;
    }

    // A hot restart on hardware re-JITs the app through the lldb breakpoint,
    // which is minutes-scale work. The host default would abandon the RPC and
    // force-close the VM-service connection mid-restart, reporting "timed out"
    // for a restart that was going to succeed.
    test('is far longer on a physical iOS device than on a host', () {
      expect(
        IOSDevice(udid: 'X').applyTimeout,
        greaterThan(MacOSDevice().applyTimeout),
      );
      expect(
        IOSDevice(udid: 'X').applyTimeout,
        greaterThanOrEqualTo(const Duration(minutes: 1)),
      );
    });

    // Re-JITing the app over Wi-Fi costs several times what it costs over a
    // cable (see `IOSDevice.applyTimeout`), so a budget that fits a wired
    // restart abandons a wireless one mid-flight.
    test('is longer again when the device is on the network', () async {
      final wired = await launchedDevice('wired');
      final wireless = await launchedDevice('localNetwork');
      expect(wireless.applyTimeout, greaterThan(wired.applyTimeout));
    });

    test(
      'reports the hardware UDID once resolved, whatever was asked for',
      () async {
        final device = IOSDevice(
          udid: 'CORE-1',
          bundleId: 'com.example.test',
          runProcess: (exe, args) async {
            if (args.contains('devices') && args.contains('--json-output')) {
              File(args[args.indexOf('--json-output') + 1]).writeAsStringSync(
                json.encode({
                  'result': {
                    'devices': [
                      {
                        'identifier': 'CORE-1',
                        'hardwareProperties': {'udid': 'UDID-1'},
                        'connectionProperties': {'transportType': 'wired'},
                      },
                    ],
                  },
                }),
              );
              return ProcessResult(0, 0, '', '');
            }
            return ProcessResult(0, 1, '', 'INSTALL_FAILED');
          },
          startProcess: (exe, args, env) async => FakeProcess(),
        );

        expect(device.udid, 'CORE-1', reason: 'nothing resolved yet');
        await expectLater(
          device.launch('/path/to/MyApp.app'),
          throwsStateError,
        );
        expect(
          device.udid,
          'UDID-1',
          reason: 'usbmuxd-backed tools cannot use the CoreDevice UUID',
        );
      },
    );

    test('a simulator keeps the host budget', () {
      expect(
        IOSSimulatorDevice(udid: 'X').applyTimeout,
        MacOSDevice().applyTimeout,
      );
    });
  });

  group('IOSDevice.screenshot', () {
    test('captures with devicectl, addressed by the UDID', () async {
      final devicectl = fakeDevicectl(
        () => [display('LCD', uniqueId: 'SCREEN-1', primary: true)],
      );
      final device = IOSDevice(udid: 'TEST-UDID', runProcess: devicectl.run);
      await device.screenshot(
        AppInstance(process: FakeProcess()),
        '/tmp/ios.png',
      );
      expect(devicectl.calls.last, [
        'xcrun',
        'devicectl',
        'device',
        'capture',
        'screenshot',
        '--device',
        'TEST-UDID',
        '--destination',
        '/tmp/ios.png',
        '--display-unique-id',
        'SCREEN-1',
        '--timeout',
        '30',
        '--quiet',
      ]);
    });

    // A wired iPhone reports its own screen, which has no unique id, and a
    // wireless display beside it. The built-in one is the default, and is
    // captured by naming no id, which devicectl documents as the primary.
    test('takes the built-in screen over a wireless display', () async {
      final devicectl = fakeDevicectl(
        () => [
          display('LCD', primary: true),
          display(
            'Wireless',
            uniqueId: 'WIRELESS',
            displayId: 2,
            type: 'wireless',
          ),
        ],
      );
      final device = IOSDevice(udid: 'TEST-UDID', runProcess: devicectl.run);
      await device.screenshot(
        AppInstance(process: FakeProcess()),
        '/tmp/ios.png',
      );
      expect(devicectl.calls.last, isNot(contains('--display-unique-id')));
    });

    test('a wireless display is captured when it is named', () async {
      final devicectl = fakeDevicectl(
        () => [
          display('LCD', primary: true),
          display(
            'Wireless',
            uniqueId: 'WIRELESS',
            displayId: 2,
            type: 'wireless',
          ),
        ],
      );
      final device = IOSDevice(udid: 'TEST-UDID', runProcess: devicectl.run);
      await device.screenshot(
        AppInstance(process: FakeProcess()),
        '/tmp/ios.png',
        screen: 'Wireless',
      );
      expect(
        devicectl.calls.last,
        containsAllInOrder(['--display-unique-id', 'WIRELESS']),
      );
    });

    test(
      'a screen with no unique id that is not primary cannot be captured',
      () {
        final devicectl = fakeDevicectl(
          () => [display('LCD', primary: true), display('LCD-1', displayId: 3)],
        );
        final device = IOSDevice(udid: 'TEST-UDID', runProcess: devicectl.run);
        expect(
          () => device.screenshot(
            AppInstance(process: FakeProcess()),
            '/tmp/ios.png',
            screen: 'displayId:3',
          ),
          throwsA(
            isA<ScreenSelectionException>().having(
              (e) => e.reason,
              'reason',
              contains('LCD-1 cannot be captured'),
            ),
          ),
        );
      },
    );

    test('names Xcode 27 when devicectl lacks the subcommands', () async {
      // What a devicectl without the subcommand prints for this command line:
      // its parser stops at `device` and rejects the first option after it.
      final device = IOSDevice(
        udid: 'TEST-UDID',
        runProcess: (exe, args) async => ProcessResult(
          0,
          64,
          '',
          "Error: Unknown option '--device'\n"
              'Usage: devicectl device [--verbose] [--quiet] <subcommand>\n',
        ),
      );
      expect(
        () => device.screenshot(
          AppInstance(process: FakeProcess()),
          '/tmp/ios.png',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('iOS screenshots need Xcode 27 or later'),
          ),
        ),
      );
    });

    test('reports a capture that runs and fails as it is', () async {
      final device = IOSDevice(
        udid: 'TEST-UDID',
        runProcess: (exe, args) async {
          if (args.contains('displays')) {
            return displaysAnswer(args, [
              display('LCD', uniqueId: 'SCREEN-1', primary: true),
            ]);
          }
          return ProcessResult(
            0,
            1,
            '',
            'ERROR: The specified device was not found.',
          );
        },
      );
      expect(
        () => device.screenshot(
          AppInstance(process: FakeProcess()),
          '/tmp/ios.png',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('The specified device was not found'),
              isNot(contains('Xcode 27')),
            ),
          ),
        ),
      );
    });
  });

  group('resolveRunfile', () {
    test('returns null when not in Bazel runfiles', () {
      final result = resolveRunfile('_main/some/nonexistent/path');
      expect(result, isNull);
    });
  });

  group('extractPackageInfo', () {
    test('parses aapt2 dump badging output', () async {
      final info = await extractPackageInfo(
        '/fake/app.apk',
        aapt2Path: '/fake/aapt2',
        runProcess: (exe, args) async {
          return ProcessResult(
            0,
            0,
            "package: name='com.example.myapp' versionCode='1'\n"
                "launchable-activity: name='com.example.myapp.MainActivity'\n",
            '',
          );
        },
      );
      expect(info.packageName, 'com.example.myapp');
      expect(info.activityName, 'com.example.myapp.MainActivity');
    });

    test('throws naming the command that failed', () {
      expect(
        () => extractPackageInfo(
          '/fake/app.apk',
          aapt2Path: '/fake/aapt2',
          runProcess: (exe, args) async =>
              ProcessResult(0, 1, '', 'not a valid APK'),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('/fake/aapt2 dump badging /fake/app.apk'),
              contains('not a valid APK'),
            ),
          ),
        ),
      );
    });
  });

  group('waitForLocalTcpPort', () {
    test('returns once a listener accepts', () async {
      final server = await ServerSocket.bind('127.0.0.1', 0);
      addTearDown(server.close);
      await waitForLocalTcpPort(server.port, what: 'test listener');
    });

    // The rest of the wait is time and answers, not sockets: the probe is
    // faked and `fakeAsync` moves the clock, so each outcome below is exact.
    group('against a faked probe', () {
      /// A probe that refuses until [acceptsFrom] on the (fake) clock, and
      /// records when it was asked.
      ({TcpProbe probe, List<Duration> asked}) listener(
        FakeAsync async, {
        Duration? acceptsFrom,
      }) {
        final asked = <Duration>[];
        return (
          asked: asked,
          probe: (port) async {
            asked.add(async.elapsed);
            if (acceptsFrom == null || async.elapsed < acceptsFrom) {
              throw const SocketException('Connection refused');
            }
          },
        );
      }

      test('waits for a listener that binds late', () {
        fakeAsync((async) {
          final l = listener(async, acceptsFrom: const Duration(seconds: 1));
          final outcome = track(
            waitForLocalTcpPort(1, what: 'late listener', probe: l.probe),
          );

          async.elapse(const Duration(milliseconds: 999));
          expect(outcome.done, isFalse);

          // Asks at 0, 50, 150, 350, 750 ms, then every 500 ms: 1250 is the
          // first ask after the bind at 1000.
          async.elapse(const Duration(milliseconds: 251));
          expect(outcome.done, isTrue);
          expect(outcome.error, isNull);
          expect(
            l.asked.map((d) => d.inMilliseconds),
            [0, 50, 150, 350, 750, 1250],
          );
        });
      });

      test('throws a StateError naming the forward when nothing binds', () {
        fakeAsync((async) {
          final l = listener(async);
          final outcome = track(
            waitForLocalTcpPort(
              4242,
              what: 'iproxy forward',
              budget: const Duration(seconds: 2),
              probe: l.probe,
            ),
          );

          // The budget is spent by the ask at 2250 ms (0, 50, 150, 350, 750,
          // 1250, 1750, 2250); nothing is asked before it, and it fails then.
          async.elapse(const Duration(milliseconds: 2249));
          expect(outcome.done, isFalse);
          async.elapse(const Duration(milliseconds: 1));

          expect(outcome.done, isTrue);
          expect(
            outcome.error,
            isA<StateError>().having(
              (e) => e.message,
              'message',
              startsWith(
                'iproxy forward on 127.0.0.1:4242 did not accept connections '
                'within 2s of starting.',
              ),
            ),
          );
          expect(l.asked.last, const Duration(milliseconds: 2250));
        });
      });

      test('an ask that lands past the budget still succeeds if it is up', () {
        fakeAsync((async) {
          final l = listener(async, acceptsFrom: const Duration(seconds: 2));
          final outcome = track(
            waitForLocalTcpPort(
              1,
              what: 'edge listener',
              budget: const Duration(seconds: 2),
              probe: l.probe,
            ),
          );
          async.elapse(const Duration(seconds: 3));

          expect(outcome.done, isTrue);
          expect(outcome.error, isNull);
        });
      });
    });
  });

  group('desktopLaunchEnvironment', () {
    test('always asks the embedder for an ephemeral VM service port', () {
      // A fixed port collides across a multi-device run, and without one the
      // app binds no VM service at all — no hot reload, no DevTools.
      expect(
        desktopLaunchEnvironment(base: const {})['FLUTTER_VM_SERVICE_PORT'],
        '0',
      );
    });

    test('declares no engine switches when none were asked for', () {
      // FLUTTER_ENGINE_SWITCHES is a count the embedder iterates. Setting it
      // to 0 and setting nothing at all are the same to the engine, but the
      // absent form is what an unmodified launch has always looked like.
      final env = desktopLaunchEnvironment(base: const {});

      expect(env.keys, isNot(contains('FLUTTER_ENGINE_SWITCHES')));
      expect(
        env.keys.where((k) => k.startsWith('FLUTTER_ENGINE_SWITCH_')),
        isEmpty,
      );
    });

    test('passes start-paused as a counted engine switch', () {
      // The desktop embedders read switches from the environment and nowhere
      // else — the runner's argv goes to the Dart entrypoint, not the engine.
      final env = desktopLaunchEnvironment(startPaused: true, base: const {});

      expect(env['FLUTTER_ENGINE_SWITCHES'], '1');
      expect(env['FLUTTER_ENGINE_SWITCH_1'], 'start-paused=true');
    });

    test('inherits the environment the app is launched from', () {
      final env = desktopLaunchEnvironment(base: const {'HOME': '/home/dev'});

      expect(env['HOME'], '/home/dev');
    });
  });

  group('bounded teardown', () {
    /// Every log record the code under test emits while [body] runs.
    Future<List<LogRecord>> recording(Future<void> Function() body) async {
      final records = <LogRecord>[];
      final sub = Logger.root.onRecord.listen(records.add);
      try {
        await body();
      } finally {
        await sub.cancel();
      }
      return records;
    }

    test('an app that ignores SIGTERM is escalated to SIGKILL, not waited on '
        'forever', () async {
      final process = FakeProcess()..ignoresSigterm = true;
      final device = MacOSDevice()
        ..teardownBound = const Duration(milliseconds: 50);

      // The bound is what makes this return at all: without it `stop` awaits
      // an `exitCode` that a SIGTERM-trapping process never completes, and
      // `flutter_bazel` never comes back.
      final records = await recording(
        () => device
            .stop(AppInstance(process: process))
            .timeout(
              const Duration(seconds: 5),
              onTimeout: () => fail(
                'stop() never returned: the teardown is '
                'still unbounded',
              ),
            ),
      );

      expect(
        process.signals,
        [ProcessSignal.sigterm, ProcessSignal.sigkill],
        reason:
            'SIGTERM is a request a wedged process can refuse; SIGKILL '
            'is the only escalation that is not refusable',
      );
      expect(await process.exitCode, -9);
      expect(
        records.where((r) => r.message.contains('process_kill_escalated')),
        isNotEmpty,
        reason:
            'escalating past a refused SIGTERM is degradation, and this '
            'project does not degrade silently',
      );
    });

    test('an app that exits on SIGTERM is never escalated', () async {
      final process = FakeProcess();
      // Deliberately enormous: if this test passes it is because the process
      // exited, not because a short bound expired.
      final device = MacOSDevice()..teardownBound = const Duration(seconds: 30);

      final records = await recording(
        () => device
            .stop(AppInstance(process: process))
            .timeout(const Duration(seconds: 5)),
      );

      expect(
        process.signals,
        [ProcessSignal.sigterm],
        reason: 'a process that stops when asked must not also be SIGKILLed',
      );
      expect(
        records.where((r) => r.message.contains('process_kill')),
        isEmpty,
        reason: 'an ordinary stop is not worth a warning',
      );
    });

    test(
      'a real process that traps SIGTERM is escalated and actually dies',
      () async {
        // The one place the escalation meets a real kernel rather than a fake,
        // which is what keeps FakeProcess honest if the platform ever stops
        // behaving this way.
        final real = await Process.start('/bin/sh', [
          '-c',
          'trap "" TERM; echo ready; while true; do sleep 0.05; done',
        ]);
        final ready = Completer<void>();
        real.stdout.listen((data) {
          if (String.fromCharCodes(data).contains('ready') &&
              !ready.isCompleted) {
            ready.complete();
          }
        });
        real.stderr.listen((_) {});
        await ready.future.timeout(const Duration(seconds: 10));
        addTearDown(() => real.kill(ProcessSignal.sigkill));

        final device = MacOSDevice()
          ..teardownBound = const Duration(milliseconds: 200);
        // The 10 s is a guard against hanging, not a claim about speed: how
        // long the stop took is load, and it is not asserted. That the wait
        // was bounded is the escalation itself, the record below.
        final records = await recording(
          () => device
              .stop(AppInstance(process: real))
              .timeout(
                const Duration(seconds: 10),
                onTimeout: () => fail(
                  'stop() never returned against a real '
                  'SIGTERM-trapping process',
                ),
              ),
        );

        expect(
          await real.exitCode,
          -9,
          reason:
              'SIGKILL is what this process can be killed by, and -9 is '
              'what dart:io reports for it',
        );
        expect(
          records.where((r) => r.message.contains('process_kill_escalated')),
          isNotEmpty,
          reason: 'the wait is bounded, not merely eventual',
        );
      },
      testOn: '!windows',
    );

    // A Ctrl-C in a terminal reaches the app as well as this tool — they share
    // the terminal's process group — so by the time teardown asks, the app
    // has often gone. `kill` answers `false` for a process that has exited,
    // and reading that as a failed kill told every such user to go and stop by
    // hand an app that was no longer running.
    test(
      'an app that has already exited is stopped without a warning',
      () async {
        final real = await Process.start('/bin/sh', ['-c', 'exit 0']);
        await real.exitCode;
        expect(
          real.kill(),
          isFalse,
          reason:
              'the platform fact this is about: FakeProcess mirrors it, and a '
              'fake that did not could never fail this test',
        );

        final records = await recording(
          () => MacOSDevice().stop(AppInstance(process: real)),
        );

        expect(
          records.where((r) => r.message.contains('process_kill')),
          isEmpty,
          reason: 'an app that is already gone was stopped; nothing failed',
        );
      },
      testOn: '!windows',
    );

    test(
      'FakeProcess answers a kill after its exit the way a process does',
      () {
        final process = FakeProcess()..complete(0);

        expect(process.kill(), isFalse);
      },
    );

    test('a web module server that never finishes stopping does not hold the '
        'browser hostage', () async {
      final process = FakeProcess();
      final device = WebDevice()
        ..teardownBound = const Duration(milliseconds: 50)
        ..setModuleServer(_HangingModuleServer());

      final records = await recording(
        () => device
            .stop(AppInstance(process: process))
            .timeout(
              const Duration(seconds: 5),
              onTimeout: () => fail(
                'stop() never returned: a wedged module '
                'server still blocks the teardown',
              ),
            ),
      );

      expect(
        process.signals,
        contains(ProcessSignal.sigterm),
        reason:
            'the kill sits AFTER the module server in the chain, so an '
            'unbounded stop() there means the browser is never even asked '
            'to exit',
      );
      expect(
        records.where((r) => r.message.contains('teardown_step_timed_out')),
        isNotEmpty,
      );
    });
  });
}

/// A [WebModuleServer] whose `stop()` never completes.
///
/// Not a hypothetical: `stop()` awaits `dwds.stop()`, which reaches
/// `DebugService.close()` → `dds.shutdown()` and `DwdsVmClient.close()` →
/// `client.dispose()` — peer-dependent awaits in a third-party package this
/// repo does not control.
class _HangingModuleServer extends WebModuleServer {
  _HangingModuleServer()
    : super(
        webToolchain: WebToolchainPaths(
          ddcOutlineDill: '/nonexistent',
          librariesSpec: '/nonexistent',
          dartSdkJs: '/nonexistent',
          ddcModuleLoaderJs: '/nonexistent',
          stackTraceMapperJs: '/nonexistent',
          dartSdkRoot: '/nonexistent',
        ),
        buildOutputDir: '/nonexistent',
        entrypointFilename: 'main.dart',
        flutterBootstrapJsPath: '/nonexistent',
        dartExecutable: '/nonexistent',
        options: const WebServerOptions(crossOriginIsolation: false),
      );

  @override
  Future<void> stop() => Completer<void>().future;
}

/// A device whose only interesting property is what it demands of the host.
class _ToolsDevice extends Device {
  final List<HostTool> _tools;

  _ToolsDevice(this._tools);

  @override
  Future<List<HostTool>> requiredHostTools() async => _tools;

  @override
  String get name => 'Tools';

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) =>
      throw UnimplementedError();

  @override
  Future<void> stop(AppInstance instance) => throw UnimplementedError();
}

class _MinimalDevice extends Device {
  @override
  String get name => 'Minimal';

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) =>
      throw UnimplementedError();

  @override
  Future<void> stop(AppInstance instance) => throw UnimplementedError();
}
