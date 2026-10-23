// Tagged `runfiles`: the guard under test imports `package:rules_dart_guard`,
// which Bazel supplies via the `@rules_dart//dart/guard:directive_guard` dep
// its `dart_test` declares. A bare `dart test` resolves only this package's
// pubspec, where that import does not exist, so the file fails to load rather
// than failing a test.
// Coverage comes from //flutter/private/tools:kernel_filter_test.
@Tags(['runfiles'])
library;

import 'dart:io';

import 'package:test/test.dart';

import '../directive_guard.dart';
import '../kernel_filter.dart';

const _id = '53d4fd45-0cd8-4542-bca7-7ba7c9385b70';

void main() {
  group('isBoundaryLine', () {
    test('matches the three lines frontend_server frames a compile with', () {
      expect(isBoundaryLine('result $_id'), isTrue);
      expect(isBoundaryLine(_id), isTrue);
      expect(
        isBoundaryLine('$_id bazel-out/x y/bin/app_flutter.dill 0'),
        isTrue,
      );
    });

    test('keeps everything else', () {
      expect(isBoundaryLine(''), isFalse);
      expect(
        isBoundaryLine('lib/main.dart:3:5: Error: Expected `;`.'),
        isFalse,
      );
      expect(isBoundaryLine('result'), isFalse);
      expect(isBoundaryLine('result $_id extra'), isFalse);
      expect(isBoundaryLine('see $_id'), isFalse);
      expect(isBoundaryLine('$_id out.dill'), isFalse);
    });
  });

  group('splitDependencyLines', () {
    test('separates reads from the rest', () {
      final split = splitDependencyLines(
        'result $_id\n'
        '$_id\n'
        '+file:///work/lib/main.dart\n'
        'lib/main.dart:3:5: Error: boom.\n'
        '+file:///work/lib/foo.dart\n'
        '$_id app_flutter.dill 1\n',
      );
      expect(
        split.reads,
        ['+file:///work/lib/main.dart', '+file:///work/lib/foo.dart'],
      );
      expect(split.rest, contains('Error: boom.'));
      expect(split.rest, isNot(contains(_id)));
      expect(split.rest, isNot(contains('+file://')));
    });
  });

  group('dependencyExecPath', () {
    late Directory savedCwd;

    setUp(() => savedCwd = Directory.current);
    tearDown(() => Directory.current = savedCwd.path);

    test('maps a read under the working directory to its exec path', () {
      final work = Directory.systemTemp.createTempSync('kernel_filter_cwd_');
      addTearDown(() => work.deleteSync(recursive: true));
      Directory.current = work.path;
      File('${work.path}/lib/main.dart').createSync(recursive: true);
      expect(
        dependencyExecPath('+file://${work.path}/lib/main.dart'),
        'lib/main.dart',
      );
    });

    test('decodes percent escapes the way the front end spells them', () {
      final work = Directory.systemTemp.createTempSync('kernel_filter_pct_');
      addTearDown(() => work.deleteSync(recursive: true));
      Directory.current = work.path;
      expect(
        dependencyExecPath('+file://${work.path}/lib/my%20lib.dart'),
        'lib/my lib.dart',
      );
    });

    test('rejects reads outside the working directory', () {
      final work = Directory.systemTemp.createTempSync('kernel_filter_out_');
      addTearDown(() => work.deleteSync(recursive: true));
      Directory.current = work.path;
      expect(dependencyExecPath('+file:///etc/hostname'), isNull);
      expect(dependencyExecPath('+dart:async'), isNull);
      expect(dependencyExecPath('not-a-uri'), isNull);
    });
  });

  group('findUndeclaredReads', () {
    const declared = {
      'app/lib/main.dart',
      'bazel-out/k8-fastbuild/bin/app.dill.stage/app/lib/main.dart',
    };
    const allowed = {'.dart_tool/package_config.json'};

    test('accepts declared and allowed reads spelt exec-root-relative', () {
      final work = Directory.systemTemp.createTempSync('kernel_filter_ru_');
      addTearDown(() => work.deleteSync(recursive: true));
      final saved = Directory.current;
      Directory.current = work.path;
      addTearDown(() => Directory.current = saved.path);
      expect(
        findUndeclaredReads(
          [
            '+file://${work.path}/app/lib/main.dart',
            '+file://${work.path}/.dart_tool/package_config.json',
          ],
          declared,
          allowed,
        ),
        isEmpty,
      );
    });

    test('refuses absolute reads outside the working directory by default', () {
      final work = Directory.systemTemp.createTempSync('kernel_filter_ro_');
      addTearDown(() => work.deleteSync(recursive: true));
      final saved = Directory.current;
      Directory.current = work.path;
      addTearDown(() => Directory.current = saved.path);
      expect(
        findUndeclaredReads(
          ['+file:///tmp/mirror/app/lib/main.dart'],
          declared,
          allowed,
        ),
        ['+file:///tmp/mirror/app/lib/main.dart'],
      );
    });

    test('accepts a created library under a remapped request root', () {
      final parent = Directory.systemTemp.createTempSync('kernel_filter_rm_');
      addTearDown(() => parent.deleteSync(recursive: true));
      final work = Directory('${parent.path}/work')..createSync();
      final mirror = Directory('${parent.path}/mirror')..createSync();
      final saved = Directory.current;
      Directory.current = work.path;
      addTearDown(() => Directory.current = saved.path);
      expect(
        findUndeclaredReads(
          [
            '+file://${mirror.path}/app/lib/main.dart',
            '+file://${mirror.path}/app/lib/new.dart',
            '+file://${work.path}/.dart_tool/package_config.json',
          ],
          declared,
          allowed,
          requestRoots: [mirror.path],
        ),
        isEmpty,
      );
    });

    test('still refuses escapes and outside-root reads with roots given', () {
      final parent = Directory.systemTemp.createTempSync('kernel_filter_rb_');
      addTearDown(() => parent.deleteSync(recursive: true));
      final work = Directory('${parent.path}/work')..createSync();
      final mirror = Directory('${parent.path}/mirror')..createSync();
      final saved = Directory.current;
      Directory.current = work.path;
      addTearDown(() => Directory.current = saved.path);
      final escape = '+file://${mirror.path}/../evil.dart';
      const outside = '+file:///tmp/other/evil.dart';
      expect(
        findUndeclaredReads(
          [escape, outside, '+dart:async'],
          declared,
          allowed,
          requestRoots: ['${mirror.path}/'],
        ),
        [escape, outside, '+dart:async'],
      );
    });
  });

  group('findDisallowedFlutterDirectives', () {
    late Directory work;
    late Directory savedCwd;

    setUp(() {
      savedCwd = Directory.current;
      work = Directory.systemTemp.createTempSync('kernel_filter_guard_');
      Directory.current = work.path;
    });
    tearDown(() {
      Directory.current = savedCwd.path;
      work.deleteSync(recursive: true);
    });

    void write(String rel, String content) {
      File('${work.path}/$rel')
        ..createSync(recursive: true)
        ..writeAsStringSync(content);
    }

    List<String> check(
      Map<String, String> files, [
      List<String> roots = const [],
    ]) {
      for (final entry in files.entries) {
        write(entry.key, entry.value);
      }
      return findDisallowedFlutterDirectives(files.keys.toList(), roots);
    }

    test('accepts package, dart, relative and app-scheme directives', () {
      const helper = 'int get answer => 42;\n';
      write('lib/helper.dart', helper);
      final errors = check({
        'lib/helper.dart': helper,
        'lib/main.dart': '''
import 'package:foo/foo.dart';
import 'dart:async';
import 'helper.dart';
import 'org-dartlang-app:///lib/helper.dart';
void main() {}
''',
      });
      expect(errors, isEmpty);
    });

    test('refuses a file: import of an undeclared workspace file', () {
      write('pkg/lib/secret.dart', 'const secret = 1;\n');
      final errors = check({
        'lib/main.dart': """
import 'file:///proc/self/cwd/pkg/lib/secret.dart';
void main() {}
""",
      });
      expect(errors, hasLength(1));
      expect(errors.single, contains('lib/main.dart'));
      expect(
        errors.single,
        contains("import 'file:///proc/self/cwd/pkg/lib/secret.dart'"),
      );
    });

    test('refuses a file: import of a host path outside the workspace', () {
      final errors = check({
        'lib/main.dart': """
import 'file:///etc/hostname';
void main() {}
""",
      });
      expect(errors, hasLength(1));
      expect(errors.single, contains('is not a declared input'));
    });

    test('refuses file: spellings: case, authority, bare, backslash', () {
      for (final uri in [
        "FILE:///etc/hostname",
        "file://localhost/etc/hostname",
        "file:lib/../secret.dart",
        r"file:lib\..\secret.dart",
        "file:///etc/hostname?query",
        "file:///etc/hostname#fragment",
      ]) {
        final errors = check({
          'lib/main.dart': "import '$uri';\nvoid main() {}\n",
        });
        expect(errors, hasLength(1), reason: uri);
      }
    });

    test('refuses triple-quoted URIs with a whitespace first line', () {
      // The front end drops a whitespace-only first line of a multi-line
      // string literal and reads a different file than the resolvers see, so
      // a scanned URI holding a line break is refused however it spells its
      // target.
      write('secret.dart', 'const secret = 1;\n');
      for (final spelling in [
        "import '''   \n../secret.dart''';",
        'export """\t\n../secret.dart""";',
        "part '''   \n../secret.dart''';",
        "import '''../secret.dart\n''';",
      ]) {
        final errors = check({
          'lib/main.dart': '$spelling\nvoid main() {}\n',
        });
        expect(errors, hasLength(1), reason: spelling);
        expect(errors.single, contains('lib/main.dart'), reason: spelling);
        expect(
          errors.single,
          contains('is not a declared input'),
          reason: spelling,
        );
      }
    });

    test('refuses percent-encoded escapes naming a host file', () {
      final errors = check({
        'lib/main.dart': """
import 'file:///etc%2fhostname';
void main() {}
""",
      });
      expect(errors, hasLength(1));
    });

    test('refuses a relative import climbing out of the declared inputs', () {
      // On the host but declared by no target: readable under every strategy,
      // so only the guard can stop it.
      write('secret.dart', 'const secret = 1;\n');
      final errors = check({
        'lib/main.dart': """
import '../secret.dart';
void main() {}
""",
      });
      expect(errors, hasLength(1));
      expect(errors.single, contains('lib/main.dart'));
      expect(errors.single, contains("import '../secret.dart'"));
    });

    test('refuses an absolute path import', () {
      final errors = check({
        'lib/main.dart': """
import '/etc/hostname';
void main() {}
""",
      });
      expect(errors, hasLength(1));
    });

    test('refuses a package: URI climbing above its package', () {
      final errors = check({
        'lib/main.dart': """
import 'package:foo/../../secret.dart';
void main() {}
""",
      });
      expect(errors, hasLength(1));
    });

    test('refuses a file: URI in an untaken conditional branch', () {
      const helper = 'int get answer => 42;\n';
      write('lib/helper.dart', helper);
      final errors = check({
        'lib/helper.dart': helper,
        'lib/main.dart': """
import 'helper.dart' if (dart.library.html) 'file:///etc/hostname';
import 'helper.dart';
void main() {}
""",
      });
      expect(errors, hasLength(1));
    });

    test('refuses file: exports and parts', () {
      final exportErrors = check({
        'lib/main.dart': """
export 'file:///etc/hostname';
void main() {}
""",
      });
      expect(exportErrors, hasLength(1));
      final partErrors = check({
        'lib/main.dart': "part 'file:///etc/hostname';\nvoid main() {}\n",
      });
      expect(partErrors, hasLength(1));
    });

    test('refuses an app-scheme URI naming no declared key', () {
      const helper = 'int get answer => 42;\n';
      write('lib/helper.dart', helper);
      final errors = check({
        'lib/helper.dart': helper,
        'lib/main.dart': """
import 'org-dartlang-app:///other/unlisted.dart';
import 'helper.dart';
void main() {}
""",
      });
      expect(errors, hasLength(1));
    });

    test('accepts a generated part and its part of, in both directions', () {
      // A declared codegen sibling lives under bazel-out/<config>/bin/ and is
      // staged at its workspace-relative path: the source's `part` and the
      // sibling's `part of` name the same multi-root key the front end looks
      // up, so both directions are declared inputs.
      const stage = 'bazel-out/k8-fastbuild/bin/app.dill.1a2b3c4d.stage';
      final errors = check(
        {
          'lib/user.dart': "part 'user.g.dart';\n",
          'bazel-out/k8-fastbuild/bin/lib/user.g.dart':
              "part of 'user.dart';\n",
        },
        [stage],
      );
      expect(errors, isEmpty);
    });

    test('accepts generated parts in a dependency package', () {
      const stage = 'bazel-out/k8-fastbuild/bin/app.dill.1a2b3c4d.stage';
      final errors = check(
        {
          'dep_part/lib/settings.dart': "part 'settings.g.dart';\n",
          'bazel-out/k8-fastbuild/bin/dep_part/lib/settings.g.dart':
              "part of 'settings.dart';\n",
        },
        [stage],
      );
      expect(errors, isEmpty);
    });

    test('still refuses a part whose generated sibling is undeclared', () {
      final errors = check({
        'lib/user.dart': "part 'user.g.dart';\n",
      });
      expect(errors, hasLength(1));
      expect(errors.single, contains("part 'user.g.dart'"));
    });

    test('refuses a disallowed directive after an invalid byte', () {
      // The front end decodes malformed UTF-8 instead of reporting it, so the
      // guard scans what it can rather than skipping the file.
      final file = File('${work.path}/lib/main.dart')
        ..createSync(recursive: true)
        ..writeAsBytesSync([
          ...'// comment '.codeUnits,
          0xff,
          ...'\nimport \'file:///etc/hostname\';\nvoid main() {}\n'.codeUnits,
        ]);
      final errors = findDisallowedFlutterDirectives([
        'lib/main.dart',
      ], const []);
      expect(errors, hasLength(1));
      expect(errors.single, contains('lib/main.dart'));
      expect(errors.single, contains('is not a declared input'));
      expect(file.existsSync(), isTrue);
    });

    test('accepts a malformed source with no disallowed directive', () {
      // The compiler accepts malformed sources, so a clean one is not refused.
      File('${work.path}/lib/main.dart')
        ..createSync(recursive: true)
        ..writeAsBytesSync([
          ...'// comment '.codeUnits,
          0xff,
          ...'\nvoid main() {}\n'.codeUnits,
        ]);
      final errors = findDisallowedFlutterDirectives([
        'lib/main.dart',
      ], const []);
      expect(errors, isEmpty);
    });

    test('accepts a valid source importing a malformed declared sibling', () {
      // A skipped file would be missing from the declared set, so a valid
      // importer of a malformed sibling would be refused as undeclared.
      File('${work.path}/lib/sibling.dart')
        ..createSync(recursive: true)
        ..writeAsBytesSync([
          ...'// comment '.codeUnits,
          0xff,
          ...'\nint get answer => 42;\n'.codeUnits,
        ]);
      write('lib/main.dart', "import 'sibling.dart';\nvoid main() {}\n");
      final errors = findDisallowedFlutterDirectives([
        'lib/main.dart',
        'lib/sibling.dart',
      ], const []);
      expect(errors, isEmpty);
    });
  });

  group('runFiltered', () {
    late Directory dir;
    late Directory work;
    late Directory savedCwd;

    setUp(() {
      savedCwd = Directory.current;
      dir = Directory.systemTemp.createTempSync('kernel_filter_');
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
      List<String> reads = const [],
      List<String> roots = const [],
      String? output,
    ]) {
      final lines = <String>[
        ...sources,
        '# staged',
        ...staged,
        '# allowed-reads',
        ...reads,
        '# filesystem-roots',
        ...roots,
        '# output',
        if (output != null) output,
      ];
      final manifest = File('${dir.path}/inputs.manifest')
        ..writeAsStringSync('${lines.join('\n')}\n');
      return manifest.path;
    }

    File fakeCompiler(String name, String body) {
      return File('${dir.path}/$name.dart')..writeAsStringSync(body);
    }

    Future<({int code, String out, String err})> run(
      List<String> argv,
    ) async {
      final out = StringBuffer();
      final err = StringBuffer();
      final code = await runFiltered(argv, out, err);
      return (code: code, out: '$out', err: '$err');
    }

    Future<({int code, String out, String err})> runSource(
      String stdoutText,
      int exitCode, {
      List<String> sources = const [],
      List<String> extraArgs = const [],
    }) async {
      final script = fakeCompiler(
        'fake',
        'import "dart:io";\n'
            'void main() {\n'
            '  stdout.write(r"""$stdoutText""");\n'
            '  stderr.writeln("to stderr");\n'
            '  exit($exitCode);\n'
            '}\n',
      );
      return run([
        '--declared-inputs',
        writeManifest(sources),
        '--',
        Platform.resolvedExecutable,
        script.path,
        ...extraArgs,
      ]);
    }

    test('a successful compile prints nothing', () async {
      writeWork('lib/main.dart', 'void main() {}\n');
      final r = await run([
        '--declared-inputs',
        writeManifest(['lib/main.dart']),
        '--',
        Platform.resolvedExecutable,
        fakeCompiler(
          'clean',
          'import "dart:io";\n'
              'void main() {\n'
              '  stdout.writeln("result $_id");\n'
              '  stdout.writeln("$_id");\n'
              '  stdout.writeln("+file://${work.path}/lib/main.dart");\n'
              '  stdout.writeln("$_id app_flutter.dill 0");\n'
              '}\n',
        ).path,
      ]);
      expect(r.code, 0);
      expect(r.out.trim(), isEmpty);
    });

    test('a compile error still shows, with its exit code', () async {
      const error = 'lib/main.dart:3:5: Error: Expected `;` after this.';
      final r = await runSource(
        'result $_id\n$_id\n$error\n$_id app_flutter.dill 1\n',
        1,
      );
      expect(r.code, 1);
      expect(r.out, contains(error));
      expect(r.out, isNot(contains(_id)));
      expect(r.err, contains('to stderr'));
    });

    test('refuses a call with no command', () async {
      final err = StringBuffer();
      expect(await runFiltered(['--'], StringBuffer(), err), 2);
      expect(err.toString(), contains('Usage'));
    });

    test('refuses a call with no declared-inputs manifest', () async {
      final r = await run(['--', Platform.resolvedExecutable, 'x.dart']);
      expect(r.code, 2);
      expect(r.err, contains('--declared-inputs'));
    });

    test('refuses a file: import before running the compiler', () async {
      writeWork('lib/main.dart', """
import 'file:///etc/hostname';
void main() {}
""");
      final invoked = File('${dir.path}/invoked');
      final script = fakeCompiler(
        'counting',
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
        final script = fakeCompiler(
          'counting',
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

    test(
      'fails a read outside the declared inputs and drops the dill',
      () async {
        writeWork('lib/main.dart', 'void main() {}\n');
        final output = File('${work.path}/app.dill')
          ..writeAsStringSync('stale bytes');
        final script = fakeCompiler(
          'reader',
          'import "dart:io";\n'
              'void main() {\n'
              '  stdout.writeln("result $_id");\n'
              '  stdout.writeln("$_id");\n'
              '  stdout.writeln("+file://${work.path}/lib/main.dart");\n'
              '  stdout.writeln("+file:///etc/hostname");\n'
              '  stdout.writeln("$_id app.dill 0");\n'
              '}\n',
        );
        final r = await run([
          '--declared-inputs',
          writeManifest(['lib/main.dart'], [], [], [], 'app.dill'),
          '--',
          Platform.resolvedExecutable,
          script.path,
          '--output-dill',
          output.path,
        ]);
        expect(r.code, 1);
        expect(r.err, contains('+file:///etc/hostname'));
        expect(r.err, contains('not a declared input'));
        expect(output.existsSync(), isFalse);
      },
    );

    test('accepts a read named by the manifest', () async {
      writeWork('lib/main.dart', 'void main() {}\n');
      final summary = File('${work.path}/app_summary.dill')
        ..writeAsStringSync('compiled bytes');
      final script = fakeCompiler(
        'import_reader',
        'import "dart:io";\n'
            'void main() {\n'
            '  stdout.writeln("result $_id");\n'
            '  stdout.writeln("$_id");\n'
            '  stdout.writeln("+file://${work.path}/lib/main.dart");\n'
            '  stdout.writeln("+file://${summary.path}");\n'
            '  stdout.writeln("$_id app.dill 0");\n'
            '}\n',
      );
      final r = await run([
        '--declared-inputs',
        writeManifest(['lib/main.dart'], [], ['app_summary.dill']),
        '--',
        Platform.resolvedExecutable,
        script.path,
        '--output-dill',
        '${work.path}/app.dill',
        '--import-dill=app_summary.dill',
      ]);
      expect(r.code, 0, reason: r.err);
      expect(r.out.trim(), isEmpty);
    });

    test('allows a manifest read the argv never names', () async {
      // The argv carries no `--import-dill` at all: the manifest alone
      // allows the summary read.
      writeWork('lib/main.dart', 'void main() {}\n');
      final summary = File('${work.path}/app_summary.dill')
        ..writeAsStringSync('compiled bytes');
      final script = fakeCompiler(
        'manifest_only_reader',
        'import "dart:io";\n'
            'void main() {\n'
            '  stdout.writeln("result $_id");\n'
            '  stdout.writeln("$_id");\n'
            '  stdout.writeln("+file://${work.path}/lib/main.dart");\n'
            '  stdout.writeln("+file://${summary.path}");\n'
            '  stdout.writeln("$_id app.dill 0");\n'
            '}\n',
      );
      final r = await run([
        '--declared-inputs',
        writeManifest(['lib/main.dart'], [], ['app_summary.dill']),
        '--',
        Platform.resolvedExecutable,
        script.path,
        '--output-dill',
        '${work.path}/app.dill',
      ]);
      expect(r.code, 0, reason: r.err);
      expect(r.out.trim(), isEmpty);
    });

    test('an argv-only flag allow-lists nothing', () async {
      // Every smuggle spelling in the argv — `vm_flags` position (before
      // any snapshot) and `extra_flags` position alike, `=` and space
      // forms — while the manifest names no such read.
      writeWork('lib/main.dart', 'void main() {}\n');
      final sneak = File('${work.path}/sneak.dill')..writeAsStringSync('sneak');
      final output = File('${work.path}/app.dill')
        ..writeAsStringSync('stale bytes');
      final script = fakeCompiler(
        'argv_spoof',
        'import "dart:io";\n'
            'void main() {\n'
            '  stdout.writeln("result $_id");\n'
            '  stdout.writeln("$_id");\n'
            '  stdout.writeln("+file://${work.path}/lib/main.dart");\n'
            '  stdout.writeln("+file://${sneak.path}");\n'
            '  stdout.writeln("$_id app.dill 0");\n'
            '}\n',
      );
      final r = await run([
        '--declared-inputs',
        writeManifest(['lib/main.dart'], [], [], [], 'app.dill'),
        '--',
        Platform.resolvedExecutable,
        script.path,
        '--packages=sneak.dill',
        '--platform',
        'sneak.dill',
        '--from-dill=sneak.dill',
        '--import-dill=sneak.dill',
        '--native-assets',
        'sneak.dill',
        '--output-dill',
        '${work.path}/app.dill',
      ]);
      expect(r.code, 1);
      expect(r.err, contains('+file://${sneak.path}'));
      expect(r.err, contains('not a declared input'));
      expect(output.existsSync(), isFalse);
    });

    test(
      'the refusal deletes the manifest output, not the argv --output-dill',
      () async {
        writeWork('lib/main.dart', 'void main() {}\n');
        final decoy = File('${work.path}/decoy.dill')
          ..writeAsStringSync('decoy bytes');
        final output = File('${work.path}/app.dill')
          ..writeAsStringSync('stale bytes');
        final script = fakeCompiler(
          'spoofed_output',
          'import "dart:io";\n'
              'void main() {\n'
              '  stdout.writeln("result $_id");\n'
              '  stdout.writeln("$_id");\n'
              '  stdout.writeln("+file://${work.path}/lib/main.dart");\n'
              '  stdout.writeln("+file:///etc/hostname");\n'
              '  stdout.writeln("$_id app.dill 0");\n'
              '}\n',
        );
        final r = await run([
          '--declared-inputs',
          writeManifest(['lib/main.dart'], [], [], [], 'app.dill'),
          '--',
          Platform.resolvedExecutable,
          script.path,
          '--output-dill',
          decoy.path,
        ]);
        expect(r.code, 1);
        expect(r.err, contains('+file:///etc/hostname'));
        expect(r.err, contains('not a declared input'));
        expect(decoy.readAsStringSync(), 'decoy bytes');
        expect(output.existsSync(), isFalse);
      },
    );

    test(
      'an undeclared source beside the --import-dill is still refused',
      () async {
        writeWork('lib/main.dart', 'void main() {}\n');
        final summary = File('${work.path}/app_summary.dill')
          ..writeAsStringSync('compiled bytes');
        final script = fakeCompiler(
          'import_sneak_reader',
          'import "dart:io";\n'
              'void main() {\n'
              '  stdout.writeln("result $_id");\n'
              '  stdout.writeln("$_id");\n'
              '  stdout.writeln("+file://${work.path}/lib/main.dart");\n'
              '  stdout.writeln("+file://${summary.path}");\n'
              '  stdout.writeln("+file://${work.path}/lib/sneak.dart");\n'
              '  stdout.writeln("$_id app.dill 0");\n'
              '}\n',
        );
        final r = await run([
          '--declared-inputs',
          writeManifest(['lib/main.dart'], [], ['app_summary.dill']),
          '--',
          Platform.resolvedExecutable,
          script.path,
          '--output-dill',
          '${work.path}/app.dill',
          '--import-dill',
          'app_summary.dill',
        ]);
        expect(r.code, 1);
        expect(r.err, contains('+file://${work.path}/lib/sneak.dart'));
        expect(r.err, contains('not a declared input'));
      },
    );

    test('accepts reads of declared sources and staged copies', () async {
      writeWork('lib/main.dart', 'void main() {}\n');
      final script = fakeCompiler(
        'clean_reader',
        'import "dart:io";\n'
            'void main() {\n'
            '  stdout.writeln("result $_id");\n'
            '  stdout.writeln("$_id");\n'
            '  stdout.writeln("+file://${work.path}/lib/main.dart");\n'
            '  stdout.writeln("$_id app.dill 0");\n'
            '}\n',
      );
      final r = await run([
        '--declared-inputs',
        writeManifest(['lib/main.dart'], ['out/stage/lib/main.dart']),
        '--',
        Platform.resolvedExecutable,
        script.path,
        '--output-dill',
        '${work.path}/app.dill',
      ]);
      expect(r.code, 0, reason: r.err);
      expect(r.out.trim(), isEmpty);
    });

    test(
      'an unavailable plugin fails loudly: no retry, no registrant rewrite',
      () async {
        writeWork('lib/main.dart', 'void main() {}\n');
        final registrant = File('${work.path}/plugin_registrant.dart')
          ..createSync(recursive: true)
          ..writeAsStringSync(
            "import 'package:webby/webby.dart';\n"
            'void register() => WebbyPlugin.registerWith();\n',
          );
        const original = "import 'package:webby/webby.dart';\n";
        final invocations = File('${dir.path}/invocations');
        final script = fakeCompiler(
          'unavailable',
          'import "dart:io";\n'
              'void main() {\n'
              '  File(r"${invocations.path}").writeAsStringSync("x", mode: FileMode.append);\n'
              '  stdout.writeln("result $_id");\n'
              '  stdout.writeln("lib/main.dart: Error: package:webby is not available on this platform.");\n'
              '  stdout.writeln("$_id app.dill 1");\n'
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
        // The frontend's error passes through, with a hint that the build
        // fails instead of shipping without the plugin.
        expect(r.out, contains('is not available on this platform.'));
        expect(r.err, contains('not available on the compiled platform'));
        // No retry: the compiler ran exactly once ...
        expect(invocations.readAsStringSync(), 'x');
        // ... and the registrant is untouched.
        expect(registrant.readAsStringSync(), contains(original));
        expect(
          registrant.readAsStringSync(),
          contains('WebbyPlugin.registerWith();'),
        );
      },
    );

    test(
      'leaves staged flutter_web_plugins sources untouched',
      () async {
        writeWork('lib/main.dart', 'void main() {}\n');
        const originalRegistry =
            "import 'dart:ui_web' as ui_web;\n"
            'void register() => ui_web.setPluginHandler((a, b, c) {});\n';
        final stagedDir = Directory(
          '${work.path}/stage/external/x__flutter_web_plugins/lib',
        )..createSync(recursive: true);
        final stagedRegistry = File('${stagedDir.path}/plugin_registry.dart')
          ..writeAsStringSync(originalRegistry);
        final stub = File('${work.path}/stage/app/plugin_web_ui_web_stub.dart')
          ..createSync(recursive: true)
          ..writeAsStringSync('// stub\n');
        final script = fakeCompiler(
          'nop',
          'import "dart:io";\n'
              'void main() {\n'
              '  stdout.writeln("result $_id");\n'
              '  stdout.writeln("$_id");\n'
              '  stdout.writeln("+file://${work.path}/lib/main.dart");\n'
              '  stdout.writeln("$_id app.dill 0");\n'
              '}\n',
        );
        final r = await run([
          '--declared-inputs',
          writeManifest(['lib/main.dart']),
          '--',
          Platform.resolvedExecutable,
          script.path,
          '--filesystem-root',
          '${work.path}/stage',
          '--filesystem-scheme',
          'org-dartlang-app',
        ]);
        expect(r.code, 0, reason: r.err);
        expect(stagedRegistry.readAsStringSync(), originalRegistry);
        expect(stub.readAsStringSync(), '// stub\n');
      },
    );

    test('fails closed when a successful compile reported no reads', () async {
      // A real compile reads at least its entrypoint: zero `+` lines means
      // the report was silenced, so the build fails instead of caching
      // unverified bytes.
      writeWork('lib/main.dart', 'void main() {}\n');
      final output = File('${work.path}/app.dill')
        ..writeAsStringSync('stale bytes');
      final script = fakeCompiler(
        'silent',
        'import "dart:io";\n'
            'void main() {\n'
            '  stdout.writeln("result $_id");\n'
            '  stdout.writeln("$_id");\n'
            '  stdout.writeln("$_id app.dill 0");\n'
            '}\n',
      );
      final r = await run([
        '--declared-inputs',
        writeManifest(['lib/main.dart'], [], [], [], 'app.dill'),
        '--',
        Platform.resolvedExecutable,
        script.path,
        '--output-dill',
        output.path,
      ]);
      expect(r.code, 1);
      expect(r.err, contains('no dependency reads'));
      expect(r.err, contains('--print-incremental-dependencies'));
      expect(output.existsSync(), isFalse);
    });

    test(
      'forces --print-incremental-dependencies after the caller flags',
      () async {
        writeWork('lib/main.dart', 'void main() {}\n');
        final seen = File('${dir.path}/seen_args.txt');
        final script = fakeCompiler(
          'recorder',
          'import "dart:io";\n'
              'void main(List<String> args) {\n'
              '  File(r"${seen.path}").writeAsStringSync(args.join("\\n"));\n'
              '  stdout.writeln("result $_id");\n'
              '  stdout.writeln("$_id");\n'
              '  stdout.writeln("+file://${work.path}/lib/main.dart");\n'
              '  stdout.writeln("$_id app.dill 0");\n'
              '}\n',
        );
        final r = await run([
          '--declared-inputs',
          writeManifest(['lib/main.dart']),
          '--',
          Platform.resolvedExecutable,
          script.path,
          '--incremental',
          '--no-print-incremental-dependencies',
          'entry.dart',
        ]);
        expect(r.code, 0, reason: r.err);
        final args = seen.readAsStringSync().split('\n');
        final forced = args.lastIndexOf('--print-incremental-dependencies');
        expect(forced, isNot(-1));
        expect(args.last, 'entry.dart');
        expect(forced, args.length - 2);
        expect(
          args.indexOf('--no-print-incremental-dependencies'),
          lessThan(forced),
        );
      },
    );

    test('withForcedDependencyReport inserts the flag before the entry', () {
      expect(withForcedDependencyReport([]), [
        '--print-incremental-dependencies',
      ]);
      expect(withForcedDependencyReport(['script.dart']), [
        'script.dart',
        '--print-incremental-dependencies',
      ]);
      expect(
        withForcedDependencyReport(['snap', '--incremental', 'main.dart']),
        [
          'snap',
          '--incremental',
          '--print-incremental-dependencies',
          'main.dart',
        ],
      );
    });

    test('--incremental does not silence the check', () async {
      // The e2e/smoke consumer passes `--incremental`: an undeclared read
      // beside it is still refused.
      writeWork('lib/main.dart', 'void main() {}\n');
      final script = fakeCompiler(
        'incremental_reader',
        'import "dart:io";\n'
            'void main() {\n'
            '  stdout.writeln("result $_id");\n'
            '  stdout.writeln("$_id");\n'
            '  stdout.writeln("+file://${work.path}/lib/main.dart");\n'
            '  stdout.writeln("+file://${work.path}/lib/sneak.dart");\n'
            '  stdout.writeln("$_id app.dill 0");\n'
            '}\n',
      );
      final r = await run([
        '--declared-inputs',
        writeManifest(['lib/main.dart']),
        '--',
        Platform.resolvedExecutable,
        script.path,
        '--incremental',
      ]);
      expect(r.code, 1);
      expect(r.err, contains('+file://${work.path}/lib/sneak.dart'));
      expect(r.err, contains('not a declared input'));
    });
  });

  group('resolveFlutterKeyRelativeTarget', () {
    test('resolves a sibling against the importing file', () {
      expect(
        resolveFlutterKeyRelativeTarget('b.dart', 'app/lib/main.dart'),
        'app/lib/b.dart',
      );
    });

    test('an empty reference names the importing file itself', () {
      expect(
        resolveFlutterKeyRelativeTarget('', 'app/lib/main.dart'),
        'app/lib/main.dart',
      );
    });

    test('a query resolves its path part', () {
      expect(
        resolveFlutterKeyRelativeTarget('b.dart?x=1', 'app/lib/main.dart'),
        'app/lib/b.dart',
      );
    });

    test('dot segments stay inside the key root', () {
      expect(
        resolveFlutterKeyRelativeTarget('sub/./b.dart', 'app/main.dart'),
        'app/sub/b.dart',
      );
      expect(
        resolveFlutterKeyRelativeTarget('../x.dart', 'app/lib/main.dart'),
        'app/x.dart',
      );
      expect(
        resolveFlutterKeyRelativeTarget('../../x.dart', 'main.dart'),
        'x.dart',
      );
    });

    test('backslashes separate like slashes', () {
      expect(
        resolveFlutterKeyRelativeTarget(r'sub\b.dart', 'app/main.dart'),
        'app/sub/b.dart',
      );
    });

    test('percent escapes decode once', () {
      expect(
        resolveFlutterKeyRelativeTarget('my%20lib.dart', 'app/main.dart'),
        'app/my lib.dart',
      );
    });

    test('refuses non-relative spellings', () {
      expect(
        resolveFlutterKeyRelativeTarget('dart:async', 'app/main.dart'),
        isNull,
      );
      expect(
        resolveFlutterKeyRelativeTarget('package:a/b.dart', 'app/main.dart'),
        isNull,
      );
      expect(
        resolveFlutterKeyRelativeTarget('//x/y.dart', 'app/main.dart'),
        isNull,
      );
      expect(
        resolveFlutterKeyRelativeTarget('/x.dart', 'app/main.dart'),
        isNull,
      );
      expect(
        resolveFlutterKeyRelativeTarget('a.dart#frag', 'app/main.dart'),
        isNull,
      );
    });

    test('refuses an empty path segment', () {
      expect(
        resolveFlutterKeyRelativeTarget('a//b.dart', 'app/main.dart'),
        isNull,
      );
    });

    test('refuses an escape that decodes to a slash', () {
      expect(
        resolveFlutterKeyRelativeTarget('a%2Fb.dart', 'app/main.dart'),
        isNull,
      );
    });
  });

  group('flutterSourceKey', () {
    late Directory savedCwd;

    setUp(() => savedCwd = Directory.current);
    tearDown(() => Directory.current = savedCwd.path);

    test('strips the working directory', () {
      final work = Directory.systemTemp.createTempSync('kernel_filter_key_');
      addTearDown(() => work.deleteSync(recursive: true));
      Directory.current = work.path;
      expect(
        flutterSourceKey('${work.path}/app/lib/main.dart', []),
        'app/lib/main.dart',
      );
    });

    test('strips the longest filesystem root', () {
      expect(
        flutterSourceKey('out.stage/app/lib/main.dart', ['out.stage']),
        'app/lib/main.dart',
      );
      expect(
        flutterSourceKey('a/b/c.dart', ['a', 'a/b']),
        'c.dart',
      );
    });

    test('strips the bazel-out bin prefix', () {
      expect(
        flutterSourceKey('bazel-out/k8-fastbuild/bin/app/lib/main.dart', []),
        'app/lib/main.dart',
      );
    });

    test('a bare root without the slash is not a prefix', () {
      expect(flutterSourceKey('ab/c.dart', ['a']), 'ab/c.dart');
    });

    test('dot roots never strip', () {
      expect(flutterSourceKey('a/b.dart', ['.', '']), 'a/b.dart');
    });
  });

  group('stripFsRootPrefix', () {
    test('strips the longest root with the slash', () {
      expect(stripFsRootPrefix('a/b/c.dart', ['a']), 'b/c.dart');
      expect(stripFsRootPrefix('a/b/c.dart', ['a', 'a/b']), 'c.dart');
    });

    test('keeps paths under no root', () {
      expect(stripFsRootPrefix('ab/c.dart', ['a']), 'ab/c.dart');
      expect(stripFsRootPrefix('a/b.dart', ['.', '']), 'a/b.dart');
    });

    test('strips leading dot-slash and trailing root slashes', () {
      expect(stripFsRootPrefix('./a/b.dart', []), 'a/b.dart');
      expect(stripFsRootPrefix('a/b.dart', ['a/']), 'b.dart');
    });
  });
}
