import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/dev_tool_exception.dart';
import 'package:flutter_bazel_dev_tool/device.dart';
import 'package:flutter_bazel_dev_tool/device_id.dart';
import 'package:test/test.dart';

const _simUdid = '176BA0D3-AFA5-4D72-BE1F-0F5916796259';

final _simctlJson = json.encode({
  'devices': {
    'com.apple.CoreSimulator.SimRuntime.iOS-26-0': [
      {
        'udid': _simUdid,
        'name': 'iPhone 18 Pro',
        'state': 'Booted',
        'isAvailable': true,
      },
    ],
  },
});

final _devicectlJson = json.encode({
  'result': {
    'devices': [
      {
        'identifier': 'CORE-DEVICE-UUID',
        'connectionProperties': {'transportType': 'wired'},
        'hardwareProperties': {'udid': '00008101-001C'},
        'deviceProperties': {'name': "Aran's iPhone"},
      },
    ],
  },
});

const _adbOutput =
    'List of devices attached\n'
    'emulator-5554          device product:sdk_gphone64_arm64 '
    'model:sdk_gphone64_arm64 device:emu64a transport_id:1\n';

/// Answers the three lookups as a host with one of each device would.
///
/// [fail] names lookups (`simctl`, `devicectl`, `adb`) that throw instead, the
/// way the bounded runner does for a tool that is missing or does not answer.
({ProcessRunSync run, List<List<String>> calls}) _fakeHost({
  Set<String> fail = const {},
}) {
  final calls = <List<String>>[];
  Future<ProcessResult> run(String exe, List<String> args) async {
    calls.add([exe, ...args]);
    final which = args.contains('simctl')
        ? 'simctl'
        : args.contains('devicectl')
        ? 'devicectl'
        : 'adb';
    if (fail.contains(which)) {
      throw StateError('`$exe` did not answer within 3000ms and was killed.');
    }
    switch (which) {
      case 'simctl':
        return ProcessResult(1, 0, _simctlJson, '');
      case 'devicectl':
        File(args.last).writeAsStringSync(_devicectlJson);
        return ProcessResult(2, 0, '', '');
      default:
        return ProcessResult(3, 0, _adbOutput, '');
    }
  }

  return (run: run, calls: calls);
}

Matcher _refusal(Object message) => isA<DevToolException>().having(
  (e) => e.message,
  'message',
  message,
);

