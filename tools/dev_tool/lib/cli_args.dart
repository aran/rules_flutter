/// The top-level `--help` text, and the guard every subcommand's argv passes
/// through before anything runs.
///
/// `ArgParser` already refuses a misspelled *option* by name, which covers the
/// mistake people expect to make. It does not cover the one they actually make
/// with this tool: a bazel flag is not shaped like an option name at all —
/// `--@rules_flutter//flutter:extra_dart_defines=K=V` carries `@`, `/` and `:` —
/// so it never parses as one, becomes a positional argument, and is dropped.
///
/// Dropped silently, which is the part that costs hours. The run proceeds with
/// the app's `BUILD.bazel` defaults, and the failure arrives much later and
/// somewhere else: a missing define surfaces as a connection refused by whatever
/// the define was pointing at, with nothing between the two to connect them.
library;

import 'package:args/args.dart';

import 'dev_tool_exception.dart';
import 'device_id.dart';

/// The text `flutter_bazel --help` prints, ending with [parser]'s own usage.
///
/// The run options are the `run` command's own, with its help text, so the
/// summary cannot say something `run --help` does not. The `-d` forms in that
/// text come from [acceptedDeviceIdForms], the list [resolveDevices] accepts.
String topLevelUsage(ArgParser parser) => [
  'Flutter dev tool for Bazel-built projects.',
  '',
  'Usage: flutter_bazel <command> [options]',
  '',
  'Commands:',
  '  build       Build a Flutter target with Bazel',
  '  run         Build, run, and hot reload a Flutter target',
  '  attach      Connect to an already-running Flutter app',
  '',
  'Run options (all of them: flutter_bazel run --help):',
  for (final name in _summarizedRunOptions)
    _optionLines(parser.commands['run']!.options[name]!),
  '',
  'Keyboard shortcuts (during run/attach):',
  '  r    Hot reload',
  '  R    Hot restart',
  '  p    Toggle performance overlay',
  '  i    Toggle widget inspector',
  '  q    Quit',
  '',
  'Machine protocol commands (--machine):',
  '  app.hotReload    Recompile and hot reload all devices',
  '  app.restart      Hot restart all devices',
  '  app.stop         Stop the app',
  '  daemon.shutdown  Shut down the dev tool',
  '  app.*            The agent commands, such as app.tap and',
  '                   app.getText. A run lists every command it offers',
  '                   on daemon.connected and GET /commands.',
  '',
  parser.usage,
].join('\n');

/// The `run` options [topLevelUsage] shows.
const _summarizedRunOptions = [
  'device',
  'hot',
  'devtools',
  'machine',
  'dart-define',
];

/// [option] as a help entry: its name, then its own help wrapped at
/// [_helpIndent].
String _optionLines(Option option) {
  final name = option.isFlag && option.negatable!
      ? '--[no-]${option.name}'
      : '--${option.name}';
  final label = option.abbr == null ? name : '-${option.abbr}, $name';
  final help = [
    option.help!,
    if (option.isFlag && option.defaultsTo == true) '(default: on)',
  ].join(' ');
  final wrapped = _wrap(help);
  final first = '  $label';
  return first.length < _helpIndent.length
      ? first.padRight(_helpIndent.length) +
            wrapped.substring(_helpIndent.length)
      : '$first\n$wrapped';
}

/// Where an option's description starts in [topLevelUsage].
const _helpIndent = '                  ';

/// [text] broken at spaces into lines of at most 70 characters, each starting
/// at [_helpIndent].
String _wrap(String text) {
  const width = 70;
  final lines = <String>[];
  var line = '';
  for (final word in text.split(' ')) {
    if (line.isNotEmpty &&
        _helpIndent.length + line.length + 1 + word.length > width) {
      lines.add('$_helpIndent$line');
      line = '';
    }
    line = line.isEmpty ? word : '$line $word';
  }
  lines.add('$_helpIndent$line');
  return lines.join('\n');
}

/// Fail when [rest] is non-empty, naming what was dropped and the two spellings
/// that would have worked.
///
/// No subcommand takes a positional argument, so this is never a judgment call
/// about which ones are safe to ignore — anything here was meant to be
/// understood and was not.
void requireNoPositionalArgs(String command, List<String> rest) {
  if (rest.isEmpty) return;
  throw DevToolException(
    'Unexpected argument(s): ${rest.join(' ')}\n'
    'No `$command` argument is positional, so none of these reached anything. '
    "A bazel flag reaches the app's build through `--build-arg=<flag>`, and a "
    'Dart define through `--dart-define=KEY=VALUE` (which forwards as '
    '`--@rules_flutter//flutter:extra_dart_defines` and is replayed on every '
    'hot reload). Run `flutter_bazel $command --help` for the rest.',
  );
}
