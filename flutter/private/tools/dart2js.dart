/// Runs dart2js, then deletes the list of inputs it writes beside its output.
///
/// dart2js always writes `main.dart.js.deps` beside `main.dart.js`, naming each
/// input by the absolute path it was read from: the sandbox slot, the output
/// base and the home directory of the machine that built it. No flag stops
/// it. Nothing reads the list, and the bundle leaves it out of what it
/// deploys, but the output directory is one cached output, so the list would
/// make it differ with every sandbox and machine, and every action that reads
/// the directory would miss the cache.
///
/// The list must be there after a successful compile: a dart2js that stops
/// writing it, or writes it elsewhere, fails here rather than leaking the
/// paths again unnoticed.
///
/// It has no package dependencies and runs with the bare Dart SDK.
///
/// Usage:
///   dart dart2js.dart --dart <path> --deps <path> -- <`dart` arguments>
library;

import 'dart:io';

Future<void> main(List<String> argv) async {
  exit(await compile(argv, stderr));
}

/// Runs the compile [argv] describes, reporting to [err]; returns the exit
/// code.
Future<int> compile(List<String> argv, StringSink err) async {
  String? dart;
  String? deps;
  var i = 0;
  for (; i < argv.length; i++) {
    final a = argv[i];
    if (a == '--') {
      i++;
      break;
    } else if (a == '--dart' && i + 1 < argv.length) {
      dart = argv[++i];
    } else if (a == '--deps' && i + 1 < argv.length) {
      deps = argv[++i];
    }
  }
  final args = argv.sublist(i);
  if (dart == null || deps == null || args.isEmpty) {
    err.writeln(
      'Usage: dart dart2js.dart --dart <path> --deps <path> -- '
      '<dart arguments>',
    );
    return 2;
  }

  final process = await Process.start(
    dart,
    args,
    mode: ProcessStartMode.inheritStdio,
  );
  final code = await process.exitCode;
  if (code != 0) return code;

  final list = File(deps);
  if (!list.existsSync()) {
    err.writeln(
      'dart2js wrote no $deps. Find where it lists its inputs now: the list '
      'names the sandbox it ran in, so it must be left out of the output.',
    );
    return 1;
  }
  list.deleteSync();
  return 0;
}
