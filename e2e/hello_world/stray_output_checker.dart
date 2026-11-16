/// The executable of `stray_output_test`: runs a test that leaves a process
/// holding its output and then fails, and checks that it ended while that
/// process was still running and that what it said before ending reached its
/// output.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

Future<void> main() async {
  final runfiles = Runfiles.create();
  final config = json.decode(
    File(runfiles.rlocation(Platform.environment['STRAY_OUTPUT_CONFIG']!))
        .readAsStringSync(),
  ) as Map<String, Object?>;
  final scratch = Directory(Platform.environment['TEST_TMPDIR']!)
      .createTempSync('stray_output');
  final pidFile = File('${scratch.path}/stray.pid');

  final process = await Process.start(
    runfiles.rlocation(config['executable']! as String),
    const [],
    environment: {
      ...Platform.environment,
      ...(config['env']! as Map<String, Object?>).cast<String, String>(),
      // Its report is not this target's.
      'XML_OUTPUT_FILE': '${scratch.path}/report.xml',
      'STRAY_PID_FILE': pidFile.path,
    },
  );
  final output = StringBuffer();
  final pumps = [
    for (final (stream, sink) in [
      (process.stdout, stdout),
      (process.stderr, stderr),
    ])
      stream.transform(utf8.decoder).forEach((text) {
        output.write(text);
        sink.write(text);
      }),
  ];
  final exitCode = await process.exitCode;

  final problems = <String>[];
  if (exitCode == 0) problems.add('it should have failed and exited with 0');
  // Killed here, so its output closes and the pumps end. A kill that is
  // delivered says the process was alive when the test ended.
  final stray = pidFile.existsSync()
      ? int.parse(pidFile.readAsStringSync().trim())
      : null;
  if (stray == null) {
    problems.add('it wrote no process id to ${pidFile.path}');
  } else if (!Process.killPid(stray, ProcessSignal.sigkill)) {
    problems.add(
      'the process it left ($stray) was gone when it ended, so this proves '
      'nothing about ending while one runs',
    );
  }
  await Future.wait(pumps);
  for (final text in (config['outputContains']! as List).cast<String>()) {
    if (!output.toString().contains(text)) {
      problems.add('its output does not contain "$text"');
    }
  }

  if (problems.isEmpty) {
    stdout.writeln('stray_output: the test ended as it should have.');
  } else {
    stderr
      ..writeln('stray_output: the test did not end as it should have:')
      ..writeln(problems.map((p) => '  - $p').join('\n'));
  }
  await Future.wait([stdout.flush(), stderr.flush()]);
  exit(problems.isEmpty ? 0 : 1);
}
