import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_bazel_dev_tool/bazel.dart';
import 'package:flutter_bazel_dev_tool/dev_tool_exception.dart';
import 'package:flutter_bazel_dev_tool/logging.dart';
import 'package:flutter_bazel_dev_tool/native_hot_patcher.dart';
import 'package:flutter_bazel_dev_tool/native_patch_delivery.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart' show RPCError;

/// A 64-bit Mach-O carrying only an `LC_UUID`, every byte of it [fill].
Uint8List machO(int fill) {
  final bytes = ByteData(32 + 24);
  bytes.setUint32(0, 0xfeedfacf, Endian.little);
  bytes.setUint32(16, 1, Endian.little);
  bytes.setUint32(32, 0x1b, Endian.little);
  bytes.setUint32(36, 24, Endian.little);
  final out = bytes.buffer.asUint8List();
  out.fillRange(40, 56, fill);
  return out;
}

class FakeDelivery extends NativePatchDelivery {
  final List<String> delivered = [];

  @override
  String libraryLoadPath(String libraryFileName) => 'open:$libraryFileName';

  @override
  Future<String> deliver({
    required String localFile,
    required String appDirectory,
    required String name,
  }) async {
    delivered.add('$localFile -> $appDirectory/$name');
    return '$appDirectory/$name';
  }
}

class FakeApp implements NativePatchTarget {
  @override
  final String appId;

  final FakeDelivery fakeDelivery = FakeDelivery();

  /// False for a device no patch can be delivered to.
  bool deliverable = true;

  @override
  FakeDelivery? get delivery => deliverable ? fakeDelivery : null;

  final List<String> calls = [];

  /// An extension call that should fail, with the agent's message.
  String? refuseApply;

  FakeApp(this.appId);

  @override
  Future<Map<String, dynamic>?> callExtension(
    String method,
    Map<String, String> args,
  ) async {
    calls.add('$method ${jsonEncode(args)}');
    switch (method) {
      case 'ext.rules_flutter.nativeSymbolAddress':
        return {'address': '0x1f00'};
      case 'ext.rules_flutter.nativePatchDirectory':
        return {'path': '/app/tmp'};
      case 'ext.rules_flutter.applyNativePatch':
        if (refuseApply != null) {
          throw RPCError.withDetails(
            method,
            -32602,
            'Invalid params',
            details: refuseApply,
          );
        }
        return {'applied': true};
    }
    throw StateError('unexpected $method');
  }
}

