import 'dart:async';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/bazel.dart';
import 'package:flutter_bazel_dev_tool/dev_tool_exception.dart';
import 'package:flutter_bazel_dev_tool/launch_bundle_parts.dart';
import 'package:flutter_bazel_dev_tool/web_bundle_facts.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fakes.dart';

/// A real `--build_event_json_file` stream, trimmed to the events the parser
/// reads: `bazel build //:ffi_macos -c dbg` with the hot patch aspect over
/// `e2e/ffi_example`, output base and workspace paths scrubbed.
const _hotPatchBuildEvents = [
  r'''{"id":{"workspace":{}},"workspaceInfo":{"localExecRoot":"/output_base/execroot/_main"}}''',
  r'''{"id":{"targetCompleted":{"label":"//:ffi_macos","configuration":{"id":"ded4a48995378b6e91c665930388fd27a68bc9ae052e68bda3b10a50d5a2def7"}}},"completed":{"success":true,"tag":["manual"]}}''',
  r'''{"id":{"namedSet":{"id":"0"}},"namedSetOfFiles":{"files":[{"name":"mul_hot_patch.hot_patch.json","uri":"file:///output_base/execroot/_main/bazel-out/darwin_arm64-dbg-macos-arm64-min10.14-ST-03fe10a2746b/bin/mul_hot_patch.hot_patch.json","pathPrefix":["bazel-out","darwin_arm64-dbg-macos-arm64-min10.14-ST-03fe10a2746b","bin"],"digest":"e816d563bb00d826870d8b5fac4b1cdb6bb96713d6e157d403cd0c1f1bf39710","length":"360"},{"name":"c_patch_tool","uri":"file:///output_base/execroot/_main/bazel-out/darwin_arm64-opt-exec/bin/c_patch_tool","pathPrefix":["bazel-out","darwin_arm64-opt-exec","bin"],"digest":"5917a8f9c6437120fcaae3c1aaeba7fa9febd97e7bac28780c7df71d672fe520","length":"5878880"},{"name":"libmul_patch.dylib","uri":"file:///output_base/execroot/_main/bazel-out/darwin_arm64-dbg-macos-arm64-min10.14-ST-03fe10a2746b/bin/libmul_patch.dylib","pathPrefix":["bazel-out","darwin_arm64-dbg-macos-arm64-min10.14-ST-03fe10a2746b","bin"],"digest":"c2a500134cb6a6ebd92e1b00b67acec836d10503b50f89c422240b43b104f33e","length":"16992"},{"name":"native/mul.h","uri":"file:///workspace/native/mul.h","digest":"56b8a1f81413ba96dfada5d7eb1d5b71075c00170177a83b97be02deaa4398c7","length":"422"}]}}''',
  r'''{"id":{"targetCompleted":{"label":"//:ffi_macos","aspect":"@@rules_flutter+//flutter:native_hot_patch.bzl%flutter_native_hot_patch_aspect","configuration":{"id":"ded4a48995378b6e91c665930388fd27a68bc9ae052e68bda3b10a50d5a2def7"}}},"completed":{"success":true,"outputGroup":[{"name":"flutter_native_hot_patch","fileSets":[{"id":"0"}]}]}}''',
];

/// The same build under remote execution with a remote cache and
/// `--remote_download_toplevel`, trimmed the same way. Every file —
/// sources and outputs that were downloaded alike — is reported by its
/// `bytestream://` address.
const _remoteHotPatchBuildEvents = [
  r'''{"id":{"workspace":{}},"workspaceInfo":{"localExecRoot":"/output_base/execroot/_main"}}''',
  r'''{"id":{"namedSet":{"id":"1"}},"namedSetOfFiles":{"files":[{"name":"mul_hot_patch.hot_patch.json","uri":"bytestream://localhost:8980/blobs/3ab92b2b27e1a0427ad708d8fc5d472b98442fce505dd6b6e949e95a003c79ce/387","pathPrefix":["bazel-out","darwin_arm64-dbg-macos-arm64-min12.0-ST-fea79f7fcfbc","bin"],"digest":"3ab92b2b27e1a0427ad708d8fc5d472b98442fce505dd6b6e949e95a003c79ce","length":"387"},{"name":"c_patch_tool","uri":"bytestream://localhost:8980/blobs/e6c21e54e0a95f1b60f7b3897f4e9848eb74b5ad8a6ac358596b5ac32a26bdc3/6377144","pathPrefix":["bazel-out","linux_cloud_arm64-opt-exec","bin"],"digest":"e6c21e54e0a95f1b60f7b3897f4e9848eb74b5ad8a6ac358596b5ac32a26bdc3","length":"6377144"},{"name":"libmul_patch.dylib","uri":"bytestream://localhost:8980/blobs/f6a7d85adb5497a099baeeeb0670f0e711e50560eb4ec27143f18d58ea820ac5/17040","pathPrefix":["bazel-out","darwin_arm64-dbg-macos-arm64-min12.0-ST-fea79f7fcfbc","bin"],"digest":"f6a7d85adb5497a099baeeeb0670f0e711e50560eb4ec27143f18d58ea820ac5","length":"17040"},{"name":"native/mul.h","uri":"bytestream://localhost:8980/blobs/56b8a1f81413ba96dfada5d7eb1d5b71075c00170177a83b97be02deaa4398c7/422","digest":"56b8a1f81413ba96dfada5d7eb1d5b71075c00170177a83b97be02deaa4398c7","length":"422"}]}}''',
  r'''{"id":{"namedSet":{"id":"2"}},"namedSetOfFiles":{"files":[{"name":"sub_hot_patch.hot_patch.json","uri":"bytestream://localhost:8980/blobs/89ecb240c85728fa727d386c0cf23a7add55c322d9d7ca1ed96bd251f651e64a/387","pathPrefix":["bazel-out","darwin_arm64-dbg-macos-arm64-min12.0-ST-fea79f7fcfbc","bin"],"digest":"89ecb240c85728fa727d386c0cf23a7add55c322d9d7ca1ed96bd251f651e64a","length":"387"},{"name":"c_patch_tool","uri":"bytestream://localhost:8980/blobs/e6c21e54e0a95f1b60f7b3897f4e9848eb74b5ad8a6ac358596b5ac32a26bdc3/6377144","pathPrefix":["bazel-out","linux_cloud_arm64-opt-exec","bin"],"digest":"e6c21e54e0a95f1b60f7b3897f4e9848eb74b5ad8a6ac358596b5ac32a26bdc3","length":"6377144"},{"name":"libsub_patch.dylib","uri":"bytestream://localhost:8980/blobs/64fe90f3b8e61a632f529fdc8fd27d267dde5eb25899745e72706b2d0a6dc636/17040","pathPrefix":["bazel-out","darwin_arm64-dbg-macos-arm64-min12.0-ST-fea79f7fcfbc","bin"],"digest":"64fe90f3b8e61a632f529fdc8fd27d267dde5eb25899745e72706b2d0a6dc636","length":"17040"},{"name":"native/sub.h","uri":"bytestream://localhost:8980/blobs/70a9ed1a77c10987fffc580e1b79e45900bbe24d1b690c2936be17cf276886a1/370","digest":"70a9ed1a77c10987fffc580e1b79e45900bbe24d1b690c2936be17cf276886a1","length":"370"}]}}''',
  r'''{"id":{"namedSet":{"id":"0"}},"namedSetOfFiles":{"fileSets":[{"id":"1"},{"id":"2"}]}}''',
  r'''{"id":{"targetCompleted":{"label":"//:ffi_macos","aspect":"@@rules_flutter+//flutter:native_hot_patch.bzl%flutter_native_hot_patch_aspect","configuration":{"id":"55bfdd55ec97cc29df1cb4d0d709d2b4dacc1438a419698e65a54c112f9ef207"}}},"completed":{"success":true,"outputGroup":[{"name":"flutter_native_hot_patch","fileSets":[{"id":"0"}]}]}}''',
];