void main() {
  group('resolveDevices', () {
    test('returns auto-detected device when no IDs given', () async {
      expect(await resolveDevices([]), hasLength(1));
    });

    test('resolves each keyword to its device kind', () async {
      final devices = await resolveDevices([
        'macos',
        'linux',
        'windows',
        'chrome',
        'ios-simulator',
        'ios',
        'android',
      ]);
      expect(devices[0], isA<MacOSDevice>());
      expect(devices[1], isA<LinuxDevice>());
      expect(devices[2], isA<WindowsDevice>());
      expect(devices[3], isA<WebDevice>());
      expect(devices[4], isA<IOSSimulatorDevice>());
      expect(devices[5], isA<IOSDevice>());
      expect((devices[6] as AndroidDevice).deviceId, isNull);
    });

    test(
      'resolves ios-simulator:UDID to IOSSimulatorDevice with udid',
      () async {
        final device = (await resolveDevices(['ios-simulator:ABC-123'])).single;
        expect((device as IOSSimulatorDevice).udid, 'ABC-123');
      },
    );

    test('resolves ios:UDID to IOSDevice with udid', () async {
      final device = (await resolveDevices(['ios:ABC-123'])).single;
      expect((device as IOSDevice).udid, 'ABC-123');
    });

    test('resolves android:SERIAL to the bare serial', () async {
      // The prefix must not survive into `adb -s`. A colon there means a network
      // device, so the server reads the serial as `android` and the rest as a
      // service name and answers `unknown host service '<serial>:features'` —
      // an error naming neither the device id nor the flag that produced it,
      // for a device the same `adb` installs to by hand.
      final device = (await resolveDevices(['android:58051JEBF01271'])).single;
      expect((device as AndroidDevice).deviceId, '58051JEBF01271');
    });

    test('resolving known forms asks no other tool', () async {
      final host = _fakeHost();
      await resolveDevices(
        [
          'macos',
          'ios-simulator:$_simUdid',
          'android:emulator-5554',
        ],
        runProbe: host.run,
        adbPath: '/fake/adb',
      );
      expect(host.calls, isEmpty);
    });

    test('refuses a prefix with nothing after it', () async {
      await expectLater(
        resolveDevices(['ios-simulator:'], runProbe: _fakeHost().run),
        throwsA(
          _refusal(contains('-d ios-simulator for the one that is booted')),
        ),
      );
    });
  });

  group('resolveDevices refuses an id that names no device kind', () {
    test('a bare simulator UDID, naming the simulator and its form', () async {
      final host = _fakeHost();
      await expectLater(
        resolveDevices([_simUdid], runProbe: host.run, adbPath: '/fake/adb'),
        throwsA(
          _refusal(
            allOf(
              contains("is the iOS simulator 'iPhone 18 Pro' (Booted)"),
              contains('pass -d ios-simulator:$_simUdid'),
            ),
          ),
        ),
      );
      // All three were asked, which is what lets a UDID that two tools know be
      // reported as ambiguous rather than as the first one found.
      expect(host.calls.map((c) => c.take(2).join(' ')), {
        'xcrun simctl',
        'xcrun devicectl',
        '/fake/adb devices',
      });
    });

    test('a bare Android serial, even one adb lists', () async {
      await expectLater(
        resolveDevices(
          ['emulator-5554'],
          runProbe: _fakeHost().run,
          adbPath: '/fake/adb',
        ),
        throwsA(
          _refusal(
            allOf(
              contains("the Android device 'sdk_gphone64_arm64' (device)"),
              contains('pass -d android:emulator-5554'),
            ),
          ),
        ),
      );
    });

    test('an iOS device by either of its identifiers', () async {
      for (final id in ['00008101-001C', 'CORE-DEVICE-UUID']) {
        await expectLater(
          resolveDevices([id], runProbe: _fakeHost().run, adbPath: '/fake/adb'),
          throwsA(
            _refusal(
              allOf(
                contains("the iOS device 'Aran's iPhone' (wired)"),
                contains('pass -d ios:$id'),
              ),
            ),
          ),
        );
      }
    });

    test('a misspelled prefix, by what follows it', () async {
      await expectLater(
        resolveDevices(
          ['ios-simulater:$_simUdid'],
          runProbe: _fakeHost().run,
          adbPath: '/fake/adb',
        ),
        throwsA(_refusal(contains('pass -d ios-simulator:$_simUdid'))),
      );
    });

    test('an id nothing knows, with every form it could take', () async {
      await expectLater(
        resolveDevices(
          ['emulator-5556'],
          runProbe: _fakeHost().run,
          adbPath: '/fake/adb',
        ),
        throwsA(
          _refusal(
            allOf([
              contains(
                'No device that simctl or devicectl or adb lists has that id.',
              ),
              contains('-d android:emulator-5556'),
              contains('-d ios-simulator:emulator-5556'),
              contains('-d ios:emulator-5556'),
              contains('Accepted forms: macos, linux'),
            ]),
          ),
        ),
      );
    });

    test('says which lookups could not answer, and still refuses', () async {
      await expectLater(
        resolveDevices(
          ['emulator-5554'],
          runProbe: _fakeHost(fail: {'adb', 'devicectl'}).run,
          adbPath: '/fake/adb',
        ),
        throwsA(
          _refusal(
            allOf(
              contains('No device that simctl lists has that id.'),
              contains('devicectl, adb could not be asked'),
              contains('-d android:emulator-5554'),
            ),
          ),
        ),
      );
    });

    test('a tool exiting non-zero counts as not asked', () async {
      Future<ProcessResult> run(String exe, List<String> args) async =>
          ProcessResult(1, 72, '', 'xcrun: error: unable to find utility');
      await expectLater(
        resolveDevices(['x'], runProbe: run, adbPath: '/fake/adb'),
        throwsA(
          _refusal(
            allOf(
              contains('simctl, devicectl, adb could not be asked'),
              isNot(contains('No device that')),
            ),
          ),
        ),
      );
    });

    test(
      'refuses every bad id at once, and keeps the good ones quiet',
      () async {
        await expectLater(
          resolveDevices(
            ['macos', _simUdid, 'emulator-5554'],
            runProbe: _fakeHost().run,
            adbPath: '/fake/adb',
          ),
          throwsA(
            _refusal(
              allOf(
                contains('-d ios-simulator:$_simUdid'),
                contains('-d android:emulator-5554'),
                isNot(contains('-d macos does not')),
              ),
            ),
          ),
        );
      },
    );
  });
}
