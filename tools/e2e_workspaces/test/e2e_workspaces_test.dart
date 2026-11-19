import 'dart:io';

import 'package:test/test.dart';

import '../e2e_workspaces.dart';

void main() {
  group('findWorkspaces', () {
    late Directory tmp;
    late Directory e2e;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('find_workspaces');
      e2e = Directory('${tmp.path}/e2e')..createSync();
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    void module(String dir) {
      Directory('${e2e.path}/$dir').createSync(recursive: true);
      File('${e2e.path}/$dir/MODULE.bazel').writeAsStringSync('');
    }

    test('finds workspaces at any depth, sorted', () {
      module('smoke');
      module('nested/inner');
      module('app');
      expect(findWorkspaces(e2e), [
        'e2e/app',
        'e2e/nested/inner',
        'e2e/smoke',
      ]);
    });

    test('ignores directories with no MODULE.bazel', () {
      module('app');
      Directory('${e2e.path}/_compare').createSync();
      expect(findWorkspaces(e2e), ['e2e/app']);
    });

    test('does not look inside a workspace', () {
      module('app');
      module('app/macos/vendored');
      expect(findWorkspaces(e2e), ['e2e/app']);
    });

    test('skips node_modules and bazel output links', () {
      module('node_modules/pkg');
      module('bazel-out/x');
      module('app');
      expect(findWorkspaces(e2e), ['e2e/app']);
    });
  });

  group('readBuildFiles', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('read_build_files'));
    tearDown(() => tmp.deleteSync(recursive: true));

    void file(String path, String text) {
      File('${tmp.path}/$path')
        ..createSync(recursive: true)
        ..writeAsStringSync(text);
    }

    test('reads the BUILD files of every package, whatever their name', () {
      file('BUILD.bazel', 'root');
      file('a/BUILD', 'a');
      file('a/b/c/BUILD.bazel', 'abc');
      file('a/lib/main.dart', 'not a BUILD file');
      expect(readBuildFiles(tmp), unorderedEquals(['root', 'a', 'abc']));
    });

    test('skips node_modules, hidden directories and bazel output links', () {
      file('BUILD.bazel', 'root');
      file('node_modules/x/BUILD', 'x');
      file('.git/BUILD', 'git');
      file('bazel-out/BUILD', 'out');
      expect(readBuildFiles(tmp), ['root']);
    });
  });
}