void main() {
  group('devToolBazelFlags', () {
    test('passes each --config as --config=<name>, before the build args', () {
      expect(
        devToolBazelFlags(configs: ['a', 'b'], buildArgs: ['--jobs=4']),
        containsAllInOrder(['--config=a', '--config=b', '--jobs=4']),
      );
    });

    // The app this tool drives has to carry the support compiled in, and a
    // `.bazelrc` may turn it off for every other debug build. Bazel takes the
    // last value a flag is given, and a config expands where it is named, so
    // the flag goes after everything the user passed.
    test('turns the dev-tool support on after the user\'s own flags', () {
      final flags = devToolBazelFlags(
        configs: ['ci'],
        buildArgs: ['--@rules_flutter//flutter:dev_tool_support=false'],
      );
      expect(flags.last, '--@rules_flutter//flutter:dev_tool_support=true');
      expect(
        bazelBuildArgs('//app', compilationMode: 'dbg', extraArgs: flags),
        containsAllInOrder([
          '--config=ci',
          '--@rules_flutter//flutter:dev_tool_support=false',
          '--@rules_flutter//flutter:dev_tool_support=true',
        ]),
      );
    });

    test('reaches the build argv, next to -c', () {
      final flags = devToolBazelFlags(configs: ['a', 'b'], buildArgs: []);
      expect(
        bazelBuildArgs('//app', compilationMode: 'dbg', extraArgs: flags),
        containsAllInOrder(['-c', 'dbg', '--config=a', '--config=b']),
      );
    });
  });

  group('aspectOutputsFromBuildEvents', () {
    const aspect =
        '@rules_flutter//flutter:native_hot_patch.bzl%'
        'flutter_native_hot_patch_aspect';

    test(
      'reads the files an aspect put in a group, and the execution root',
      () {
        final outputs = aspectOutputsFromBuildEvents(
          _hotPatchBuildEvents.join('\n'),
          aspect: aspect,
          outputGroup: 'flutter_native_hot_patch',
        );
        expect(outputs.executionRoot, '/output_base/execroot/_main');
        expect(outputs.files, [
          '/output_base/execroot/_main/bazel-out/darwin_arm64-dbg-macos-arm64-min10.14-ST-03fe10a2746b/bin/libmul_patch.dylib',
          '/output_base/execroot/_main/bazel-out/darwin_arm64-dbg-macos-arm64-min10.14-ST-03fe10a2746b/bin/mul_hot_patch.hot_patch.json',
          '/output_base/execroot/_main/bazel-out/darwin_arm64-opt-exec/bin/c_patch_tool',
          '/output_base/execroot/_main/native/mul.h',
        ]);
      },
    );

    test('reads each of several groups an aspect filled apart', () {
      final events = [
        '{"id":{"workspace":{}},"workspaceInfo":{"localExecRoot":"/x/root"}}',
        '{"id":{"namedSet":{"id":"0"}},"namedSetOfFiles":{"files":[{"name":"assets/a.bin","uri":"file:///x/root/bazel-out/k/bin/assets/a.bin","pathPrefix":["bazel-out","k","bin"]}]}}',
        '{"id":{"namedSet":{"id":"1"}},"namedSetOfFiles":{"files":[{"name":"libx.so","uri":"file:///x/root/bazel-out/k/bin/libx.so","pathPrefix":["bazel-out","k","bin"]}]}}',
        '{"id":{"targetCompleted":{"label":"//:app","aspect":"@@rules_flutter+//flutter:a.bzl%an_aspect"}},"completed":{"outputGroup":[{"name":"assets","fileSets":[{"id":"0"}]},{"name":"libs","fileSets":[{"id":"1"}]}]}}',
      ];
      final outputs = aspectOutputsFromBuildEvents(
        events.join('\n'),
        aspect: '@rules_flutter//flutter:a.bzl%an_aspect',
        outputGroup: 'assets',
        otherGroups: ['libs'],
      );
      expect(outputs.filesByGroup, {
        'assets': ['/x/root/bazel-out/k/bin/assets/a.bin'],
        'libs': ['/x/root/bazel-out/k/bin/libx.so'],
      });
      expect(outputs.files, outputs.filesByGroup['assets']);
    });

    test('ignores another aspect\'s group and follows nested file sets', () {
      final events = [
        '{"id":{"workspace":{}},"workspaceInfo":{"localExecRoot":"/x/root"}}',
        '{"id":{"namedSet":{"id":"1"}},"namedSetOfFiles":{"files":[{"name":"b.json","uri":"file:///x/root/bazel-out/k/bin/b.json","pathPrefix":["bazel-out","k","bin"]}]}}',
        '{"id":{"namedSet":{"id":"0"}},"namedSetOfFiles":{"files":[{"name":"a.json","uri":"file:///x/root/bazel-out/k/bin/a.json","pathPrefix":["bazel-out","k","bin"]}],"fileSets":[{"id":"1"}]}}',
        '{"id":{"namedSet":{"id":"2"}},"namedSetOfFiles":{"files":[{"name":"other","uri":"file:///x/root/other"}]}}',
        '{"id":{"targetCompleted":{"label":"//:app","aspect":"@@rules_flutter+//flutter:dev_files.bzl%flutter_dev_files_aspect"}},"completed":{"outputGroup":[{"name":"flutter_native_hot_patch","fileSets":[{"id":"2"}]}]}}',
        '{"id":{"targetCompleted":{"label":"//:app","aspect":"@@rules_flutter+//flutter:native_hot_patch.bzl%flutter_native_hot_patch_aspect"}},"completed":{"outputGroup":[{"name":"flutter_native_hot_patch","fileSets":[{"id":"0"}]}]}}',
      ];
      final outputs = aspectOutputsFromBuildEvents(
        events.join('\n'),
        aspect: aspect,
        outputGroup: 'flutter_native_hot_patch',
      );
      expect(outputs.files, [
        '/x/root/bazel-out/k/bin/a.json',
        '/x/root/bazel-out/k/bin/b.json',
      ]);
      expect(outputs.executionRoot, '/x/root');
    });
    // Under remote execution every file is reported by its address in the
    // remote cache, downloaded or not. Reading `uri` found no file at all, so
    // a cloud build armed nothing and said nothing.
    test('finds files a remote cache reported by bytestream address', () {
      final outputs = aspectOutputsFromBuildEvents(
        _remoteHotPatchBuildEvents.join('\n'),
        aspect: aspect,
        outputGroup: 'flutter_native_hot_patch',
      );
      expect(outputs.executionRoot, '/output_base/execroot/_main');
      expect(
        outputs.files,
        [
          '/output_base/execroot/_main/bazel-out/darwin_arm64-dbg-macos-arm64-min12.0-ST-fea79f7fcfbc/bin/libmul_patch.dylib',
          '/output_base/execroot/_main/bazel-out/darwin_arm64-dbg-macos-arm64-min12.0-ST-fea79f7fcfbc/bin/mul_hot_patch.hot_patch.json',
          '/output_base/execroot/_main/bazel-out/darwin_arm64-dbg-macos-arm64-min12.0-ST-fea79f7fcfbc/bin/sub_hot_patch.hot_patch.json',
          '/output_base/execroot/_main/bazel-out/darwin_arm64-dbg-macos-arm64-min12.0-ST-fea79f7fcfbc/bin/libsub_patch.dylib',
          '/output_base/execroot/_main/bazel-out/linux_cloud_arm64-opt-exec/bin/c_patch_tool',
          '/output_base/execroot/_main/native/mul.h',
          '/output_base/execroot/_main/native/sub.h',
        ]..sort(),
      );
    });

    test('refuses a group of files with no execution root to find them in', () {
      expect(
        () => aspectOutputsFromBuildEvents(
          _hotPatchBuildEvents.skip(1).join('\n'),
          aspect: aspect,
          outputGroup: 'flutter_native_hot_patch',
        ),
        throwsA(
          isA<DevToolException>().having(
            (e) => e.message,
            'message',
            contains('no execution root'),
          ),
        ),
      );
    });

    test('an empty group needs no execution root', () {
      final outputs = aspectOutputsFromBuildEvents(
        [
          '{"id":{"namedSet":{"id":"0"}},"namedSetOfFiles":{}}',
          '{"id":{"targetCompleted":{"label":"//:app","aspect":"@@rules_flutter+//flutter:native_hot_patch.bzl%flutter_native_hot_patch_aspect"}},"completed":{"outputGroup":[{"name":"flutter_native_hot_patch","fileSets":[{"id":"0"}]}]}}',
        ].join('\n'),
        aspect: aspect,
        outputGroup: 'flutter_native_hot_patch',
      );
      expect(outputs.files, isEmpty);
    });
  });

  // The shape Bazel 9 writes, with the options a `build:modprobe` config
  // expanded into marked as such, and the original command line beside it.
  group('moduleGraphFlagsFromBuildEvents', () {
    const events = [
      '{"id":{"structuredCommandLine":{"commandLineLabel":"original"}},"structuredCommandLine":{"commandLineLabel":"original","sections":[{"sectionLabel":"command options","optionList":{"option":[{"combinedForm":"--config=modprobe","optionName":"config","optionValue":"modprobe"}]}}]}}',
      '{"id":{"structuredCommandLine":{"commandLineLabel":"canonical"}},"structuredCommandLine":{"commandLineLabel":"canonical","sections":['
          '{"sectionLabel":"executable","chunkList":{"chunk":["bazel"]}},'
          '{"sectionLabel":"command options","optionList":{"option":['
          '{"combinedForm":"--override_module=rules_dart=/src/rules_dart","optionName":"override_module","optionValue":"rules_dart=/src/rules_dart","source":"/ws/.bazelrc.user"},'
          '{"combinedForm":"--lockfile_mode=off","optionName":"lockfile_mode","optionValue":"off"},'
          '{"combinedForm":"--default_override=2:build:modprobe=--registry=https://r.example","optionName":"default_override","optionValue":"2:build:modprobe=--registry=https://r.example"},'
          '{"combinedForm":"--config=modprobe","optionName":"config","optionValue":"modprobe"},'
          '{"combinedForm":"--registry=https://r.example","optionName":"registry","optionValue":"https://r.example","source":"expanded from --config=modprobe"},'
          '{"combinedForm":"--noignore_dev_dependency","optionName":"ignore_dev_dependency","optionValue":"0"},'
          '{"combinedForm":"--copt=-O0","optionName":"copt","optionValue":"-O0"},'
          '{"combinedForm":"--@@rules_dart+//dart:extra_dart_defines=[A=1]"}'
          ']}},'
          '{"sectionLabel":"residual","chunkList":{"chunk":["//:app"]}}]}}',
    ];

    test('keeps the options that decide the module graph, as expanded', () {
      expect(moduleGraphFlagsFromBuildEvents(events.join('\n')), [
        '--override_module=rules_dart=/src/rules_dart',
        '--lockfile_mode=off',
        '--registry=https://r.example',
        '--noignore_dev_dependency',
      ]);
    });

    test('refuses a stream with no canonical command line', () {
      expect(
        () => moduleGraphFlagsFromBuildEvents(events.first),
        throwsA(isA<DevToolException>()),
      );
    });
  });

  group('BazelBuildResult', () {
    test('success is true when exitCode is 0', () {
      final result = BazelBuildResult(
        exitCode: 0,
        outputFiles: ['/tmp/out'],
        stderr: '',
      );
      expect(result.success, isTrue);
    });

    test('success is false when exitCode is non-zero', () {
      final result = BazelBuildResult(
        exitCode: 1,
        outputFiles: [],
        stderr: 'error',
      );
      expect(result.success, isFalse);
    });

    // Without this, a failed build is indistinguishable from one that produced
    // nothing: the caller reads `.outputFiles`, gets an empty list, and reports
    // whichever output it wanted as missing.
    test('asFailure carries the command and what bazel said', () {
      final failure = BazelBuildResult(
        exitCode: 1,
        outputFiles: [],
        stderr: "lib/main.dart:12:5: Error: Expected ';' after this.",
      ).asFailure('build //:app');

      expect(failure.command, 'build //:app');
      expect(failure.diagnostics, contains("Expected ';'"));
      expect('$failure', contains('bazel build //:app failed'));
      expect(
        '$failure',
        contains("Expected ';'"),
        reason:
            'the cause has to travel with the failure; by the time this '
            'is read the streamed copy has scrolled past',
      );
    });

    test('asFailure refuses a build that succeeded', () {
      // There is no failure to raise, and inventing one would report a working
      // build as broken.
      expect(
        () => BazelBuildResult(
          exitCode: 0,
          outputFiles: ['/tmp/out'],
          stderr: '',
        ).asFailure('build //:app'),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('BazelInvocationFailure', () {
    test('says which command failed even when bazel printed nothing', () {
      const failure = BazelInvocationFailure(
        command: 'cquery //:app',
        diagnostics: '',
      );
      expect('$failure', 'bazel cquery //:app failed');
    });
  });

  // The dev tool reads build outputs off disk. The `flutter_assets` tree it
  // diffs belongs to a transitioned configuration, so it is an output of a
  // configured target nobody names on the command line — requested through an
  // aspect rather than by widening the download policy, which would make bazel
  // write down everything it produces for every user and every build.
  group('bazelBuildArgs', () {
    test('asks bazel for the files the dev loop reads', () {
      final args = bazelBuildArgs('//:app', compilationMode: 'dbg');
      expect(args, containsAllInOrder(['build', '//:app', '-c', 'dbg']));
      expect(
        args,
        contains(
          '--aspects=@rules_flutter//flutter:dev_files.bzl%flutter_dev_files_aspect',
        ),
      );
      expect(args, contains('--output_groups=+flutter_dev_files'));
    });

    // A restart compares the bundle's parts against the ones the launch built:
    // a build of them made later can hold an edit the launched app does not.
    test('adds the bundle parts a restart reads, for the launch build', () {
      const parts = LaunchBundleParts(
        aspect: '//:parts.bzl%parts',
        assetsGroup: 'assets_group',
        nativeLibsGroup: 'native_group',
      );
      final args = bazelBuildArgs(
        '//:app',
        compilationMode: 'dbg',
        parts: parts,
      );
      expect(args, contains('--aspects=//:parts.bzl%parts'));
      expect(args, contains('--output_groups=+assets_group,+native_group'));
      // Added to the outputs, not in place of them: the launch artifact and
      // the dev files are still built.
      expect(args, contains('--output_groups=+flutter_dev_files'));
      expect(
        bazelBuildArgs('//:app').any((a) => a.contains('parts.bzl')),
        isFalse,
      );
    });

    test('does not touch the download policy', () {
      // Requesting the outputs is enough; overriding how bazel materializes
      // everything else is not the dev tool's call.
      expect(
        bazelBuildArgs('//:app', compilationMode: 'dbg').join(' '),
        isNot(contains('--remote_download_outputs')),
      );
    });

    test('leaves the caller\'s download policy alone', () {
      // A user who sets one means it. The aspect asks for more outputs; it
      // does not change how anything is built, so there is nothing here that
      // needs to win over `--build-arg`.
      final args = bazelBuildArgs(
        '//:app',
        extraArgs: ['--remote_download_outputs=minimal'],
      );
      expect(args, contains('--remote_download_outputs=minimal'));
      expect(
        args.where((a) => a.startsWith('--remote_download_outputs')).length,
        1,
      );
    });

    test('passes the caller\'s own args through in order', () {
      expect(
        bazelBuildArgs(
          '//:app',
          compilationMode: 'dbg',
          extraArgs: ['--define=a=b', '--//flutter:x=y'],
        ),
        containsAllInOrder([
          'build',
          '//:app',
          '-c',
          'dbg',
          '--define=a=b',
          '--//flutter:x=y',
        ]),
      );
    });
  });

  group('dartDefineFlags', () {
    test('maps each define to one repeatable build-setting flag', () {
      expect(dartDefineFlags(['A=1', 'B=x,y']), [
        '--@rules_dart//dart:extra_dart_defines=A=1',
        '--@rules_dart//dart:extra_dart_defines=B=x,y',
      ]);
    });

    test('empty defines produce no flags', () {
      expect(dartDefineFlags([]), isEmpty);
    });
  });

  group('extraDartDefinesFrom', () {
    test('reads the one list the query prints', () {
      expect(
        extraDartDefinesFrom('["E2E_FLAG=from_flag","MSG=a,b"]\n'),
        ['E2E_FLAG=from_flag', 'MSG=a,b'],
      );
      expect(extraDartDefinesFrom('[]\n'), isEmpty);
    });

    test('refuses anything but one list of strings', () {
      // Two lines are two configurations, which `config(…, target)` exists to
      // rule out: either could be the build's.
      for (final stdout in ['', '[]\n[]\n', '{}\n', '[1]\n']) {
        expect(
          () => extraDartDefinesFrom(stdout),
          throwsA(isA<DevToolException>()),
          reason: stdout,
        );
      }
    });
  });

  // A run is stopped with a signal or `daemon.shutdown`, and either can land
  // while a bazel command is running — the launch build, a codegen rebuild on
  // reload, the first analysis, which fetches the toolchain. Left alone, that
  // command outlives the tool: measured, a build ran on to "Processing and
  // signing app" five seconds after the tool had exited, and every bazel
  // command in the workspace waited behind it for the output base's lock.
  group('Bazel', () {
    /// A [Bazel] whose commands are [FakeProcess]es the test finishes by hand.
    ({
      Bazel bazel,
      List<({List<String> args, String workingDirectory})> spawned,
      List<FakeProcess> processes,
      List<Process> interrupted,
    })
    fakeBazel({
      bool canInterrupt = true,
      Duration stopBound = const Duration(seconds: 5),
      Future<void>? spawnGate,
    }) {
      final spawned = <({List<String> args, String workingDirectory})>[];
      final processes = <FakeProcess>[];
      final interrupted = <Process>[];
      Future<Process> spawn(
        List<String> args, {
        required String workingDirectory,
      }) async {
        spawned.add((args: args, workingDirectory: workingDirectory));
        final process = FakeProcess();
        processes.add(process);
        if (spawnGate != null) await spawnGate;
        return process;
      }

      final bazel = canInterrupt
          ? Bazel.using(
              spawn: spawn,
              interrupt: interrupted.add,
              stopBound: stopBound,
            )
          : Bazel.uninterruptible(
              spawn: spawn,
              because: 'this test gave it no way to',
              stopBound: stopBound,
            );
      return (
        bazel: bazel,
        spawned: spawned,
        processes: processes,
        interrupted: interrupted,
      );
    }

    test('runs a command in the workspace and returns what it said', () async {
      final fake = fakeBazel();

      final result = fake.bazel.run([
        'info',
        'output_base',
      ], workingDirectory: '/ws');
      await pumpEventQueue();
      final process = fake.processes.single;
      await process.outputAttached;
      process.emitStdout('/out/base');
      process.emitStderr('a warning\n');
      process.complete(0);

      final finished = await result;
      expect(fake.spawned.single.args, ['info', 'output_base']);
      expect(fake.spawned.single.workingDirectory, '/ws');
      expect(finished.exitCode, 0);
      expect(finished.stdout, '/out/base\n');
      expect(finished.stderr, 'a warning\n');
    });

    // An override the build's flags make, rather than MODULE.bazel, has to
    // reach `bazel mod` too, or the module reads as fetched and a reload never
    // sees its edits. They go as the build expanded them: never a `--config`,
    // which `bazel mod` refuses when the config has only `build` lines.
    test(
      'localRepositories asks with the build\'s module graph flags',
      () async {
        final fake = fakeBazel();

        final local = fake.bazel.localRepositories(
          ['kit+'],
          workspace: '/ws',
          moduleGraphFlags: [
            '--override_module=kit=/src/kit',
            '--registry=https://registry.example',
          ],
        );
        await pumpEventQueue();
        final process = fake.processes.single;
        await process.outputAttached;
        process.emitStdout(
          '{"canonicalName":"kit+","repoRuleName":"local_repository",'
          '"attribute":[{"name":"path","stringValue":"/src/kit"}]}',
        );
        process.complete(0);

        expect(await local, {'kit+': p.normalize('/src/kit')});
        expect(fake.spawned.single.args, [
          'mod',
          'show_repo',
          '@@kit+',
          '--output=streamed_jsonproto',
          '--override_module=kit=/src/kit',
          '--registry=https://registry.example',
        ]);
      },
    );

    test('localRepositories fails with Bazel\'s own words', () async {
      final fake = fakeBazel();

      final local = fake.bazel.localRepositories(
        ['kit+'],
        workspace: '/ws',
        moduleGraphFlags: const [],
      );
      final failed = expectLater(
        local,
        throwsA(
          isA<BazelInvocationFailure>()
              .having((e) => e.command, 'command', 'mod show_repo')
              .having((e) => e.diagnostics, 'diagnostics', contains('ERROR')),
        ),
      );
      await pumpEventQueue();
      final process = fake.processes.single;
      await process.outputAttached;
      process.emitStderr('ERROR: no such repo\n');
      process.complete(2);
      await failed;
    });

    test(
      'close interrupts a running command and waits for it to end',
      () async {
        final fake = fakeBazel();
        final build = fake.bazel.run([
          'build',
          '//:app',
        ], workingDirectory: '/ws');
        await pumpEventQueue();
        final process = fake.processes.single;

        var closed = false;
        final closing = fake.bazel.close().then((_) => closed = true);
        await pumpEventQueue();

        expect(fake.interrupted, [same(process)]);
        expect(
          closed,
          isFalse,
          reason:
              'bazel releases the output base when it exits, not when it is '
              'asked to stop; returning before then leaves the next command to '
              'wait behind it',
        );

        // Expected before the stop is awaited: the stop finishes only once
        // the command's caller has been told.
        final cancelled = expectLater(build, throwsA(isA<BazelCancelled>()));
        process.complete(8);
        await closing;
        await cancelled;
      },
    );

    // Exit 8 is bazel's own "interrupted", but the status is not the fact:
    // a build that happened to finish as the interrupt arrived still belongs
    // to a run that is ending, and reporting it as a result would have the
    // caller carry on launching.
    test('a command close stopped is cancelled, whatever its status', () async {
      final fake = fakeBazel();
      final build = fake.bazel.run([
        'build',
        '//:app',
      ], workingDirectory: '/ws');
      await pumpEventQueue();

      final closing = fake.bazel.close();
      await pumpEventQueue();
      final cancelled = expectLater(
        build,
        throwsA(
          isA<BazelCancelled>().having(
            (e) => '$e',
            'message',
            contains('bazel build //:app'),
          ),
        ),
      );
      fake.processes.single.complete(0);
      await closing;
      await cancelled;
    });

    test('a command that already ended is not interrupted', () async {
      final fake = fakeBazel();
      final info = fake.bazel.run(['info'], workingDirectory: '/ws');
      await pumpEventQueue();
      fake.processes.single.complete(0);
      await info;

      await fake.bazel.close();

      expect(fake.interrupted, isEmpty);
    });

    test('refuses to start a command once closed', () async {
      final fake = fakeBazel();
      await fake.bazel.close();

      await expectLater(
        fake.bazel.run(['build', '//:app'], workingDirectory: '/ws'),
        throwsA(isA<BazelCancelled>()),
      );
      expect(
        fake.spawned,
        isEmpty,
        reason: 'a bazel started after the stop is one nothing will stop',
      );
    });

    // The window `Teardown` exists for, one level down: a command whose
    // process is still being created when the run is stopped has no process to
    // interrupt yet, and must not come into existence unowned.
    test('a command still starting when close is called is interrupted '
        'once it exists', () async {
      final gate = Completer<void>();
      final fake = fakeBazel(spawnGate: gate.future);
      final build = fake.bazel.run([
        'build',
        '//:app',
      ], workingDirectory: '/ws');
      await pumpEventQueue();

      final closing = fake.bazel.close();
      await pumpEventQueue();
      expect(fake.interrupted, isEmpty);

      gate.complete();
      await pumpEventQueue();
      final process = fake.processes.single;
      expect(fake.interrupted, [same(process)]);

      final cancelled = expectLater(build, throwsA(isA<BazelCancelled>()));
      process.complete(8);
      await closing;
      await cancelled;
    });

    // Bazel's last words on an interrupt — "Bazel caught terminate signal",
    // "build interrupted" — follow its exit status down the pipe. A run that
    // ends the moment the status arrives loses them, and they are the user's
    // only confirmation that the build really stopped.
    test('close waits for what a stopped build printed, not only for its '
        'exit', () async {
      final fake = fakeBazel();
      final build = fake.bazel.build('//:app', workspace: '/ws');
      unawaited(build.then<void>((_) {}, onError: (Object _) {}));
      await pumpEventQueue();
      final process = fake.processes.single;
      await process.outputAttached;

      var closed = false;
      final closing = fake.bazel.close().then((_) => closed = true);
      await pumpEventQueue();
      process.exitBeforeOutputEnds(8);
      await pumpEventQueue();

      expect(closed, isFalse);

      process.emitStderr('Bazel caught terminate signal\n');
      process.complete(8);
      await closing;
    });

    test(
      'close gives up on a command that will not end, and says so',
      () async {
        final fake = fakeBazel(stopBound: const Duration(milliseconds: 20));
        final records = <LogRecord>[];
        final sub = Logger.root.onRecord.listen(records.add);
        addTearDown(sub.cancel);
        unawaited(
          fake.bazel
              .run(['build', '//:app'], workingDirectory: '/ws')
              .then<void>((_) {}, onError: (Object _) {}),
        );
        await pumpEventQueue();

        await fake.bazel.close();

        expect(
          records.map((r) => r.message),
          contains(contains('bazel_stop_timed_out')),
        );
      },
    );

    // Windows: no process group to signal. A console Ctrl-C reaches bazel on
    // its own, so waiting for it is still what releases the output base; what
    // cannot happen is asking it to stop.
    test('without a way to interrupt, close still waits for the command, and '
        'says it could not stop it', () async {
      final fake = fakeBazel(
        canInterrupt: false,
        stopBound: const Duration(milliseconds: 20),
      );
      final records = <LogRecord>[];
      final sub = Logger.root.onRecord.listen(records.add);
      addTearDown(sub.cancel);
      unawaited(
        fake.bazel
            .run(['build', '//:app'], workingDirectory: '/ws')
            .then<void>((_) {}, onError: (Object _) {}),
      );
      await pumpEventQueue();

      await fake.bazel.close();

      final timedOut = records.singleWhere(
        (r) => '${r.message}'.contains('bazel_stop_timed_out'),
      );
      expect(
        '${timedOut.message}',
        contains(
          'could not be interrupted, because this test gave it no way to',
        ),
      );
    });

    test('close with nothing running returns at once, and twice', () async {
      final fake = fakeBazel();

      await fake.bazel.close();
      await fake.bazel.close();

      expect(fake.interrupted, isEmpty);
    });

    test('cqueryExtraDartDefines asks in the build\'s own options', () async {
      final fake = fakeBazel();
      final defines = fake.bazel.cqueryExtraDartDefines(
        workspace: '/ws',
        compilationMode: 'dbg',
        extraArgs: const ['--config=a'],
      );
      await pumpEventQueue();
      final process = fake.processes.single;
      await process.outputAttached;
      process.emitStdout('["A=1"]\n');
      process.complete(0);

      expect(await defines, ['A=1']);
      expect(fake.spawned.single.args, [
        ...extraDartDefinesQuery,
        '-c',
        'dbg',
        '--config=a',
      ]);
    });

    group('cqueryWebBundleFacts', () {
      Future<WebBundleFacts?> ask(
        Bazel bazel,
        List<FakeProcess> processes, {
        required int exitCode,
        String stdout = '',
        String stderr = '',
      }) async {
        final facts = bazel.cqueryWebBundleFacts(
          '//app:web',
          workspace: '/ws',
          compilationMode: 'dbg',
          extraArgs: const ['--define=a=b'],
        );
        await pumpEventQueue();
        final process = processes.single;
        await process.outputAttached;
        process.emitStdout(stdout);
        process.emitStderr(stderr);
        process.complete(exitCode);
        return facts;
      }

      test('asks in the configuration the run builds in and reads the '
          'answer', () async {
        final fake = fakeBazel();
        final facts = await ask(
          fake.bazel,
          fake.processes,
          exitCode: 0,
          stdout:
              '{"target":[{"rule":{"name":"//app:web",'
              '"ruleClass":"flutter_web_bundle","attribute":[{'
              '"name":"js_fallback","booleanValue":false}]}}]}',
        );

        expect(facts!.wasmOnly, isTrue);
        expect(fake.spawned.single.args, [
          ...webBundleFactsQuery('//app:web'),
          '-c',
          'dbg',
          '--define=a=b',
        ]);
        expect(fake.spawned.single.workingDirectory, '/ws');
      });

      test('a query bazel rejects is a failure that names the target and '
          'what bazel said', () async {
        final fake = fakeBazel();
        await expectLater(
          ask(
            fake.bazel,
            fake.processes,
            exitCode: 1,
            stderr: 'ERROR: no such package',
          ),
          throwsA(
            isA<DevToolException>().having(
              (e) => e.message,
              'message',
              allOf(contains('//app:web'), contains('no such package')),
            ),
          ),
        );
      });
    });

    group('build', () {
      test('lists the outputs of a build that succeeded', () async {
        final fake = fakeBazel();
        final build = fake.bazel.build(
          '//:app',
          workspace: '/ws',
          compilationMode: 'dbg',
        );
        await pumpEventQueue();
        final buildProcess = fake.processes.single;
        await buildProcess.outputAttached;
        buildProcess.emitStderr('INFO: Build completed successfully\n');
        buildProcess.complete(0);
        await pumpEventQueue();
        final cquery = fake.processes.last;
        await cquery.outputAttached;
        cquery.emitStdout('bazel-out/darwin/bin/app.zip');
        cquery.complete(0);

        final result = await build;
        expect(fake.spawned.first.args.first, 'build');
        expect(fake.spawned.last.args, [
          'cquery',
          'config(//:app, target)',
          '--output=files',
          '-c',
          'dbg',
        ]);
        expect(result.success, isTrue);
        expect(result.outputFiles, ['/ws/bazel-out/darwin/bin/app.zip']);
      });

      test(
        'a build the run stopped says it stopped, not that it failed',
        () async {
          final fake = fakeBazel();
          final lines = <Map<String, dynamic>>[];
          final sub = Logger.root.onRecord.listen((r) {
            final o = r.object;
            if (o is Map && o['message'] == 'bazel_phase') {
              lines.add(Map<String, dynamic>.from(o));
            }
          });
          addTearDown(sub.cancel);
          final build = fake.bazel.build('//:app', workspace: '/ws');
          final cancelled = expectLater(build, throwsA(isA<BazelCancelled>()));
          await pumpEventQueue();
          final process = fake.processes.single;
          await process.outputAttached;

          final closing = fake.bazel.close();
          await pumpEventQueue();
          process.complete(8);
          await closing;
          await cancelled;

          expect(lines.single['event'], 'stopped');
          expect(
            lines.single['text'],
            matches(
              r'^bazel build //:app stopped after \d+ms: '
              r'the run is shutting down$',
            ),
          );
        },
      );

      // A reload that sits in bazel and one that sits in the query after it are
      // different stalls; each ends with a line that says so, and the query
      // announces itself because it is a second invocation.
      test('says when the build ended and when the query after it ended, with '
          'timings', () async {
        final fake = fakeBazel();
        final lines = <Map<String, dynamic>>[];
        final sub = Logger.root.onRecord.listen((r) {
          final o = r.object;
          if (o is Map && o['message'] == 'bazel_phase') {
            lines.add(Map<String, dynamic>.from(o));
          }
        });
        addTearDown(sub.cancel);
        final build = fake.bazel.build('//:app', workspace: '/ws');
        await pumpEventQueue();
        final buildProcess = fake.processes.single;
        await buildProcess.outputAttached;
        buildProcess.complete(0);
        await pumpEventQueue();
        final cquery = fake.processes.last;
        await cquery.outputAttached;
        cquery.emitStdout('bazel-out/darwin/bin/app.zip');
        cquery.complete(0);
        await build;

        expect(
          [for (final l in lines) '${l['phase']} ${l['event']}'],
          [
            'bazel build finished',
            'bazel query started',
            'bazel query finished',
          ],
        );
        expect(
          lines.first['text'],
          matches(r'^bazel build //:app finished in \d+ms \(exit 0\)$'),
        );
        expect(
          lines.last['text'],
          matches(r'^bazel query of //:app outputs finished in \d+ms$'),
        );
      });

      test('a build that failed carries the tail of what bazel said, and '
          'lists nothing', () async {
        final fake = fakeBazel();
        final build = fake.bazel.build('//:app', workspace: '/ws');
        await pumpEventQueue();
        final process = fake.processes.single;
        await process.outputAttached;
        process.emitStderr("ERROR: lib/main.dart: Expected ';'\n");
        process.complete(1);

        final result = await build;
        expect(result.exitCode, 1);
        expect(result.stderr, contains("Expected ';'"));
        expect(fake.spawned, hasLength(1), reason: 'no cquery after a failure');
      });

      // The dev tool reads every file in the group off this machine's disk, and
      // `--remote_download_minimal` would leave all of them in a remote cache.
      test('an aspect build asks for its group on this machine, and reads it '
          'from the event stream', () async {
        final fake = fakeBazel();
        final build = fake.bazel.buildAspectOutputs(
          '//:app',
          workspace: '/ws',
          aspect: '//:a.bzl%a',
          outputGroup: 'flutter_native_hot_patch',
        );
        // It makes a directory for the event file before it starts bazel.
        while (fake.processes.isEmpty) {
          await pumpEventQueue();
        }
        final process = fake.processes.single;
        await process.outputAttached;
        final args = fake.spawned.single.args;
        expect(args, contains('--remote_download_toplevel'));
        expect(args, contains('--output_groups=flutter_native_hot_patch'));
        final eventFile = args
            .singleWhere((a) => a.startsWith('--build_event_json_file='))
            .split('=')
            .last;
        File(eventFile).writeAsStringSync(
          [
            ..._remoteHotPatchBuildEvents.map(
              (e) => e.replaceAll('flutter_native_hot_patch_aspect', 'a'),
            ),
            '{"structuredCommandLine":{"commandLineLabel":"canonical","sections":[{"sectionLabel":"command options","optionList":{"option":[{"combinedForm":"--override_module=kit=/src/kit","optionName":"override_module"}]}}]}}',
          ].join('\n'),
        );
        process.complete(0);

        final outputs = await build;
        expect(outputs.success, isTrue);
        expect(outputs.moduleGraphFlags, ['--override_module=kit=/src/kit']);
        expect(
          outputs.files,
          contains(
            '/output_base/execroot/_main/bazel-out/darwin_arm64-dbg-macos-arm64-min12.0-ST-fea79f7fcfbc/bin/mul_hot_patch.hot_patch.json',
          ),
        );
      });

      // What a restart compares against is what the launch built, so the
      // launch build itself reports the parts, from its own event stream: an
      // aspect's outputs are in no cquery.
      test('a launch build with bundle parts reads them from its event '
          'stream', () async {
        final fake = fakeBazel();
        final build = fake.bazel.build(
          '//:app',
          workspace: '/ws',
          parts: const LaunchBundleParts(
            aspect: '@rules_flutter//flutter:a.bzl%an_aspect',
            assetsGroup: 'assets',
            nativeLibsGroup: 'libs',
          ),
        );
        while (fake.processes.isEmpty) {
          await pumpEventQueue();
        }
        final process = fake.processes.single;
        await process.outputAttached;
        final args = fake.spawned.single.args;
        expect(args, contains('--output_groups=+assets,+libs'));
        final eventFile = args
            .singleWhere((a) => a.startsWith('--build_event_json_file='))
            .split('=')
            .last;
        File(eventFile).writeAsStringSync(
          [
            '{"id":{"workspace":{}},"workspaceInfo":{"localExecRoot":"/x/root"}}',
            '{"id":{"namedSet":{"id":"0"}},"namedSetOfFiles":{"files":[{"name":"libx.dylib","pathPrefix":["bazel-out","k","bin"]}]}}',
            '{"id":{"targetCompleted":{"label":"//:app","aspect":"@@rules_flutter+//flutter:a.bzl%an_aspect"}},"completed":{"outputGroup":[{"name":"libs","fileSets":[{"id":"0"}]}]}}',
          ].join('\n'),
        );
        process.complete(0);
        await pumpEventQueue();
        final cquery = fake.processes.last;
        await cquery.outputAttached;
        cquery.emitStdout('bazel-out/darwin/bin/app.zip');
        cquery.complete(0);

        final result = await build;
        expect(result.partsFiles, {
          'assets': <String>[],
          'libs': ['/x/root/bazel-out/k/bin/libx.dylib'],
        });
        expect(
          fake.spawned.last.args,
          isNot(contains(startsWith('--build_event_json_file'))),
          reason: 'the cquery lists outputs; it writes no event stream',
        );
      });

      test('a build close stopped is cancelled and queries nothing', () async {
        final fake = fakeBazel();
        final build = fake.bazel.build('//:app', workspace: '/ws');
        await pumpEventQueue();

        final closing = fake.bazel.close();
        await pumpEventQueue();
        final cancelled = expectLater(build, throwsA(isA<BazelCancelled>()));
        fake.processes.single.complete(8);
        await closing;
        await cancelled;
        expect(fake.spawned, hasLength(1));
      });
    });
  });
}
