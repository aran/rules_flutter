/// The emulator an Android integration test boots is the test's own: it takes
/// ports no other test holds, answers to an `adb` server of its own that sees
/// no attached phone, is booted before the app is installed, and is shut down
/// with its server however the test ends. One a killed run left is stopped by
/// the next run that takes its ports. A host without a hypervisor fails the
/// test saying how to give it one.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/integration/test_emulator.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fakes.dart';

/// A lock file another process holds: every attempt to take it fails.
class _Held implements RandomAccessFile {
  var closed = false;

  @override
  Future<RandomAccessFile> lock([
    FileLock mode = FileLock.exclusive,
    int start = 0,
    int end = -1,
  ]) async => throw const FileSystemException('held by another process');

  @override
  Future<void> close() async => closed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// A recorder of the processes a run runs, answering as [reply] says.
class _Runs {
  _Runs([ProcessResult Function(String exe, List<String> args)? reply])
    : _reply = reply ?? ((_, _) => ProcessResult(0, 0, '', ''));

  final ProcessResult Function(String exe, List<String> args) _reply;
  final calls = <(String, List<String>, Map<String, String>)>[];

  Future<ProcessResult> call(
    String exe,
    List<String> args,
    Map<String, String> environment,
  ) async {
    calls.add((exe, args, environment));
    return _reply(exe, args);
  }

