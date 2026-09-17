import 'dart:async';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/bazel.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'fakes.dart';

/// A real `--build_event_json_file` stream, trimmed to the events the parser
/// reads: `bazel build //:ffi_macos -c dbg` with the hot patch aspect over
/// `e2e/ffi_example`, output base and workspace paths scrubbed.
const _hotPatchBuildEvents = [
  r'''{"id":{"targetCompleted":{"label":"//:ffi_macos","configuration":{"id":"ded4a48995378b6e91c665930388fd27a68bc9ae052e68bda3b10a50d5a2def7"}}},"completed":{"success":true,"tag":["manual"]}}''',
  r'''{"id":{"namedSet":{"id":"0"}},"namedSetOfFiles":{"files":[{"name":"mul_hot_patch.hot_patch.json","uri":"file:///output_base/execroot/_main/bazel-out/darwin_arm64-dbg-macos-arm64-min10.14-ST-03fe10a2746b/bin/mul_hot_patch.hot_patch.json","pathPrefix":["bazel-out","darwin_arm64-dbg-macos-arm64-min10.14-ST-03fe10a2746b","bin"],"digest":"e816d563bb00d826870d8b5fac4b1cdb6bb96713d6e157d403cd0c1f1bf39710","length":"360"},{"name":"c_patch_tool","uri":"file:///output_base/execroot/_main/bazel-out/darwin_arm64-opt-exec/bin/c_patch_tool","pathPrefix":["bazel-out","darwin_arm64-opt-exec","bin"],"digest":"5917a8f9c6437120fcaae3c1aaeba7fa9febd97e7bac28780c7df71d672fe520","length":"5878880"},{"name":"libmul_patch.dylib","uri":"file:///output_base/execroot/_main/bazel-out/darwin_arm64-dbg-macos-arm64-min10.14-ST-03fe10a2746b/bin/libmul_patch.dylib","pathPrefix":["bazel-out","darwin_arm64-dbg-macos-arm64-min10.14-ST-03fe10a2746b","bin"],"digest":"c2a500134cb6a6ebd92e1b00b67acec836d10503b50f89c422240b43b104f33e","length":"16992"},{"name":"native/mul.h","uri":"file:///workspace/native/mul.h","digest":"56b8a1f81413ba96dfada5d7eb1d5b71075c00170177a83b97be02deaa4398c7","length":"422"}]}}''',
  r'''{"id":{"targetCompleted":{"label":"//:ffi_macos","aspect":"@@rules_flutter+//flutter:native_hot_patch.bzl%flutter_native_hot_patch_aspect","configuration":{"id":"ded4a48995378b6e91c665930388fd27a68bc9ae052e68bda3b10a50d5a2def7"}}},"completed":{"success":true,"outputGroup":[{"name":"flutter_native_hot_patch","fileSets":[{"id":"0"}]}]}}''',
];

void main() {
  group('aspectOutputsFromBuildEvents', () {
    const aspect =
        '@rules_flutter//flutter:native_hot_patch.bzl%'
        'flutter_native_hot_patch_aspect';

    test('reads the files an aspect put in a group, and the execution root', () {
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
        '/workspace/native/mul.h',
      ]);
    });

    test('ignores another aspect\'s group and follows nested file sets', () {
      final events = [
        '{"id":{"namedSet":{"id":"1"}},"namedSetOfFiles":{"files":[{"name":"b.json","uri":"file:///x/root/bazel-out/k/bin/b.json","pathPrefix":["bazel-out","k","bin"]}]}}',
        '{"id":{"namedSet":{"id":"0"}},"namedSetOfFiles":{"files":[{"name":"a.json","uri":"file:///x/root/bazel-out/k/bin/a.json","pathPrefix":["bazel-out","k","bin"]}],"fileSets":[{"id":"1"}]}}',
        '{"id":{"namedSet":{"id":"2"}},"namedSetOfFiles":{"files":[{"name":"other","uri":"file:///x/root/other"}]}}',
        '{"id":{"targetCompleted":{"label":"//:app","aspect":"@@rules_flutter+//flutter:dev_files.bzl%flutter_dev_files"}},"completed":{"outputGroup":[{"name":"flutter_native_hot_patch","fileSets":[{"id":"2"}]}]}}',
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
          '--aspects=@rules_flutter//flutter:dev_files.bzl%flutter_dev_files',
        ),
      );
      expect(args, contains('--output_groups=+flutter_dev_files'));
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
        '--@rules_flutter//flutter:extra_dart_defines=A=1',
        '--@rules_flutter//flutter:extra_dart_defines=B=x,y',
      ]);
    });

    test('empty defines produce no flags', () {
      expect(dartDefineFlags([]), isEmpty);
    });
  });

  // A run is stopped with a signal or `daemon.shutdown`, and either can land
  // while a bazel command is running — the launch build, a codegen rebuild on
  // reload, a first `bazel fetch` of the toolchain. Left alone, that command
  // outlives the tool: measured, a build ran on to "Processing and signing
  // app" five seconds after the tool had exited, and every bazel command in
  // the workspace waited behind it for the output base's lock.
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
          '//:app',
          '--output=files',
          '-c',
          'dbg',
        ]);
        expect(result.success, isTrue);
        expect(result.outputFiles, ['/ws/bazel-out/darwin/bin/app.zip']);
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
