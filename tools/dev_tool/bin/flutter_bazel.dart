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
import 'dart:io';

import 'package:args/args.dart';

import '../lib/attach_command.dart';
import '../lib/build_command.dart';
import '../lib/logging.dart';
import '../lib/run_command.dart' show RunCommand, DevToolException;
import '../lib/tunnel_command.dart';

void main(List<String> args) async {
  initLogging();
  // Handle ios-tunnel as a special case — it's a long-running daemon that
  // takes over the process, so we intercept it before ArgParser.
  if (args.isNotEmpty && args.first == 'ios-tunnel') {
    await executeTunnelCommand();
  }

  final parser = ArgParser()
    ..addCommand('build', BuildCommand.parser)
    ..addCommand('run', RunCommand.parser)
    ..addCommand('attach', AttachCommand.parser)
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

    switch (command.name) {
      case 'build':
        await BuildCommand(command).execute();
      case 'run':
        await RunCommand(command).execute();
      case 'attach':
        await AttachCommand(command).execute();
      default:
        stderr.writeln('Unknown command: ${command.name}');
        _printUsage(parser);
        exit(1);
    }
  } on DevToolException catch (e) {
    stderr.writeln('Error: $e');
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
  stdout.writeln('Flutter dev tool for Bazel-built projects.');
  stdout.writeln();
  stdout.writeln('Usage: flutter_bazel <command> [options]');
  stdout.writeln();
  stdout.writeln('Commands:');
  stdout.writeln('  build       Build a Flutter target with Bazel');
  stdout.writeln('  run         Build, run, and hot reload a Flutter target');
  stdout.writeln('  attach      Connect to an already-running Flutter app');
  stdout.writeln('  ios-tunnel  Start iOS device tunnel daemon (requires sudo)');
  stdout.writeln();
  stdout.writeln('Run options:');
  stdout.writeln('  -d, --device    Device to run on (repeatable for multi-device)');
  stdout.writeln('                  macos, linux, windows, ios-simulator, ios, chrome,');
  stdout.writeln('                  ios-simulator:<udid>, ios:<udid>, or Android serial');
  stdout.writeln('  --hot           Enable hot reload (default: on, requires -c dbg)');
  stdout.writeln('  --no-hot        Disable hot reload (just build and launch)');
  stdout.writeln('  --devtools      Launch DevTools (default: on)');
  stdout.writeln('  --no-devtools   Disable DevTools auto-launch');
  stdout.writeln('  --machine       Enable machine-readable JSON protocol for IDE');
  stdout.writeln();
  stdout.writeln('Keyboard shortcuts (during run/attach):');
  stdout.writeln('  r    Hot reload');
  stdout.writeln('  R    Hot restart');
  stdout.writeln('  p    Toggle performance overlay');
  stdout.writeln('  i    Toggle widget inspector');
  stdout.writeln('  q    Quit');
  stdout.writeln();
  stdout.writeln('Machine protocol commands (--machine):');
  stdout.writeln('  app.hotReload    Recompile and hot reload all devices');
  stdout.writeln('  app.restart      Hot restart all devices');
  stdout.writeln('  app.stop         Stop the app');
  stdout.writeln('  daemon.shutdown  Shut down the dev tool');
  stdout.writeln();
  stdout.writeln(parser.usage);
}
