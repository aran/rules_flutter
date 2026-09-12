/// The guard every subcommand's argv passes through before anything runs.
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

import 'dev_tool_exception.dart';

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
