// Tagged `runfiles`: the guard under test imports `package:rules_dart_guard`,
// which Bazel supplies via the `@rules_dart//dart/guard:directive_guard` dep
// its `dart_test` declares. A bare `dart test` resolves only this package's
// pubspec, where that import does not exist, so the file fails to load rather
// than failing a test.
// Coverage comes from //flutter/private/tools:web_guard_test.
@Tags(['runfiles'])
library;

import 'dart:io';

import 'package:test/test.dart';

import '../web_guard.dart';

void main() {
  group('runGuarded', () {
    late Directory dir;
    late Directory work;
    late Directory savedCwd;

    setUp(() {
      savedCwd = Directory.current;
      dir = Directory.systemTemp.createTempSync('web_guard_');
      work = Directory('${dir.path}/work')..createSync();
      Directory.current = work.path;
    });
    tearDown(() {
      Directory.current = savedCwd.path;
      dir.deleteSync(recursive: true);
    });

    void writeWork(String rel, String content) {
      File('${work.path}/$rel')
        ..createSync(recursive: true)
        ..writeAsStringSync(content);
    }

    String writeManifest(
      List<String> sources, [
      List<String> staged = const [],
    ]) {
      final manifest = File('${dir.path}/inputs.manifest')
        ..writeAsStringSync(
          '${sources.join('\n')}\n# staged\n${staged.join('\n')}\n',
        );
      return manifest.path;
    }

    Future<({int code, String out, String err})> run(
      List<String> argv,
    ) async {
      final out = StringBuffer();
      final err = StringBuffer();
      final code = await runGuarded(argv, out, err);
      return (code: code, out: '$out', err: '$err');
    }

    test('a successful compile passes its output through', () async {
      writeWork('lib/main.dart', 'void main() {}\n');
      final script = File('${dir.path}/fake.dart')
        ..writeAsStringSync(
          'import "dart:io";\n'
          'void main() {\n'
          '  stdout.write("compiled ok\\n");\n'
          '  stderr.writeln("to stderr");\n'
          '}\n',
        );
      final r = await run([
        '--declared-inputs',
        writeManifest(['lib/main.dart']),
        '--',
        Platform.resolvedExecutable,
        script.path,
        '--multi-root=out.stage',
      ]);
      expect(r.code, 0);
      expect(r.out, contains('compiled ok'));
      expect(r.err, contains('to stderr'));
    });

    test('a compile error still shows, with its exit code', () async {
      writeWork('lib/main.dart', 'void main() {}\n');
      final script = File('${dir.path}/fake.dart')
        ..writeAsStringSync(
          'import "dart:io";\n'
          'void main() {\n'
          '  stdout.write("lib/main.dart:3:5: Error: boom.\\n");\n'
          '  exit(1);\n'
          '}\n',
        );
      final r = await run([
        '--declared-inputs',
        writeManifest(['lib/main.dart']),
        '--',
        Platform.resolvedExecutable,
        script.path,
      ]);
      expect(r.code, 1);
      expect(r.out, contains('Error: boom.'));
    });

    test('refuses a call with no command', () async {
      final err = StringBuffer();
      expect(await runGuarded(['--'], StringBuffer(), err), 2);
      expect(err.toString(), contains('Usage'));
    });

    test('refuses a call with no declared-inputs manifest', () async {
      final r = await run(['--', Platform.resolvedExecutable, 'x.dart']);
      expect(r.code, 2);
      expect(r.err, contains('--declared-inputs'));
    });

    test('refuses a call with a missing manifest', () async {
      final r = await run([
        '--declared-inputs',
        '${dir.path}/no-such.manifest',
        '--',
        Platform.resolvedExecutable,
        'x.dart',
      ]);
      expect(r.code, 2);
      expect(r.err, contains('does not exist'));
    });

    test('refuses a file: import before running the compiler', () async {
      writeWork('lib/main.dart', """
import 'file:///etc/hostname';
void main() {}
""");
      final invoked = File('${dir.path}/invoked');
      final script = File('${dir.path}/counting.dart')
        ..writeAsStringSync(
          'import "dart:io";\n'
          'void main() {\n'
          '  File(r"${invoked.path}").writeAsStringSync("ran");\n'
          '}\n',
        );
      final r = await run([
        '--declared-inputs',
        writeManifest(['lib/main.dart']),
        '--',
        Platform.resolvedExecutable,
        script.path,
      ]);
      expect(r.code, 1);
      expect(r.err, contains('lib/main.dart'));
      expect(r.err, contains("import 'file:///etc/hostname'"));
      expect(r.err, contains('is not a declared input'));
      expect(invoked.existsSync(), isFalse);
    });

    test(
      'refuses a triple-quoted import with a whitespace first line before running the compiler',
      () async {
        writeWork('secret.dart', 'const secret = 1;\n');
        writeWork(
          'lib/main.dart',
          "import '''   \n../secret.dart''';\nvoid main() {}\n",
        );
        final invoked = File('${dir.path}/invoked');
        final script = File('${dir.path}/counting.dart')
          ..writeAsStringSync(
            'import "dart:io";\n'
            'void main() {\n'
            '  File(r"${invoked.path}").writeAsStringSync("ran");\n'
            '}\n',
          );
        final r = await run([
          '--declared-inputs',
          writeManifest(['lib/main.dart']),
          '--',
          Platform.resolvedExecutable,
          script.path,
        ]);
        expect(r.code, 1);
        expect(r.err, contains('lib/main.dart'));
        expect(r.err, contains('is not a declared input'));
        expect(invoked.existsSync(), isFalse);
      },
    );

    for (final spelling in [
      "import 'file:///etc/hostname';",
      "import 'FILE:///etc/hostname';",
      "import 'file://localhost/etc/hostname';",
      "import 'file:lib/../secret.dart';",
      "import '../secret.dart';",
      "import '/etc/hostname';",
      "import '//host/secret.dart';",
      "import 'package:foo/../../secret.dart';",
      "import 'org-dartlang-app:///other/unlisted.dart';",
      "import 'file:///etc/hostname?query';",
      "export 'file:///etc/hostname';",
      "part 'file:///etc/hostname';",
    ]) {
      test('refuses $spelling before running the compiler', () async {
        writeWork('pkg/lib/secret.dart', 'const secret = 1;\n');
        writeWork('secret.dart', 'const secret = 1;\n');
        writeWork('lib/helper.dart', 'int get answer => 42;\n');
        writeWork('lib/main.dart', "$spelling\nvoid main() {}\n");
        final invoked = File('${dir.path}/invoked');
        final script = File('${dir.path}/counting.dart')
          ..writeAsStringSync(
            'import "dart:io";\n'
            'void main() {\n'
            '  File(r"${invoked.path}").writeAsStringSync("ran");\n'
            '}\n',
          );
        final r = await run([
          '--declared-inputs',
          writeManifest(['lib/main.dart', 'lib/helper.dart']),
          '--',
          Platform.resolvedExecutable,
          script.path,
        ]);
        expect(r.code, 1, reason: spelling);
        expect(r.err, contains('is not a declared input'), reason: spelling);
        expect(invoked.existsSync(), isFalse, reason: spelling);
      });
    }

    test('refuses an untaken conditional file: import', () async {
      writeWork('lib/helper.dart', 'int get answer => 42;\n');
      writeWork('lib/main.dart', """
import 'helper.dart' if (dart.library.html) 'file:///etc/hostname';
import 'helper.dart';
void main() {}
""");
      final r = await run([
        '--declared-inputs',
        writeManifest(['lib/main.dart', 'lib/helper.dart']),
        '--',
        Platform.resolvedExecutable,
        '${dir.path}/never.dart',
      ]);
      expect(r.code, 1);
      expect(r.err, contains('is not a declared input'));
    });

    test('fails closed on a source that is not decodable text', () async {
      final bytes = <int>[
        ...'// '.codeUnits,
        0xff,
        ..."\nimport 'file:///etc/hostname';\nvoid main() {}\n".codeUnits,
      ];
      File('${work.path}/lib/bad.dart')
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes);
      final invoked = File('${dir.path}/invoked');
      final script = File('${dir.path}/counting.dart')
        ..writeAsStringSync(
          'import "dart:io";\n'
          'void main() {\n'
          '  File(r"${invoked.path}").writeAsStringSync("ran");\n'
          '}\n',
        );
      final r = await run([
        '--declared-inputs',
        writeManifest(['lib/bad.dart']),
        '--',
        Platform.resolvedExecutable,
        script.path,
      ]);
      expect(r.code, 1);
      expect(r.err, contains('lib/bad.dart'));
      expect(invoked.existsSync(), isFalse);
    });

    test(
      'accepts clean relative, package, dart and app-scheme sources',
      () async {
        const helper = 'int get answer => 42;\n';
        writeWork('lib/helper.dart', helper);
        writeWork('lib/main.dart', '''
import 'package:foo/foo.dart';
import 'dart:async';
import 'helper.dart';
import 'org-dartlang-app:///lib/helper.dart';
void main() {}
''');
        final script = File('${dir.path}/ok.dart')
          ..writeAsStringSync('void main() {}\n');
        final r = await run([
          '--declared-inputs',
          writeManifest(
            ['lib/main.dart', 'lib/helper.dart'],
            ['stage/lib/main.dart', 'stage/lib/helper.dart'],
          ),
          '--',
          Platform.resolvedExecutable,
          script.path,
          '--multi-root=stage',
        ]);
        expect(r.code, 0);
        expect(r.err, isNot(contains('is not a declared input')));
      },
    );
  });
}
