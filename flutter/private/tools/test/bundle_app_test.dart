import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  group('bundle_app', () {
    late Directory tempDir;
    late String scriptPath;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('bundle_app_test_');
      // Resolve relative to this test file's location.
      final thisDir = File(Platform.script.toFilePath()).parent.path;
      scriptPath = '$thisDir/../bundle_app.dart';
      if (!File(scriptPath).existsSync()) {
        // Fallback: running from tools/ directory.
        scriptPath = '${Directory.current.path}/bundle_app.dart';
      }
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    String configPath(Map<String, dynamic> config) {
      final f = File('${tempDir.path}/config.json');
      f.writeAsStringSync(json.encode(config));
      return f.path;
    }

    test('copies files to correct destinations', () async {
      final srcFile = File('${tempDir.path}/source.txt')
        ..writeAsStringSync('hello');
      final outputDir = '${tempDir.path}/output';

      final result = await Process.run('dart', [
        'run',
        scriptPath,
        '--config',
        configPath({
          'output_dir': outputDir,
          'copies': [
            {'src': srcFile.path, 'dst': 'data/source.txt'},
          ],
        }),
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(File('$outputDir/data/source.txt').readAsStringSync(), 'hello');
    });

    test('creates nested output directories', () async {
      final srcFile = File('${tempDir.path}/src.txt')
        ..writeAsStringSync('nested');
      final outputDir = '${tempDir.path}/output';

      await Process.run('dart', [
        'run',
        scriptPath,
        '--config',
        configPath({
          'output_dir': outputDir,
          'copies': [
            {'src': srcFile.path, 'dst': 'a/b/c/deep.txt'},
          ],
        }),
      ]);

      expect(
          File('$outputDir/a/b/c/deep.txt').readAsStringSync(), 'nested');
    });

    test('copies directories recursively', () async {
      final srcDir = Directory('${tempDir.path}/srcdir')..createSync();
      File('${srcDir.path}/file1.txt').writeAsStringSync('one');
      final subDir = Directory('${srcDir.path}/sub')..createSync();
      File('${subDir.path}/file2.txt').writeAsStringSync('two');
      final outputDir = '${tempDir.path}/output';

      await Process.run('dart', [
        'run',
        scriptPath,
        '--config',
        configPath({
          'output_dir': outputDir,
          'copy_dirs': [
            {'src': srcDir.path, 'dst': 'copied'},
          ],
        }),
      ]);

      expect(
          File('$outputDir/copied/file1.txt').readAsStringSync(), 'one');
      expect(
          File('$outputDir/copied/sub/file2.txt').readAsStringSync(), 'two');
    });

    test('creates symlinks', () async {
      final outputDir = '${tempDir.path}/output';

      await Process.run('dart', [
        'run',
        scriptPath,
        '--config',
        configPath({
          'output_dir': outputDir,
          'write_files': [
            {'path': 'target.txt', 'content': 'target content'},
          ],
          'symlinks': [
            {'target': 'target.txt', 'link': 'link.txt'},
          ],
        }),
      ]);

      expect(Link('$outputDir/link.txt').existsSync(), isTrue);
    }, testOn: '!windows');

    test('writes files with content', () async {
      final outputDir = '${tempDir.path}/output';

      await Process.run('dart', [
        'run',
        scriptPath,
        '--config',
        configPath({
          'output_dir': outputDir,
          'write_files': [
            {'path': 'info.txt', 'content': 'generated content'},
          ],
        }),
      ]);

      expect(File('$outputDir/info.txt').readAsStringSync(),
          'generated content');
    });

    test('exits with error on missing config file', () async {
      final result = await Process.run('dart', [
        'run',
        scriptPath,
        '--config',
        '${tempDir.path}/nonexistent.json',
      ]);

      expect(result.exitCode, isNot(0));
    });
  });
}
