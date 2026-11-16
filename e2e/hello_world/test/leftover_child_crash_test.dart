// flutter_tester dies while a process the test started holds its output. What
// it wrote before dying still reaches the target's output, and the target
// ends without waiting for that process. Meant to fail: `stray_output_test`
// runs it, and records the process id in `$STRAY_PID_FILE`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test("dies while a child holds the tester's output", () async {
    final sh = await Process.start('sh', [
      '-c',
      r'sleep 90 & echo $! > "$STRAY_PID_FILE"',
    ], mode: ProcessStartMode.inheritStdio);
    expect(await sh.exitCode, 0);
    stderr.writeln('leftover_child_crash: last words before exit(3)');
    await stderr.flush();
    exit(3);
  });
}
