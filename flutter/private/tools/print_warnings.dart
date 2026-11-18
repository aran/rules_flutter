/// Prints a build's warnings, and succeeds.
///
/// flutter_tools prints some warnings and builds on, such as one about a
/// federated plugin's `default_package` it ignores. Analysis has no channel
/// for a warning; what a successful action writes to stderr is Bazel's, as
/// with a compiler's warnings. The rules run this as a validation action
/// whose stamp the build requires, so building the target prints each
/// `--warning` once, whenever the action runs.
///
/// It has no package dependencies, and runs with the bare Dart SDK.
///
/// Usage:
///   dart print_warnings.dart --stamp <file> [--warning <text>]...
import 'dart:io';

/// Writes each warning of [args] to [err] and the stamp they name.
void printWarnings(List<String> args, StringSink err) {
  String? stamp;
  final warnings = <String>[];
  for (var i = 0; i < args.length; i++) {
    final flag = args[i];
    if (i + 1 >= args.length) {
      throw ArgumentError('$flag needs a value');
    }
    final value = args[++i];
    switch (flag) {
      case '--stamp':
        stamp = value;
      case '--warning':
        warnings.add(value);
      default:
        throw ArgumentError('unknown argument $flag');
    }
  }
  if (stamp == null) {
    throw ArgumentError('--stamp is required');
  }
  for (final warning in warnings) {
    err.write(warning.endsWith('\n') ? warning : '$warning\n');
  }
  File(stamp).writeAsStringSync('');
}

void main(List<String> args) {
  printWarnings(args, stderr);
}
