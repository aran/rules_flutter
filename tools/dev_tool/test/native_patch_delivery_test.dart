import 'dart:io';

import 'package:flutter_bazel_dev_tool/native_patch_delivery.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late List<String> commands;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('npd_test');
    commands = [];
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  File patch() =>
      File('${tmp.path}/libmul_patch.dylib')..writeAsStringSync('p');

  DeliveryProcessRunner recording({
    Map<String, ProcessResult> answers = const {},
    void Function(List<String> args)? sideEffect,
  }) => (exe, args) async {
    final line = '$exe ${args.join(' ')}';
    commands.add(line);
    sideEffect?.call(args);
    for (final entry in answers.entries) {
      if (line.contains(entry.key)) return entry.value;
    }
    return ProcessResult(1, 0, '', '');
  };

  test('an iOS framework is named the way the bundler names it', () {
    expect(iosFrameworkName('libmul.dylib'), 'mul');
    expect(iosFrameworkName('objective_c.dylib'), 'objective_c');
    expect(iosFrameworkName('foo.bar.dylib'), 'foobar');
    expect(iosFrameworkName('libfoo'), 'libfoo');
  });

  test('macOS copies into the directory the app named', () async {
    const delivery = MacOSPatchDelivery();
    expect(
      delivery.libraryLoadPath('libmul.dylib'),
      '@executable_path/../Frameworks/libmul.dylib',
    );
    final appDirectory = Directory('${tmp.path}/container/tmp')
      ..createSync(recursive: true);
    final path = await delivery.deliver(
      localFile: patch().path,
      appDirectory: appDirectory.path,
      name: 'patch1.libmul.dylib',
    );
    expect(path, '${appDirectory.path}/patch1.libmul.dylib');
    expect(File(path).readAsStringSync(), 'p');
  });

  test('the simulator copies, then signs ad hoc', () async {
    final delivery = IOSSimulatorPatchDelivery(run: recording());
    expect(
      delivery.libraryLoadPath('libmul.dylib'),
      '@executable_path/Frameworks/mul.framework/mul',
    );
    final path = await delivery.deliver(
      localFile: patch().path,
      appDirectory: tmp.path,
      name: 'patch1.libmul.dylib',
    );
    expect(commands, ['codesign --force --sign - $path']);
  });

  group('a physical iOS device', () {
    test('addresses the copy relative to the app data container', () {
      expect(
        IOSDevicePatchDelivery.containerRelative(
          '/private/var/mobile/Containers/Data/Application/'
          '1A2B-3C/tmp/flutter_hot_patch',
        ),
        'tmp/flutter_hot_patch',
      );
      expect(
        () => IOSDevicePatchDelivery.containerRelative('/tmp/x'),
        throwsA(isA<NativePatchDeliveryException>()),
      );
    });

    test(
      'signs with the hash of the app\'s own certificate, then copies',
      () async {
        final delivery = IOSDevicePatchDelivery(
          udid: '00008101-001C',
          bundleId: 'com.example.ffi',
          appPath: '/build/Runner.app',
          run: recording(
            answers: {
              'shasum': ProcessResult(1, 0, 'ab12cd34ef  /tmp/cert0\n', ''),
            },
            // `codesign --extract-certificates=<prefix>` writes <prefix>0, the
            // leaf.
            sideEffect: (args) {
              for (final arg in args) {
                if (arg.startsWith('--extract-certificates=')) {
                  File('${arg.split('=').last}0').writeAsStringSync('der');
                }
              }
            },
          ),
        );
        const appDirectory =
            '/private/var/mobile/Containers/Data/Application/1A2B/tmp/hot';
        final path = await delivery.deliver(
          localFile: patch().path,
          appDirectory: appDirectory,
          name: 'patch1.libmul.dylib',
        );
        expect(path, '$appDirectory/patch1.libmul.dylib');
        expect(commands, hasLength(4));
        expect(
          commands[0],
          startsWith('codesign --display --extract-certificates='),
        );
        expect(commands[0], endsWith(' /build/Runner.app'));
        expect(commands[1], startsWith('shasum -a 1 '));
        expect(commands[2], startsWith('codesign --force --sign AB12CD34EF '));
        expect(
          commands[3],
          allOf(
            startsWith(
              'xcrun devicectl device copy to --device 00008101-001C '
              '--domain-type appDataContainer --domain-identifier '
              'com.example.ffi --source ',
            ),
            endsWith(' --destination tmp/hot/patch1.libmul.dylib'),
          ),
        );

        // The identity is read once per run, not once per patch.
        commands.clear();
        await delivery.deliver(
          localFile: patch().path,
          appDirectory: appDirectory,
          name: 'patch2.libmul.dylib',
        );
        expect(commands.map((c) => c.split(' ').first), ['codesign', 'xcrun']);
      },
    );

    test('an unsigned app has no identity to lend a patch', () async {
      final delivery = IOSDevicePatchDelivery(
        udid: 'u',
        bundleId: 'b',
        appPath: '/build/Runner.app',
        run: recording(),
      );
      await expectLater(
        delivery.deliver(
          localFile: patch().path,
          appDirectory: '/x/Containers/Data/Application/A/tmp',
          name: 'p',
        ),
        throwsA(
          isA<NativePatchDeliveryException>().having(
            (e) => e.message,
            'message',
            contains('carries no signing certificate'),
          ),
        ),
      );
    });
  });

  group('Android', () {
    AndroidPatchDelivery android({
      Map<String, ProcessResult> answers = const {},
    }) => AndroidPatchDelivery(
      packageName: 'com.example.app',
      adb: '/sdk/adb',
      adbPrefix: const ['-s', 'emulator-5556'],
      run: recording(answers: answers),
    );

    test('loads a library by the name the app already has it by', () {
      expect(android().libraryLoadPath('libmul.so'), 'libmul.so');
    });

    test('pushes, copies in as the app, and cleans up', () async {
      final path = await android().deliver(
        localFile: '/out/libmul_patch.so',
        appDirectory: '/data/user/0/com.example.app/code_cache/hot',
        name: 'patch1.libmul.so',
      );
      expect(
        path,
        '/data/user/0/com.example.app/code_cache/hot/patch1.libmul.so',
      );
      expect(commands, [
        '/sdk/adb -s emulator-5556 push /out/libmul_patch.so '
            '/data/local/tmp/patch1.libmul.so',
        '/sdk/adb -s emulator-5556 shell run-as com.example.app cp '
            '/data/local/tmp/patch1.libmul.so '
            '/data/user/0/com.example.app/code_cache/hot/patch1.libmul.so',
        '/sdk/adb -s emulator-5556 shell rm -f /data/local/tmp/patch1.libmul.so',
      ]);
    });

    test(
      'a copy the app\'s uid refuses is reported, and the push cleaned up',
      () async {
        await expectLater(
          android(
            answers: {
              'run-as': ProcessResult(
                1,
                1,
                '',
                'run-as: package not debuggable',
              ),
            },
          ).deliver(localFile: '/out/p.so', appDirectory: '/d', name: 'p.so'),
          throwsA(
            isA<NativePatchDeliveryException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('copy the patch into the app'),
                contains('package not debuggable'),
              ),
            ),
          ),
        );
        expect(commands.last, contains('rm -f /data/local/tmp/p.so'));
      },
    );
  });
}