void main() {
  late Directory tmp;
  late String workspace;
  late String execRoot;
  late String appFile;
  late int builds;
  late List<String> builtFiles;
  late bool buildFails;
  late List<String> toolCalls;
  late String Function(List<String> args) toolAnswer;
  late List<FakeApp> apps;

  /// A manifest for `libmul.dylib` built into [config], with that build's
  /// identity [fill].
  String declare(String config, int fill) {
    final bin = Directory('$execRoot/bazel-out/$config/bin')
      ..createSync(recursive: true);
    File('${bin.path}/libmul.dylib').writeAsBytesSync(machO(fill));
    final manifest = File('${bin.path}/mul.hot_patch.json')
      ..writeAsStringSync(
        jsonEncode({
          'version': 1,
          'library': 'bazel-out/$config/bin/libmul.dylib',
          'sources': ['native/mul.c'],
          'command': ['tool', config],
        }),
      );
    return manifest.path;
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('nhp_test');
    workspace = '${tmp.path}/ws';
    execRoot = '${tmp.path}/exec';
    File('$workspace/native/mul.c')
      ..createSync(recursive: true)
      ..writeAsStringSync('int mul() { return 1; }');
    appFile = '${tmp.path}/app.app';
    File('$appFile/Contents/Frameworks/libmul.dylib')
      ..createSync(recursive: true)
      ..writeAsBytesSync(machO(0xaa));
    builds = 0;
    builtFiles = [];
    buildFails = false;
    toolCalls = [];
    toolAnswer = (args) => args.contains('snapshot')
        ? '{"status":"ok"}'
        : '{"status":"patched","file":"/out/libmul_patch.dylib","functions":["mul_body"]}';
    apps = [FakeApp('app1')];
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  Future<NativeHotPatcher?> arm() => NativeHotPatcher.arm(
    workspace: workspace,
    build: () async {
      builds++;
      return BazelAspectOutputs(
        exitCode: buildFails ? 1 : 0,
        files: buildFails ? const [] : builtFiles,
        executionRoot: buildFails ? null : execRoot,
        stderr: buildFails ? 'ERROR: mul.c:3: expected ;' : '',
      );
    },
    appFile: appFile,
    targets: () => apps,
    logger: Logger('test'),
    scratch: Directory('${tmp.path}/scratch')..createSync(),
    runTool: (exe, args, {required workingDirectory}) async {
      toolCalls.add('$exe ${args.join(' ')}');
      return ProcessResult(1, 0, toolAnswer(args), '');
    },
  );

  /// An edit a stat can see: a different size.
  void editSource() => File(
    '$workspace/native/mul.c',
  ).writeAsStringSync('int mul() { return ${DateTime.now().microsecond}2; }');

  group('arming', () {
    test('an app with no patch builder has no patcher', () async {
      expect(await arm(), isNull);
    });

    test('snapshots only the build the app is running', () async {
      // The same library in two configurations, as a platform rule's own
      // transition produces; only the second carries the bundled identity.
      builtFiles = [declare('top', 0x11), declare('top-ST-abc', 0xaa)];
      final patcher = await arm();
      expect(patcher!.libraries, ['libmul.dylib']);
      expect(toolCalls, hasLength(1));
      expect(toolCalls.single, startsWith('tool top-ST-abc snapshot --state '));
    });

    test(
      'refuses, naming both sides, when no build is the running one',
      () async {
        builtFiles = [declare('top', 0x11)];
        await expectLater(
          arm(),
          throwsA(
            isA<DevToolException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('None of the 1 build(s) of libmul.dylib'),
                contains('uuid:${'aa' * 16}'),
                contains('uuid:${'11' * 16}'),
                contains('need a hot restart'),
              ),
            ),
          ),
        );
      },
    );

    test('an app on a device no patch can reach is said at launch', () async {
      builtFiles = [declare('st', 0xaa)];
      apps = [FakeApp('linux')..deliverable = false];
      await expectLater(
        arm(),
        throwsA(
          isA<DevToolException>().having(
            (e) => e.message,
            'message',
            allOf(contains('linux runs on a device'), contains('hot restart')),
          ),
        ),
      );
    });

    test('a library declared but not bundled is not armed', () async {
      final bin = Directory('$execRoot/bazel-out/k/bin')
        ..createSync(recursive: true);
      File('${bin.path}/libother.dylib').writeAsBytesSync(machO(1));
      File('${bin.path}/other.hot_patch.json').writeAsStringSync(
        jsonEncode({
          'version': 1,
          'library': 'bazel-out/k/bin/libother.dylib',
          'sources': ['native/mul.c'],
          'command': ['tool'],
        }),
      );
      builtFiles = ['${bin.path}/other.hot_patch.json'];
      expect(await arm(), isNull);
    });
  });

  group('a reload', () {
    late NativeHotPatcher patcher;

    setUp(() async {
      builtFiles = [declare('st', 0xaa)];
      patcher = (await arm())!;
      builds = 0;
      toolCalls.clear();
    });

    test('with no native source moved costs no build', () async {
      expect(await patcher.patchIfMoved(), isA<NativePatchNotNeeded>());
      expect(builds, 0);
    });

    test('with a source moved builds, patches and loads it', () async {
      editSource();
      final outcome = await patcher.patchIfMoved();
      expect(
        outcome,
        isA<NativePatched>().having((o) => o.functions, 'functions', {
          'libmul.dylib': ['mul_body'],
        }),
      );
      expect(builds, 1);
      expect(toolCalls.single, contains('patch --state'));
      expect(
        toolCalls.single,
        contains('--symbol flutter_hot_patch_apply=0x1f00'),
      );
      final app = apps.single;
      expect(app.fakeDelivery.delivered, [
        '/out/libmul_patch.dylib -> /app/tmp/patch1.libmul.dylib',
      ]);
      expect(
        app.calls.last,
        'ext.rules_flutter.applyNativePatch '
        '{"library":"open:libmul.dylib","patch":"/app/tmp/patch1.libmul.dylib"}',
      );

      // Delivered, so the next reload with nothing new is free again.
      builds = 0;
      expect(await patcher.patchIfMoved(), isA<NativePatchNotNeeded>());
      expect(builds, 0);
    });

    test('every delivery gets a name its loader has never opened', () async {
      editSource();
      await patcher.patchIfMoved();
      editSource();
      await patcher.patchIfMoved();
      expect(apps.single.fakeDelivery.delivered.map((d) => d.split('/').last), [
        'patch1.libmul.dylib',
        'patch2.libmul.dylib',
      ]);
    });

    test('a library the reload\'s own rebuild moved is patched too', () async {
      final outcome = await patcher.patchIfMoved(
        movedLibraries: {'libmul.dylib'},
      );
      expect(outcome, isA<NativePatched>());
      expect(builds, 1);
    });

    test(
      'an edit that needs a restart delivers nothing and is asked again',
      () async {
        toolAnswer = (_) =>
            '{"status":"restart","reasons":["native/mul.h changed"]}';
        editSource();
        expect(
          await patcher.patchIfMoved(),
          isA<NativePatchNeedsRestart>().having((o) => o.reasons, 'reasons', {
            'libmul.dylib': ['native/mul.h changed'],
          }),
        );
        expect(apps.single.fakeDelivery.delivered, isEmpty);
        // Not recorded as delivered: the next reload still owes the answer.
        builds = 0;
        expect(await patcher.patchIfMoved(), isA<NativePatchNeedsRestart>());
        expect(builds, 1);
      },
    );

    test('a broken build is reported with what bazel said', () async {
      buildFails = true;
      editSource();
      expect(
        await patcher.patchIfMoved(),
        isA<NativePatchBuildFailed>().having(
          (o) => o.message,
          'message',
          contains('expected ;'),
        ),
      );
      expect(toolCalls, isEmpty);
    });

    test('an edit undone after its patch sends calls back to the launched '
        'code', () async {
      editSource();
      expect(await patcher.patchIfMoved(), isA<NativePatched>());
      toolAnswer = (_) => '{"status":"unchanged"}';
      editSource();
      expect(
        await patcher.patchIfMoved(),
        isA<NativePatched>().having((o) => o.reverted, 'reverted', [
          'libmul.dylib',
        ]),
      );
      expect(
        apps.single.calls.last,
        'ext.rules_flutter.applyNativePatch {"library":"open:libmul.dylib"}',
      );
      // Nothing is live any more, so an unchanged answer is nothing to do.
      editSource();
      expect(await patcher.patchIfMoved(), isA<NativePatchNotNeeded>());
    });

    test('a patch an app refuses is a load failure naming the app', () async {
      apps = [
        FakeApp('ok'),
        FakeApp('bad')..refuseApply = 'missing code signature',
      ];
      editSource();
      expect(
        await patcher.patchIfMoved(),
        isA<NativePatchLoadFailed>()
            .having((o) => o.applied, 'applied', ['ok'])
            .having(
              (o) => o.failures,
              'failures',
              {'bad': contains('missing code signature')},
            ),
      );
    });

    test(
      'an app that cannot receive a patch is never counted as patched',
      () async {
        apps.add(FakeApp('late')..deliverable = false);
        editSource();
        expect(
          await patcher.patchIfMoved(),
          isA<NativePatchLoadFailed>().having(
            (o) => o.failures.keys,
            'failures',
            ['late'],
          ),
        );
        // Not recorded as delivered.
        builds = 0;
        apps.removeLast();
        expect(await patcher.patchIfMoved(), isA<NativePatched>());
        expect(builds, 1);
      },
    );

    test('a relaunch re-snapshots and forgets what was live', () async {
      editSource();
      await patcher.patchIfMoved();
      toolCalls.clear();
      await patcher.rebaseline();
      expect(toolCalls.single, contains('snapshot'));
      toolAnswer = (_) => '{"status":"unchanged"}';
      editSource();
      // The new process never had the patch, so there is nothing to revert.
      expect(await patcher.patchIfMoved(), isA<NativePatchNotNeeded>());
    });
  });
}
