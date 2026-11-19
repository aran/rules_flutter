/// Reads its standard input through `standardInput`, for
/// `standard_input_test`.
///
///     standard_input_probe read-to-end|stop-reading
///
/// `read-to-end` reads the input to its end, then starts `cat` and prints how
/// it exited. `cat` reads its own stdin, which `Process.run` hands it as a
/// pipe and closes: it exits 0 when it was given one, and fails with "Bad file
/// descriptor" when it starts without. `stop-reading` is [_stopReading].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/standard_input.dart';

Future<void> main(List<String> args) async {
  switch (args.single) {
    case 'read-to-end':
      await _readToEnd();
    case 'stop-reading':
      await _stopReading();
    case final other:
      throw ArgumentError('Unknown mode: $other');
  }
}

Future<void> _readToEnd() async {
  final read = await standardInput.fold<int>(0, (n, c) => n + c.length);
  final cat = await Process.run('cat', const []);
  stdout.writeln(
    jsonEncode({
      'read': read,
      'catExitCode': cat.exitCode,
      'catStderr': '${cat.stderr}'.trim(),
    }),
  );
}

/// Takes the first chunk, stops reading with the input still open, and
/// returns from `main`, as the keyboard loop does on `q`: the process has to
/// end though nothing more is typed.
Future<void> _stopReading() async {
  final iterator = StreamIterator(standardInput);
  await iterator.moveNext();
  stdout.writeln('read ${iterator.current.length}');
  await iterator.cancel();
}
