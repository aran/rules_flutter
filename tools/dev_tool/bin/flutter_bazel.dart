/// Flutter dev tool for Bazel-built projects.
///
/// This is the `flutter run` equivalent for Bazel-based Flutter projects.
/// It invokes `bazel build` to produce the application, then handles
/// device deployment and hot reload via the persistent frontend_server.
///
/// Usage:
///   dart run tools/dev_tool/bin/flutter_bazel.dart run --target //:my_app
///   dart run tools/dev_tool/bin/flutter_bazel.dart build --target //:my_app
///   dart run tools/dev_tool/bin/flutter_bazel.dart attach --debug-url http://...
///   dart run tools/dev_tool/bin/flutter_bazel.dart devices
import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:flutter_bazel_dev_tool/attach_command.dart';
import 'package:flutter_bazel_dev_tool/build_command.dart';
import 'package:flutter_bazel_dev_tool/chrome_profile.dart';
import 'package:flutter_bazel_dev_tool/cli_args.dart';
import 'package:flutter_bazel_dev_tool/devices_command.dart';
import 'package:flutter_bazel_dev_tool/logging.dart';
import 'package:flutter_bazel_dev_tool/run_command.dart'
    show RunCommand, DevToolException;
import 'package:flutter_bazel_dev_tool/runfiles_helper.dart'
    show pinProcessLocation;

void main(List<String> args) {
  // The VM ends the process on an error nothing caught, and nothing between
  // that error and the exit stops the browsers a run has started or deletes
  // their profiles. The exit is the same one the VM would have made.
  runZonedGuarded(() => _run(args), (error, stack) {
    ChromeProfile.releaseAllNow();
    stderr.writeln('Unhandled exception:\n$error\n$stack');
    exit(255);
  });
}

Future<void> _run(List<String> args) async {
  // Before anything can move the path this was launched through.
  pinProcessLocation();
  initLogging();

  final parser = ArgParser()
    ..addCommand('build', BuildCommand.parser)
    ..addCommand('run', RunCommand.parser)
    ..addCommand('attach', AttachCommand.parser)
    ..addCommand('devices', DevicesCommand.parser)
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show help.');

  try {
    final results = parser.parse(args);

    if (results['help'] as bool || results.command == null) {
      _printUsage(parser);
      exit(0);
    }

    final command = results.command!;
    if (command['help'] as bool? ?? false) {
      _printCommandHelp(command.name!, parser);
      exit(0);
    }
    requireNoPositionalArgs(command.name!, command.rest);

    switch (command.name) {
      case 'build':
        await BuildCommand(command).execute();
      case 'run':
        await RunCommand(command).execute();
      case 'attach':
        await AttachCommand(command).execute();
      case 'devices':
        await DevicesCommand(command).execute();
      default:
        stderr.writeln('Unknown command: ${command.name}');
        _printUsage(parser);
        exit(1);
    }
  } on DevToolException catch (e) {
    // Through the logger rather than straight to stderr: under
    // `LOG_FORMAT=json` the line that says why the run failed has to be a
    // record with a level like every other, or the one message a consumer most
    // needs is the one it cannot parse. Text mode is unchanged.
    Logger('dev_tool').severe({
      'message': 'command_failed',
      'text': 'Error: $e',
      'error': '$e',
      'exitCode': e.exitCode,
    });
    exit(e.exitCode);
  } on FormatException catch (e) {
    stderr.writeln('Error: ${e.message}');
    _printUsage(parser);
    exit(1);
  }
}

void _printCommandHelp(String commandName, ArgParser parser) {
  final commandParser = parser.commands[commandName]!;
  stdout.writeln('Usage: flutter_bazel $commandName [options]');
  stdout.writeln();
  stdout.writeln(commandParser.usage);
}

void _printUsage(ArgParser parser) {
  stdout.writeln(topLevelUsage(parser));
}
