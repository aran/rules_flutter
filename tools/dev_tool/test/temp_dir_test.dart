import 'dart:io';

import 'package:flutter_bazel_dev_tool/temp_dir.dart';
import 'package:test/test.dart';

void main() {
  group('withTempDir', () {
    test('removes the directory after the body returns', () async {
      late final Directory seen;
      final result = await withTempDir('dev_tool_test_', (dir) async {
        seen = dir;
        File('${dir.path}/scratch.json').writeAsStringSync('{}');
        return dir.path;
      });

      expect(result, seen.path);
      expect(seen.existsSync(), isFalse);
    });

    test('removes the directory when the body throws', () async {
      late final Directory seen;
      await expectLater(
        withTempDir<void>('dev_tool_test_', (dir) async {
          seen = dir;
          File('${dir.path}/half-written').writeAsStringSync('partial');
          throw StateError('subprocess failed');
        }),
        throwsA(isA<StateError>()),
      );

      expect(seen.existsSync(), isFalse);
    });

    test('gives each call its own directory', () async {
      final first = await withTempDir(
        'dev_tool_test_',
        (dir) async => dir.path,
      );
      final second = await withTempDir(
        'dev_tool_test_',
        (dir) async => dir.path,
      );
      expect(first, isNot(second));
    });
  });

  group('deleteTempDir', () {
    test('removes a directory and everything under it', () async {
      final dir = await createTempDir('dev_tool_test_');
      Directory('${dir.path}/nested/deeper').createSync(recursive: true);
      File('${dir.path}/nested/deeper/file.txt').writeAsStringSync('content');

      await deleteTempDir(dir);

      expect(dir.existsSync(), isFalse);
    });

    // Deleting twice is the normal shape of a teardown that runs on more than
    // one path — an error there would turn tidying up into a failed run.
    test('is silent about a directory that is already gone', () async {
      final dir = await createTempDir('dev_tool_test_');
      await deleteTempDir(dir);
      await deleteTempDir(dir);
      expect(dir.existsSync(), isFalse);
    });
  });
}
