// A test may start a process that outlives flutter_tester and keeps its
// output open. The target still ends once its suite is reported: this child
// sleeps past the target's timeout, so a runner that waited for the tester's
// output to close would end in TIMEOUT.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test("leaves a child holding the tester's stdout", () async {
    final sh = await Process.start('sh', [
      '-c',
      'sleep 90 &',
    ], mode: ProcessStartMode.inheritStdio);
    expect(await sh.exitCode, 0);
  });
}
