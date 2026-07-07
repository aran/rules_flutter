/// The `build` command — invokes bazel build for a Flutter target.
import 'dart:io';

import 'package:args/args.dart';

import 'bazel.dart';
import 'run_command.dart';

class BuildCommand {
  static final parser =
      ArgParser()
        ..addOption('target', abbr: 't', help: 'Bazel target to build (e.g. //:my_app).', mandatory: true)
        ..addOption('config', abbr: 'c', help: 'Bazel config to use (e.g. release).')
        ..addMultiOption('build-arg', help: 'Additional arguments to pass to bazel build.')
        ..addMultiOption('dart-define',
            splitCommas: false,
            help: 'Dart environment define (KEY=VALUE) forwarded to the build '
                'as --@rules_flutter//flutter:extra_dart_defines. Repeat for '
                'multiple defines.')
        ..addFlag('verbose', abbr: 'v', defaultsTo: false, help: 'Enable verbose debug logging.')
        ..addFlag('help', abbr: 'h', negatable: false, help: 'Show help for this command.');

  final ArgResults _results;

  BuildCommand(this._results);

  Future<void> execute() async {
    final target = _results['target'] as String;
    final config = _results['config'] as String?;
    final extraArgs = [
      ...(_results['build-arg'] as List<String>),
      ...dartDefineFlags(_results['dart-define'] as List<String>),
    ];
    final workspace = await findWorkspaceRoot();

    stdout.writeln('Building $target...');

    final result = await bazelBuild(target,
        workspace: workspace,
        compilationMode: config,
        extraArgs: extraArgs);

    if (!result.success) {
      throw DevToolException('Build failed with exit code ${result.exitCode}',
          exitCode: result.exitCode);
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
