import 'dart:io';

import 'package:flutter_bazel_dev_tool/process_cpu_time.dart';
import 'package:test/test.dart';

void main() {
  group('parsePsCpuTime', () {
    test('reads minutes and fractional seconds', () {
      expect(
        parsePsCpuTime('0:01.26'),
        const Duration(seconds: 1, milliseconds: 260),
      );
    });

    test('reads hours', () {
      expect(
        parsePsCpuTime('1:02:03.50'),
        const Duration(hours: 1, minutes: 2, seconds: 3, milliseconds: 500),
      );
    });

    test('reads days', () {
      expect(
        parsePsCpuTime('2-01:00:00'),
        const Duration(days: 2, hours: 1),
      );
    });
  });

  group('readProcessCpuTime', () {
    test('advances while this process works', () async {
      // Spins until the reading moves rather than for a set wall time: on a
      // loaded machine this process gets a fraction of a core, which is the
      // situation the reading exists for.
      final before = await readProcessCpuTime(pid);
      var after = before;
      var x = 0;
      while (after - before < const Duration(milliseconds: 100)) {
        final spin = Stopwatch()..start();
        while (spin.elapsedMilliseconds < 50) {
          x = (x * 31 + 7) & 0xffffff;
        }
        after = await readProcessCpuTime(pid);
      }
      expect(x, isNonNegative);
      expect(after, greaterThan(before));
    });

    test('names a process that does not exist', () async {
      final exited = Platform.isWindows
          ? await Process.start('cmd', ['/c', 'exit'])
          : await Process.start('true', []);
      await exited.exitCode;
      await expectLater(
        readProcessCpuTime(exited.pid),
        throwsA(isA<ProcessCpuTimeException>()),
      );
    });
  });
}
