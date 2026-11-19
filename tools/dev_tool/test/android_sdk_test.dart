import 'dart:io';

import 'package:flutter_bazel_dev_tool/android_sdk.dart';
import 'package:flutter_bazel_dev_tool/dev_tool_exception.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _executionRoot = '/ob/execroot/_main';

/// What the cquery of the `host_tool` targets answers: their links, built for
/// the host.
const _cquery =
    '@@rules_flutter+//tools/dev_tool/android_sdk:aapt2 '
    'bazel-out/darwin_arm64-dbg/bin/external/rules_flutter+/tools/dev_tool/'
    'android_sdk/aapt2/aapt2_binary\n'
    '@@rules_flutter+//tools/dev_tool/android_sdk:adb '
    'bazel-out/darwin_arm64-dbg/bin/external/rules_flutter+/tools/dev_tool/'
    'android_sdk/adb/adb\n';

/// A bazel that answers each command from [answers], keyed by its first
/// argument, and records what it was asked.
class _FakeBazel {
  final Map<String, ProcessResult> answers;
  final calls = <List<String>>[];

  _FakeBazel(this.answers);

  Future<ProcessResult> run(
    List<String> args, {
    required String workingDirectory,
  }) async {
    calls.add(args);
    return answers[args.first] ?? ProcessResult(0, 0, '', '');
  }

  List<String> get commands => [for (final c in calls) c.first];
}

ProcessResult _ok(String stdout) => ProcessResult(0, 0, stdout, '');

void main() {
  group('WorkspaceAndroidSdk', () {
    test(
      'a workspace with no SDK is asked one query and builds nothing',
      () async {
        final bazel = _FakeBazel({'query': _ok('')});
        final sdk = WorkspaceAndroidSdk(workspace: '/ws', runBazel: bazel.run);
        expect(await sdk.find(), isNull);
        expect(bazel.commands, ['query']);
        await expectLater(
          sdk.require(),
          throwsA(
            isA<DevToolException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('this workspace has no Android SDK'),
                contains('hermetic_android_toolchains'),
                contains('ANDROID_HOME'),
              ),
            ),
          ),
        );
      },
    );

    test(
      'builds adb and aapt2 in the run\'s options, and finds them',
      () async {
        final bazel = _FakeBazel({
          'query': _ok('@androidsdk//:aapt2\n@androidsdk//:adb\n'),
          'cquery': _ok(_cquery),
          'info': _ok('$_executionRoot\n'),
        });
        const runFlags = ['-c', 'dbg', '--config=ci', '--copt=-O1'];
        final sdk = WorkspaceAndroidSdk(
          workspace: '/ws',
          runBazel: bazel.run,
          configFlags: ['--config=ci'],
          buildFlags: runFlags,
        );
        final tools = (await sdk.find())!;
        // Host paths: the cquery's execroot-relative path, under the root.
        expect(
          tools.adb,
          p.join(
            _executionRoot,
            'bazel-out/darwin_arm64-dbg/bin/external/'
            'rules_flutter+/tools/dev_tool/android_sdk/adb/adb',
          ),
        );
        expect(
          tools.aapt2,
          p.join(
            _executionRoot,
            'bazel-out/darwin_arm64-dbg/bin/external/'
            'rules_flutter+/tools/dev_tool/android_sdk/aapt2/aapt2_binary',
          ),
        );
        expect(bazel.commands, ['query', 'build', 'cquery', 'info']);
        // The query and `bazel info` take the configs alone: `bazel query`
        // refuses a build-only option such as `--copt`.
        expect(bazel.calls[0].skip(2), ['--config=ci']);
        expect(bazel.calls[3].skip(2), ['--config=ci']);
        // The build and the cquery are in exactly the run's options, so that
        // neither throws away the analysis of the app's build. The cquery reads
        // the files the build made.
        expect(bazel.calls[1], ['build', ...runFlags, ...androidSdkToolLabels]);
        expect(bazel.calls[2].sublist(2, 2 + runFlags.length), runFlags);
        expect(bazel.calls[2].skip(2 + runFlags.length), hasLength(2));
      },
    );

    test('asks once per run', () async {
      final bazel = _FakeBazel({
        'query': _ok('@androidsdk//:aapt2\n@androidsdk//:adb\n'),
        'cquery': _ok(_cquery),
        'info': _ok('$_executionRoot\n'),
      });
      final sdk = WorkspaceAndroidSdk(workspace: '/ws', runBazel: bazel.run);
      await sdk.find();
      await sdk.require();
      expect(bazel.commands, ['query', 'build', 'cquery', 'info']);
    });

    test('a failed build names the command and what bazel said', () async {
      final bazel = _FakeBazel({
        'query': _ok('@androidsdk//:aapt2\n@androidsdk//:adb\n'),
        'build': ProcessResult(0, 1, '', 'ERROR: licence not accepted'),
      });
      final sdk = WorkspaceAndroidSdk(workspace: '/ws', runBazel: bazel.run);
      await expectLater(
        sdk.find(),
        throwsA(
          isA<DevToolException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains("build the Android SDK's adb and aapt2"),
              contains('cd /ws && bazel build'),
              contains('ERROR: licence not accepted'),
            ),
          ),
        ),
      );
    });
  });

  group('androidSdkToolsFrom', () {
    test('reads Windows executables', () {
      final tools = androidSdkToolsFrom(
        cquery:
            '@@rules_flutter+//tools/dev_tool/android_sdk:aapt2 '
            'bazel-out/x64_windows-dbg/bin/aapt2/aapt2.exe\n'
            '@@rules_flutter+//tools/dev_tool/android_sdk:adb '
            'bazel-out/x64_windows-dbg/bin/adb/adb.exe\n',
        executionRoot: _executionRoot,
      );
      expect(tools.adb, endsWith('adb.exe'));
      expect(tools.aapt2, endsWith('aapt2.exe'));
    });

    test('refuses an answer missing a tool', () {
      expect(
        () => androidSdkToolsFrom(
          cquery:
              '@@rules_flutter+//tools/dev_tool/android_sdk:adb '
              'bazel-out/x/bin/adb/adb\n',
          executionRoot: _executionRoot,
        ),
        throwsA(isA<DevToolException>()),
      );
    });
  });
}
