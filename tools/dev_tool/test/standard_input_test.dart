/// What `standardInput` has to guarantee: a process the tool starts after its
/// own input has ended still gets a stdin, and the tool can still end while
/// its input is open.
///
/// The first runs `standard_input_probe`, which reads its input to the end
/// and then starts `cat`, with that input a pipe, `/dev/null` or a file: the
/// three a script, a CI job or an agent starts the tool with. Read through
/// `dart:io`'s `stdin` instead, the same probe's `cat` usually starts with no
/// stdin; usually rather than always, because `dart:io` closes descriptor 0 a
/// moment after it announces the end, and whatever the process opens first
/// then takes descriptor 0. That is why there is no control case here.
///
/// Tagged `runfiles`: the probe is a `data` dependency.
@TestOn('!windows')
@Tags(['runfiles'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/runfiles_helper.dart';
import 'package:test/test.dart';

const _probeKey = 'rules_flutter/tools/dev_tool/standard_input_probe';

String _probe() {
  final path = resolveRunfile(_probeKey);
  if (path == null) {
    throw StateError(
      'Could not resolve $_probeKey from runfiles. Run this with '
      '`bazel test //tools/dev_tool:standard_input_test`.',
    );
  }
  return path;
}

/// What the probe reported after reading its input to the end.
typedef _Report = ({int read, int catExitCode, String catStderr});

/// Runs the probe with stdin from a shell redirection of [from], or, when
/// [from] is null, from a pipe this test writes [bytes] to and closes.
Future<_Report> _readToEnd({String? from, List<int>? bytes}) async {
  final process = from == null
      ? await Process.start(_probe(), ['read-to-end'])
      : await Process.start('/bin/sh', [
          '-c',
          r'exec "$0" read-to-end < "$1"',
          _probe(),
          from,
        ]);
  if (bytes != null) process.stdin.add(bytes);
  await process.stdin.close();
  final out = process.stdout.transform(utf8.decoder).join();
  final err = process.stderr.transform(utf8.decoder).join();
  final code = await process.exitCode;
  expect(code, 0, reason: 'the probe failed: ${await err}');
  final report = jsonDecode((await out).trim()) as Map<String, dynamic>;
  return (
    read: report['read'] as int,
    catExitCode: report['catExitCode'] as int,
    catStderr: report['catStderr'] as String,
  );
}

void main() {
  late Directory scratch;
  late String file;

  setUpAll(() {
    scratch = Directory.systemTemp.createTempSync('standard_input_test');
    file = '${scratch.path}/input';
    File(file).writeAsStringSync('r\nq\n');
  });

  tearDownAll(() => scratch.deleteSync(recursive: true));

  group('a process started after the input ends gets a stdin', () {
    test('from a pipe', () async {
      final report = await _readToEnd(bytes: utf8.encode('rq'));
      expect(report.read, 2);
      expect(report.catExitCode, 0, reason: report.catStderr);
    });

    test('from /dev/null', () async {
      final report = await _readToEnd(from: '/dev/null');
      expect(report.read, 0);
      expect(report.catExitCode, 0, reason: report.catStderr);
    });

    test('from a file', () async {
      final report = await _readToEnd(from: file);
      expect(report.read, 4);
      expect(report.catExitCode, 0, reason: report.catStderr);
    });
  });

  // A run that stops reading while its input is still open (`q` on a
  // terminal) has to be able to end. With nothing more typed, the reader is
  // waiting on descriptor 0, and `main` returning does not end the process
  // while it waits.
  test('a process that stops reading ends with its input still open', () async {
    final probe = await Process.start(_probe(), ['stop-reading']);
    probe.stdin.add(utf8.encode('q'));
    await probe.stdin.flush();
    final out = probe.stdout.transform(utf8.decoder).join();
    final code = await probe.exitCode.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        probe.kill(ProcessSignal.sigkill);
        fail('the probe was still running 30 s after it stopped reading');
      },
    );
    expect(code, 0);
    expect(await out, contains('read 1'));
    await probe.stdin.close();
  });
}
