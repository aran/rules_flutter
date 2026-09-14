/// The `build` command — invokes bazel build for a Flutter target.
import 'dart:io';

import 'package:args/args.dart';

import 'bazel.dart';
import 'run_command.dart';
import 'shutdown_signals.dart';

class BuildCommand {
  static final parser = ArgParser()
    ..addOption(
      'target',
      abbr: 't',
      help: 'Bazel target to build (e.g. //:my_app).',
      mandatory: true,
    )
    ..addOption(
      'config',
      abbr: 'c',
      help: 'Bazel config to use (e.g. release).',
    )
    ..addMultiOption(
      'build-arg',
      // A bazel flag's value can hold a comma (`--copt=-Wl,-rpath`), and the
      // option repeats, so a comma never separates two of them.
      splitCommas: false,
      help: 'Additional arguments to pass to bazel build.',
    )
    ..addMultiOption(
      'dart-define',
      splitCommas: false,
      help:
          'Dart environment define (KEY=VALUE) forwarded to the build '
          'as --@rules_flutter//flutter:extra_dart_defines. Repeat for '
          'multiple defines.',
    )
    ..addFlag(
      'verbose',
      abbr: 'v',
      defaultsTo: false,
      help: 'Enable verbose debug logging.',
    )
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Show help for this command.',
    );

  final ArgResults _results;

  BuildCommand(this._results);

  Future<void> execute() async {
    final bazel = Bazel();
    // Stopping `flutter_bazel build` has to stop the build. Dart's default for
    // SIGINT and SIGTERM ends the VM on the spot, and bazel — in a process group
    // of its own, which a terminal's Ctrl-C no longer reaches — would build on
    // without it. The same handler `run` uses: a first signal stops the build
    // and waits for it to exit, a second exits at once.
    final handler = ShutdownSignalHandler(
      onShutdown: bazel.close,
      exitProcess: exit,
    );
    final subscriptions = [
      for (final signal in shutdownSignalsFor(isWindows: Platform.isWindows))
        handler.listen(signal.watch()),
    ];

    try {
      await _build(bazel);
    } on BazelCancelled {
      // Only the handler stops a build, and it is still running: it exits once
      // the build has. The signal subscriptions stay up on the way out because
      // they are what keeps this process alive until then.
      return;
    }
    // Cancelled once the build is over, or the process could not end: an
    // uncancelled `ProcessSignal.watch()` keeps the VM alive after `main`.
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  }

  Future<void> _build(Bazel bazel) async {
    final target = _results['target'] as String;
    final config = _results['config'] as String?;
    final extraArgs = [
      ...(_results['build-arg'] as List<String>),
      ...dartDefineFlags(_results['dart-define'] as List<String>),
    ];
    final workspace = await bazel.findWorkspaceRoot();

    stdout.writeln('Building $target...');

    final result = await bazel.build(
      target,
      workspace: workspace,
      compilationMode: config,
      extraArgs: extraArgs,
    );

    if (!result.success) {
      throw DevToolException(
        'Build failed with exit code ${result.exitCode}',
        exitCode: result.exitCode,
      );
    }

    stdout.writeln('Build succeeded.');
    if (result.outputFiles.isNotEmpty) {
      stdout.writeln('Output files:');
      for (final f in result.outputFiles) {
        stdout.writeln('  $f');
      }
    }
  }
}