  List<List<String>> get arguments => [for (final c in calls) c.$2];
}

const _settings = EmulatorSettings(
  executable: '/runfiles/emu/emulator/emulator',
  systemImage: '/runfiles/image/source.properties',
  abi: 'arm64-v8a',
  apiLevel: 35,
  tag: 'aosp_atd',
  cores: 2,
  memoryMb: 2048,
);

Future<bool> _allFree(int _) async => true;

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('test_emulator_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<EmulatorPorts> take({
    Future<bool> Function(int port) isFree = _allFree,
    Future<void> Function(EmulatorRecord record)? reclaim,
    List<String>? log,
    Set<int> held = const {},
  }) => EmulatorPorts.take(
    lockDirectory: dir,
    isFree: isFree,
    reclaim: reclaim ?? (_) async => fail('nothing is left to reclaim'),
    log: (message) => log?.add(message),
    open: (path) async {
      for (final console in held) {
        if (path.endsWith('android-emulator-$console.lock')) return _Held();
      }
      return File(path).open(mode: FileMode.append);
    },
  );

  group('the ports of a test\'s emulator', () {
    test('are the first pair of the ones adb knows emulators by, with an adb '
        'server port of their own', () async {
      final ports = await take();

      expect(ports.console, 5554);
      expect(ports.adb, 5555);
      expect(ports.server, 5700);
      expect(ports.serial, 'emulator-5554');
      expect(File('${dir.path}/android-emulator-5554.lock').existsSync(), true);
      await ports.release();
    });

    test('pass over a pair another test holds', () async {
      final ports = await take(held: {5554});

      expect(ports.console, 5556);
      expect(ports.server, 5701);
      await ports.release();
    });

    test('pass over a pair something else listens on', () async {
      final ports = await take(isFree: (port) async => port != 5555);

      expect(ports.console, 5556);
      await ports.release();
    });

    test('stop what a killed run left on them before they are used, and '
        'say so', () async {
      File('${dir.path}/android-emulator-5554.json').writeAsStringSync(
        json.encode({'pid': 4242, 'startedAt': 1700000000, 'server': 5700}),
      );
      final reclaimed = <EmulatorRecord>[];
      final log = <String>[];

      final ports = await take(
        reclaim: (record) async => reclaimed.add(record),
        log: log,
      );

      expect(ports.console, 5554);
      expect(reclaimed.single.pid, 4242);
      expect(reclaimed.single.startedAt, 1700000000);
      expect(reclaimed.single.server, 5700);
      expect(log.single, contains('process 4242'));
      expect(
        File('${dir.path}/android-emulator-5554.json').existsSync(),
        false,
      );
      await ports.release();
    });

    test('record what the run started, and forget it when given up', () async {
      final ports = await take();
      final record = File('${dir.path}/android-emulator-5554.json');

      ports.record(99, 1700000001);
      expect(json.decode(record.readAsStringSync()), {
        'pid': 99,
        'startedAt': 1700000001,
        'server': 5700,
      });
      await ports.release();
      expect(record.existsSync(), false);
    });

    test('are refused, naming what to do, when every pair is taken', () async {
      final every = {
        for (var slot = 0; slot < emulatorSlots; slot++)
          EmulatorPorts.consolePortOf(slot),
      };

      await expectLater(
        take(held: every),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('all 16'), contains('--local_test_jobs')),
          ),
        ),
      );
    });
  });

  group('what a killed run left', () {
    test('is killed when its process is still the one that started, and its '
        'adb server is stopped', () async {
      final killed = <int>[];
      final runs = _Runs();
      // What `ps` says below, in the local time zone it says it in.
      final started =
          DateTime(2025, 11, 6, 10, 25, 55).millisecondsSinceEpoch ~/ 1000;

      await reclaimEmulator(
        EmulatorRecord(4242, started, 5703),
        adb: '/sdk/adb',
        adbEnvironment: const {'ADB_USB': '0'},
        ps: (_, _) async =>
            ProcessResult(0, 0, 'Thu Nov  6 10:25:55 2025\n', ''),
        run: runs.call,
        kill: (pid, signal) {
          expect(signal, ProcessSignal.sigkill);
          killed.add(pid);
          return true;
        },
      );

      expect(killed, [4242]);
      expect(runs.arguments, [
        ['-P', '5703', 'kill-server'],
      ]);
    });

    test('is left alone when its process id is another process\'s now, but '
        'its adb server is stopped', () async {
      final runs = _Runs();

      await reclaimEmulator(
        const EmulatorRecord(4242, 1, 5703),
        adb: '/sdk/adb',
        adbEnvironment: const {},
        ps: (_, _) async =>
            ProcessResult(0, 0, 'Thu Nov  6 10:25:55 2025\n', ''),
        run: runs.call,
        kill: (_, _) => fail('another process is not killed'),
      );

      expect(runs.arguments, [
        ['-P', '5703', 'kill-server'],
      ]);
    });
  });

  group('the host\'s hypervisor', () {
    test('is enough when the emulator says it can use it', () async {
      final runs = _Runs(
        (_, _) => ProcessResult(
          0,
          0,
          'accel:\n0\nHypervisor.Framework OS X Version 27.2\naccel\n',
          '',
        ),
      );

      await checkAcceleration(
        emulator: '/e/emulator',
        environment: const {},
        os: 'macos',
        run: runs.call,
      );
      expect(runs.arguments, [
        ['-accel-check'],
      ]);
    });

    test('missing fails the test, saying what the emulator said and how to '
        'give it KVM', () async {
      final runs = _Runs(
        (_, _) => ProcessResult(
          0,
          0,
          'accel:\n7\n/dev/kvm is not found: VT disabled in BIOS or KVM '
              'kernel module not loaded\naccel\n',
          '',
        ),
      );

      await expectLater(
        checkAcceleration(
          emulator: '/e/emulator',
          environment: const {},
          os: 'linux',
          run: runs.call,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('/dev/kvm is not found'),
              contains('it needs KVM'),
              contains('android_device=attached'),
            ),
          ),
        ),
      );
    });
  });

  group('the device the emulator boots', () {
    test('is laid out with the emulator and the image where the emulator looks '
        'for them', () {
      final scratch = EmulatorScratch(p.join(dir.path, 'scratch'));
      final image = Directory(p.join(dir.path, 'image'))..createSync();
      final emulator = Directory(p.join(dir.path, 'emu'))..createSync();
      final settings = EmulatorSettings(
        executable: p.join(emulator.path, 'emulator'),
        systemImage: p.join(image.path, 'source.properties'),
        abi: 'x86_64',
        apiLevel: 35,
        tag: 'aosp_atd',
        cores: 2,
        memoryMb: 2048,
      );

      layOutEmulator(scratch, settings);

      expect(Link(p.join(scratch.sdk, 'emulator')).targetSync(), emulator.path);
      expect(
        Link(
          p.join(
            scratch.sdk,
            'system-images/android-35/aosp_atd/x86_64',
          ),
        ).targetSync(),
        image.path,
      );
      expect(
        Directory(p.join(scratch.sdk, 'platform-tools')).existsSync(),
        true,
      );
      final ini = File(
        p.join(scratch.avdHome, 'rules_flutter_test.ini'),
      ).readAsStringSync();
      expect(ini, contains('target=android-35'));
      final config = File(
        p.join(scratch.avdHome, 'rules_flutter_test.avd', 'config.ini'),
      ).readAsStringSync();
      expect(config, contains('abi.type=x86_64\n'));
      expect(config, contains('hw.cpu.arch=x86_64\n'));
      expect(
        config,
        contains('image.sysdir.1=system-images/android-35/aosp_atd/x86_64/\n'),
      );
    });

    test('is an arm64 device of the cores and memory asked for', () {
      final config = avdConfig(_settings);

      expect(config, contains('hw.cpu.arch=arm64\n'));
      expect(config, contains('hw.cpu.ncore=2\n'));
      expect(config, contains('hw.ramSize=2048\n'));
    });
  });

  group('the emulator\'s environment', () {
    test(
      'is its own SDK root, home and adb server, takes nothing of the '
      'host\'s Android settings, and has only /usr/bin and /bin on its PATH',
      () {
        final scratch = EmulatorScratch('/t/emu');

        final env = emulatorEnvironment(
          base: const {
            'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
            'LD_LIBRARY_PATH': '/runtime/lib',
            'ANDROID_HOME': '/sdk',
            'ANDROID_SERIAL': 'phone',
          },
          scratch: scratch,
          server: 5701,
        );

        final home = p.join('/t/emu', 'emulator_home');
        expect(env, {
          'LD_LIBRARY_PATH': '/runtime/lib',
          'PATH': '/usr/bin:/bin',
          'HOME': home,
          'TMPDIR': p.join('/t/emu', 'tmp'),
          'ANDROID_SDK_ROOT': p.join('/t/emu', 'sdk'),
          'ANDROID_AVD_HOME': p.join('/t/emu', 'avd'),
          'ANDROID_EMULATOR_HOME': home,
          'ANDROID_USER_HOME': home,
          'ANDROID_ADB_SERVER_PORT': '5701',
        });
      },
    );
  });

  group('the test\'s adb', () {
    test('is on its own port and home, off USB, the network and other '
        'emulators, and takes nothing of the host\'s Android settings', () {
      final scratch = EmulatorScratch('/t/emu');

      final env = adbEnvironment(
        host: const {
          'PATH': '/usr/bin',
          'ANDROID_SERIAL': 'phone',
          'ANDROID_HOME': '/sdk',
          'ADB_TRACE': 'all',
        },
        scratch: scratch,
        server: 5701,
      );

      expect(env, {
        'PATH': '/usr/bin',
        'HOME': p.join('/t/emu', 'home'),
        'ANDROID_USER_HOME': p.join('/t/emu', 'home', '.android'),
        'ANDROID_ADB_SERVER_PORT': '5701',
        'ADB_USB': '0',
        'ADB_EMU': '0',
        'ADB_MDNS': '0',
      });
    });
  });

  group('booting', () {
    late EmulatorPorts ports;
    setUp(() async => ports = await take());
    tearDown(() => ports.release());

    final scratch = EmulatorScratch('/t/emu');

    Future<TestEmulator> boot(
      FakeProcess process,
      _Runs runs, {
      List<String>? log,
    }) => TestEmulator.boot(
      settings: _settings,
      ports: ports,
      scratch: scratch,
      adb: '/sdk/adb',
      environment: const {'HOME': '/t/emu/home'},
      adbEnv: const {'ADB_USB': '0'},
      run: runs.call,
      start: (exe, args, env) async {
        expect(exe, _settings.executable);
        expect(args, emulatorArguments(ports));
        expect(env, {'HOME': '/t/emu/home'});
        return process;
      },
      ps: (_, _) async => ProcessResult(0, 0, 'Thu Nov  6 10:25:55 2025\n', ''),
      log: log?.add,
    );

    test('starts the test\'s adb server, then the emulator, and completes when '
        'the device has booted', () async {
      final process = FakeProcess();
      final runs = _Runs(
        (_, args) => ProcessResult(
          0,
          0,
          args.contains('getprop') ? '1\n' : '',
          '',
        ),
      );
      final log = <String>[];

      final booting = boot(process, runs, log: log);
      await process.outputAttached;
      process.emitStdout('INFO | Boot completed in 21000 ms');
      final emulator = await booting;

      expect(runs.arguments, [
        ['-P', '5700', 'start-server'],
        [
          '-P',
          '5700',
          '-s',
          'emulator-5554',
          'wait-for-device',
          'shell',
          'getprop',
          'sys.boot_completed',
        ],
      ]);
      expect(log.single, contains('booted the emulator emulator-5554'));
      expect(
        File('${dir.path}/android-emulator-5554.json').existsSync(),
        true,
        reason: 'what the run started is recorded for a later run to reclaim',
      );

      await emulator.stop();
      expect(process.signals, [ProcessSignal.sigterm]);
      expect(runs.arguments.last, ['-P', '5700', 'kill-server']);
    });

    test('keeps the device\'s log when it is stopped, before the device is '
        'gone', () async {
      final process = FakeProcess();
      final runs = _Runs(
        (_, args) => ProcessResult(
          0,
          0,
          args.contains('getprop')
              ? '1\n'
              : args.contains('logcat')
              ? 'I flutter: the app\'s last words\n'
              : '',
          '',
        ),
      );

      final booting = boot(process, runs);
      await process.outputAttached;
      process.emitStdout('INFO | Boot completed in 21000 ms');
      final emulator = await booting;
      final logcat = p.join(dir.path, 'logcat.txt');
      await emulator.stop(logcat: logcat);

      expect(
        File(logcat).readAsStringSync(),
        contains('the app\'s last words'),
      );
      final logcatAt = runs.arguments.indexWhere((a) => a.contains('logcat'));
      final killAt = runs.arguments.indexWhere(
        (a) => a.contains('kill-server'),
      );
      expect(runs.arguments[logcatAt], [
        '-P',
        '5700',
        '-s',
        'emulator-5554',
        'logcat',
        '-d',
      ]);
      expect(logcatAt, lessThan(killAt));
      expect(process.signals, [ProcessSignal.sigterm]);
    });

    test('fails with the emulator\'s last words when it exits before the '
        'device boots, and stops the adb server', () async {
      final process = FakeProcess();
      final runs = _Runs();

      final booting = boot(process, runs);
      await process.outputAttached;
      process.emitStderr('FATAL | Broken AVD system path\n');
      // The line is read before the exit is.
      await pumpEventQueue();
      process.complete(1);

      await expectLater(
        booting,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('exited 1'), contains('Broken AVD system path')),
          ),
        ),
      );
      expect(runs.arguments.last, ['-P', '5700', 'kill-server']);
    });

    test('fails, shutting the emulator down, when adb does not read the '
        'device as booted', () async {
      final process = FakeProcess();
      final runs = _Runs((_, args) => ProcessResult(0, 0, '\n', ''));

      final booting = boot(process, runs);
      await process.outputAttached;
      process.emitStdout('INFO | Boot completed in 21000 ms');

      await expectLater(
        booting,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('sys.boot_completed as ""'),
          ),
        ),
      );
      expect(process.signals, [ProcessSignal.sigterm]);
      expect(runs.arguments.last, ['-P', '5700', 'kill-server']);
    });
  });
}
