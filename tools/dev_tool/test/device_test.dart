import 'dart:io';

import 'package:flutter_bazel_dev_tool/device.dart';
import 'package:flutter_bazel_dev_tool/runfiles_helper.dart';
import 'package:test/test.dart';

import 'fakes.dart';

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
      final device = AndroidDevice(deviceId: 'emulator-5554');
      expect(device.name, 'Android (emulator-5554)');
    });

    test('AndroidDevice name is "Android" when no deviceId', () {
      final device = AndroidDevice();
      expect(device.name, 'Android');
    });
  });

  group('resolveDevices', () {
    test('returns auto-detected device when no IDs given', () {
      final devices = resolveDevices([]);
      expect(devices, hasLength(1));
    });

    test('resolves macos to MacOSDevice', () {
      final devices = resolveDevices(['macos']);
      expect(devices.single, isA<MacOSDevice>());
    });

    test('resolves linux to LinuxDevice', () {
      final devices = resolveDevices(['linux']);
      expect(devices.single, isA<LinuxDevice>());
    });

    test('resolves windows to WindowsDevice', () {
      final devices = resolveDevices(['windows']);
      expect(devices.single, isA<WindowsDevice>());
    });

    test('resolves chrome to WebDevice', () {
      final devices = resolveDevices(['chrome']);
      expect(devices.single, isA<WebDevice>());
    });

    test('resolves ios-simulator to IOSSimulatorDevice', () {
      final devices = resolveDevices(['ios-simulator']);
      expect(devices.single, isA<IOSSimulatorDevice>());
    });

    test('resolves ios-simulator:UDID to IOSSimulatorDevice with udid', () {
      final devices = resolveDevices(['ios-simulator:ABC-123']);
      final device = devices.single as IOSSimulatorDevice;
      expect(device.udid, 'ABC-123');
    });

    test('resolves unknown ID as Android serial', () {
      final devices = resolveDevices(['emulator-5554']);
      expect(devices.single, isA<AndroidDevice>());
    });

    test('resolves multiple device IDs', () {
      final devices = resolveDevices(['macos', 'chrome']);
      expect(devices, hasLength(2));
      expect(devices[0], isA<MacOSDevice>());
      expect(devices[1], isA<WebDevice>());
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

    test('AndroidDevice defaults to arm64 platform', () {
      final device = AndroidDevice();
      expect(device.buildArgs, [
        '--platforms=@rules_flutter//flutter/platforms:android_arm64',
      ]);
    });

    test('AndroidDevice respects custom abi', () {
      final device = AndroidDevice(abi: 'x64');
      expect(device.buildArgs, [
        '--platforms=@rules_flutter//flutter/platforms:android_x64',
      ]);
    });

    test('WebDevice returns empty buildArgs', () {
      expect(WebDevice().buildArgs, isEmpty);
    });
  });

  group('IOSSimulatorDevice', () {
    test('has correct name with udid', () {
      final device = IOSSimulatorDevice(udid: 'ABC-123');
      expect(device.name, 'iOS Simulator (ABC-123)');
    });

    test('calls simctl install and launch', () async {
      final calls = <(String, List<String>)>[];
      final fakeLog = FakeProcess();

      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: (exe, args) async {
          calls.add((exe, args));
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async {
          calls.add((exe, args));
          return fakeLog;
        },
      );

      Future.delayed(Duration(milliseconds: 10), () {
        fakeLog.complete(0);
      });

      await device.launch('/path/to/MyApp.app');

      // Should have: boot, install, log stream spawn, launch.
      final xcrunCalls = calls.where((c) => c.$1 == 'xcrun').toList();
      expect(xcrunCalls.length, greaterThanOrEqualTo(4));

      final bootCall = xcrunCalls.firstWhere(
          (c) => c.$2.contains('boot'));
      expect(bootCall.$2, contains('TEST-UDID'));

      final installCall = xcrunCalls.firstWhere(
          (c) => c.$2.contains('install'));
      expect(installCall.$2, contains('TEST-UDID'));
      expect(installCall.$2, contains('/path/to/MyApp.app'));

      final launchCall = xcrunCalls.firstWhere(
          (c) => c.$2.contains('launch'));
      expect(launchCall.$2, contains('com.example.test'));
    });

    test('throws on simctl install failure', () async {
      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: (exe, args) async {
          if ((args as List).contains('install')) {
            return ProcessResult(0, 1, '', 'INSTALL_FAILED');
          }
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async => FakeProcess(),
      );

      expect(() => device.launch('/path/to/MyApp.app'), throwsStateError);
    });

    test('stop calls simctl terminate when bundleId is set', () async {
      final calls = <(String, List<String>)>[];
      final fakeLog = FakeProcess();

      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: (exe, args) async {
          calls.add((exe, args));
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async => fakeLog,
      );

      final instance = AppInstance(process: fakeLog);
      await device.stop(instance);

      final terminateCall = calls.firstWhere(
          (c) => c.$2.contains('terminate'));
      expect(terminateCall.$2, contains('com.example.test'));
    });

    test('extracts .app from .ipa before install', () async {
      final calls = <(String, List<String>)>[];
      final fakeLog = FakeProcess();

      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: (exe, args) async {
          calls.add((exe, args));
          if (exe == 'unzip') {
            // Simulate unzip by creating Payload/app.app directory.
            final dest = args.last;
            Directory('$dest/Payload/app.app').createSync(recursive: true);
            File('$dest/Payload/app.app/Info.plist').writeAsStringSync('');
          }
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async {
          calls.add((exe, args));
          return fakeLog;
        },
      );

      Future.delayed(Duration(milliseconds: 10), () {
        fakeLog.complete(0);
      });

      await device.launch('/path/to/app.ipa');

      // Should have called unzip.
      final unzipCall = calls.firstWhere((c) => c.$1 == 'unzip');
      expect(unzipCall.$2, contains('/path/to/app.ipa'));

      // simctl install should receive the extracted .app, not the .ipa.
      final installCall = calls.firstWhere(
          (c) => c.$1 == 'xcrun' && c.$2.contains('install'));
      expect(installCall.$2.last, endsWith('.app'));
      expect(installCall.$2.last, isNot(endsWith('.ipa')));
    });

    test('discovers VM service URI from log stream', () async {
      final fakeLog = FakeProcess();

      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: (exe, args) async => ProcessResult(0, 0, '', ''),
        startProcess: (exe, args) async => fakeLog,
      );

      Future.delayed(Duration(milliseconds: 20), () {
        fakeLog.emitStdout(
            'The Dart VM service is listening on http://127.0.0.1:54321/abc=/');
      });

      final instance = await device.launch('/path/to/MyApp.app');
      expect(instance.vmServiceUri, isNotNull);
      expect(instance.vmServiceUri.toString(),
          'http://127.0.0.1:54321/abc=/');
    });
  });

  group('WebDevice', () {
    test('has correct name', () {
      final device = WebDevice();
      expect(device.name, 'Chrome');
    });
  });

  group('findChrome', () {
    test('returns a string or null', () {
      // Just verifies it doesn't throw.
      final result = findChrome();
      expect(result, anyOf(isNull, isA<String>()));
    });
  });

  group('AndroidDevice.launch', () {
    test('calls adb install with -r and device flag', () async {
      final calls = <(String, List<String>)>[];
      final fakeLogcat = FakeProcess();

      final device = AndroidDevice(
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

      Future.delayed(Duration(milliseconds: 10), () {
        fakeLogcat.complete(0);
      });

      await device.launch('/path/to/app.apk');

      final runCalls = calls
          .where((c) => c.$1 == 'adb')
          .toList();
      expect(runCalls.length, greaterThanOrEqualTo(3));

      final installCall = runCalls.firstWhere(
          (c) => c.$2.contains('install'));
      expect(installCall.$2, contains('-s'));
      expect(installCall.$2, contains('emulator-5554'));
      expect(installCall.$2, contains('-r'));
      expect(installCall.$2, contains('/path/to/app.apk'));
    });

    test('calls adb shell am start with package/activity', () async {
      final calls = <(String, List<String>)>[];
      final fakeLogcat = FakeProcess();

      final device = AndroidDevice(
        packageName: 'com.example.app',
        activityName: '.FlutterActivity',
        adbPath: 'adb',
        runProcess: (exe, args) async {
          calls.add((exe, args));
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async => fakeLogcat,
      );

      Future.delayed(Duration(milliseconds: 10), () {
        fakeLogcat.complete(0);
      });

      await device.launch('/path/to/app.apk');

      final startCall = calls.firstWhere(
          (c) => c.$2.contains('am'));
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
        packageName: 'com.example.app',
        adbPath: 'adb',
        runProcess: (exe, args) async {
          calls.add((exe, args));
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async => fakeLogcat,
      );

      Future.delayed(Duration(milliseconds: 10), () {
        fakeLogcat.complete(0);
      });

      await device.launch('/path/to/app.apk');

      final startCall = calls.firstWhere(
          (c) => c.$2.contains('am'));
      expect(startCall.$2, contains('com.example.app/.MainActivity'));
    });

    test('throws on adb install failure', () async {
      final device = AndroidDevice(
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

    test('discovers VM service URI from logcat', () async {
      final fakeLogcat = FakeProcess();

      final device = AndroidDevice(
        packageName: 'com.example.app',
        adbPath: 'adb',
        runProcess: (exe, args) async => ProcessResult(0, 0, '', ''),
        startProcess: (exe, args) async => fakeLogcat,
      );

      Future.delayed(Duration(milliseconds: 20), () {
        fakeLogcat.emitStdout(
            'I/flutter: The Dart VM service is listening on http://127.0.0.1:12345/abc=/');
      });

      final instance = await device.launch('/path/to/app.apk');
      expect(instance.vmServiceUri, isNotNull);
      expect(instance.vmServiceUri.toString(),
          'http://127.0.0.1:12345/abc=/');
    });

    test('stop calls force-stop when packageName is set', () async {
      final calls = <(String, List<String>)>[];
      final fakeLogcat = FakeProcess();

      final device = AndroidDevice(
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

      final stopCall = calls.firstWhere(
          (c) => c.$2.contains('force-stop'));
      expect(stopCall.$2, contains('com.example.app'));
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
            Directory('$dest/MyApp.app/Contents/MacOS')
                .createSync(recursive: true);
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
      Future.delayed(Duration(milliseconds: 20), () {
        fakeAppProcess.emitStdout(
            'The Dart VM service is listening on http://127.0.0.1:12345/test=/');
      });

      await device.launch('/path/to/app.zip');

      // Should have called unzip.
      final unzipCall = calls.firstWhere((c) => c.$1 == 'unzip');
      expect(unzipCall.$2, contains('/path/to/app.zip'));

      // Should have started the extracted executable.
      final startCalls =
          calls.where((c) => c.$1 != 'unzip' && c.$1 != 'xcrun').toList();
      expect(startCalls, isNotEmpty);
      expect(startCalls.last.$1, contains('MyApp'));
    });

    test('launches .app bundle directly', () async {
      final calls = <(String, List<String>)>[];
      final fakeAppProcess = FakeProcess();

      final device = MacOSDevice(
        startProcess: (exe, args) async {
          calls.add((exe, args));
          return fakeAppProcess;
        },
      );

      // Emit VM service URI so launch doesn't hang waiting for it.
      Future.delayed(Duration(milliseconds: 20), () {
        fakeAppProcess.emitStdout(
            'The Dart VM service is listening on http://127.0.0.1:12345/test=/');
      });

      await device.launch('/path/to/MyApp.app');

      expect(calls, hasLength(1));
      expect(calls[0].$1, '/path/to/MyApp.app/Contents/MacOS/MyApp');
    });
  });

  group('MacOSDevice.screenshot', () {
    test('throws structured error when bundled helper binary is missing',
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
    });
  });

  group('LinuxDevice.screenshot', () {
    test('uses scrot when no vmClient', () async {
      final calls = <(String, List<String>)>[];

      final device = LinuxDevice(
        runProcess: (exe, args) async {
          calls.add((exe, args));
          return ProcessResult(0, 0, '', '');
        },
      );

      final instance = AppInstance(process: FakeProcess());
      await device.screenshot(instance, '/tmp/linux.png');

      expect(calls, hasLength(1));
      expect(calls[0].$1, 'scrot');
      expect(calls[0].$2, ['/tmp/linux.png']);
    });
  });

  group('WindowsDevice.screenshot', () {
    test('throws structured error when bundled dxcam binary is missing',
        () async {
      // The implementation uses `resolveRunfileWithManifest` to locate
      // the bundled dxcam `py_binary` and shells to it directly via
      // `Process.run`; it doesn't go through the injected `runProcess`
      // hook. Under unit-test runfiles the tool isn't reachable, so the
      // observable contract is the actionable error that points at the
      // build target. (This test was previously asserting a powershell
      // codepath that no longer exists.)
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
    });
  });

  group('AndroidDevice.screenshot', () {
    test('uses adb screencap when no vmClient', () async {
      final calls = <(String, List<String>)>[];

      final device = AndroidDevice(
        deviceId: 'emulator-5554',
        adbPath: 'adb',
        runProcess: (exe, args) async {
          calls.add((exe, args));
          return ProcessResult(0, 0, '', '');
        },
      );

      final instance = AppInstance(process: FakeProcess());
      await device.screenshot(instance, '/tmp/android.png');

      final adbCalls = calls.where((c) => c.$1 == 'adb').toList();
      expect(adbCalls.length, 3); // screencap, pull, rm
    });
  });

  group('IOSSimulatorDevice.screenshot', () {
    test('calls simctl io screenshot', () async {
      final calls = <(String, List<String>)>[];

      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        runProcess: (exe, args) async {
          calls.add((exe, args));
          return ProcessResult(0, 0, '', '');
        },
      );

      final instance = AppInstance(process: FakeProcess());
      await device.screenshot(instance, '/tmp/ios.png');

      expect(calls, hasLength(1));
      expect(calls[0].$1, 'xcrun');
      expect(
          calls[0].$2, ['simctl', 'io', 'TEST-UDID', 'screenshot', '/tmp/ios.png']);
    });

    test('throws on simctl screenshot failure', () async {
      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        runProcess: (exe, args) async {
          if ((args as List).contains('screenshot')) {
            return ProcessResult(0, 1, '', 'SCREENSHOT_FAILED');
          }
          return ProcessResult(0, 0, '', '');
        },
      );

      final instance = AppInstance(process: FakeProcess());
      expect(
        () => device.screenshot(instance, '/tmp/shot.png'),
        throwsStateError,
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

  group('IOSDevice', () {
    test('has correct name with udid', () {
      final device = IOSDevice(udid: '00008101-001C512E14D2001E');
      expect(device.name, 'iOS (00008101-001C512E14D2001E)');
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
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async => FakeProcess(),
      );

      expect(() => device.launch('/path/to/MyApp.app'), throwsStateError);
    });

    test('stop kills iproxy and devicectl', () async {
      final fakeDevicectl = FakeProcess();

      final device = IOSDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: (exe, args) async => ProcessResult(0, 0, '', ''),
        startProcess: (exe, args) async => fakeDevicectl,
      );

      final instance = AppInstance(process: fakeDevicectl);
      await device.stop(instance);

      // Process should have been killed.
      expect(await fakeDevicectl.exitCode, -1);
    });

  });

  group('IOSDevice.screenshot', () {
    test('throws when not running in Bazel runfiles', () async {
      final device = IOSDevice(
        udid: 'TEST-UDID',
        runProcess: (exe, args) async => ProcessResult(0, 0, '', ''),
      );

      final instance = AppInstance(process: FakeProcess());
      // Without runfiles, should throw telling user to build with bazel.
      expect(
        () => device.screenshot(instance, '/tmp/ios.png'),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('bazel build'),
        )),
      );
    });
  });

  group('resolveRunfile', () {
    test('returns null when not in Bazel runfiles', () {
      final result = resolveRunfile('_main/some/nonexistent/path');
      expect(result, isNull);
    });
  });

  group('resolveDevices ios', () {
    test('resolves ios to IOSDevice', () {
      final devices = resolveDevices(['ios']);
      expect(devices.single, isA<IOSDevice>());
    });

    test('resolves ios:UDID to IOSDevice with udid', () {
      final devices = resolveDevices(['ios:ABC-123']);
      final device = devices.single as IOSDevice;
      expect(device.udid, 'ABC-123');
    });
  });

  group('resolveAdb', () {
    test('returns a string', () {
      final result = resolveAdb();
      expect(result, isA<String>());
      expect(result, isNotEmpty);
    });
  });

  group('extractPackageInfo', () {
    test('parses aapt2 dump badging output', () async {
      final info = await extractPackageInfo(
        '/fake/app.apk',
        runProcess: (exe, args) async {
          return ProcessResult(0, 0,
              "package: name='com.example.myapp' versionCode='1'\n"
              "launchable-activity: name='com.example.myapp.MainActivity'\n",
              '');
        },
      );
      expect(info.packageName, 'com.example.myapp');
      expect(info.activityName, 'com.example.myapp.MainActivity');
    });

    test('throws on aapt2 failure', () {
      expect(
        () => extractPackageInfo(
          '/fake/app.apk',
          runProcess: (exe, args) async =>
              ProcessResult(0, 1, '', 'not found'),
        ),
        throwsStateError,
      );
    });
  });
}

class _MinimalDevice extends Device {
  @override
  String get name => 'Minimal';

  @override
  Future<AppInstance> launch(String appPath) => throw UnimplementedError();

  @override
  Future<void> stop(AppInstance instance) => throw UnimplementedError();
}
