import 'dart:io';

import 'package:flutter_bazel_dev_tool/hot_reload/file_clock.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  // The property every mtime cutoff relies on. Only a coarse-clock kernel
  // can break it, so on macOS this passes either way.
  test('a file written after the cutoff is never stamped before it', () async {
    final dir = await Directory.systemTemp.createTemp('file_clock_test_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File(p.join(dir.path, 'saved.txt'));

    final early = <int>[];
    for (var i = 0; i < 500; i++) {
      final cutoff = await fileClockNow();
      file.writeAsStringSync('save $i');
      if (file.statSync().modified.isBefore(cutoff)) early.add(i);
    }
    expect(early, isEmpty, reason: 'writes stamped before their cutoff');
  });
}
