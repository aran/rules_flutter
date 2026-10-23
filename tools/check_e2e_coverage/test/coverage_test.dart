/// Unit tests for the e2e workspace coverage check.
library;

import 'dart:io';

import 'package:test/test.dart';

import '../coverage.dart';

/// A fake repo root: two top-level modules, two nested modules sharing the
/// leaf name `dup`, a `bazel-x` symlink pointing at a directory that holds a
/// `MODULE.bazel` (like Bazel's convenience links into the output base), and
/// one workflow covering `foo` and both `dup`s.
Directory _makeTree() {
  final root = Directory.systemTemp.createTempSync('e2e_coverage_');
  void module(String path) {
    final dir = Directory('${root.path}/$path')..createSync(recursive: true);
    File('${dir.path}/MODULE.bazel').writeAsStringSync('');
  }

  File('${root.path}/MODULE.bazel').writeAsStringSync('');
  module('e2e/foo');
  module('e2e/bar');
  module('e2e/a/dup');
  module('e2e/b/dup');
  final target = Directory('${root.path}/outside-target')
    ..createSync(recursive: true);
  File('${target.path}/MODULE.bazel').writeAsStringSync('');
  Link(
    '${root.path}/e2e/foo/bazel-foo',
  ).createSync(target.path, recursive: true);
  final workflows = Directory('${root.path}/.github/workflows')
    ..createSync(recursive: true);
  File('${workflows.path}/ci.yaml').writeAsStringSync('''
jobs:
  a:
    defaults:
      run:
        working-directory: e2e/foo
  b:
    strategy:
      matrix:
        include:
          - workspace: dup
            shard: x
''');
  return root;
}

void main() {
  late Directory root;
  setUp(() => root = _makeTree());
  tearDown(() => root.deleteSync(recursive: true));

  group('findE2eModules', () {
    test('ignores symlinks and keeps same-named nested modules distinct', () {
      final sep = Platform.pathSeparator;
      expect(
        findE2eModules(Directory('${root.path}/e2e'), root.path),
        {
          'e2e${sep}foo',
          'e2e${sep}bar',
          'e2e${sep}a${sep}dup',
          'e2e${sep}b${sep}dup',
        },
      );
    });
  });

  group('findCoveredModules', () {
    test('reads working-directory and matrix references', () {
      expect(
        findCoveredModules(Directory('${root.path}/.github/workflows')),
        {'foo', 'dup'},
      );
    });
  });

  group('checkCoverage', () {
    test('passes when every module is covered or reasoned', () {
      expect(
        checkCoverage(
          modules: {'e2e/foo', 'e2e/bar'},
          covered: {'foo'},
          reasons: {'e2e/bar': 'reason'},
        ),
        isEmpty,
      );
    });

    test('one leaf reference covers every same-named nested module', () {
      expect(
        checkCoverage(
          modules: {'e2e/a/dup', 'e2e/b/dup'},
          covered: {'dup'},
          reasons: const {},
        ),
        isEmpty,
      );
    });

    test('fails on uncovered modules, stale and unknown reasons', () {
      final errors = checkCoverage(
        modules: {'e2e/foo', 'e2e/bar'},
        covered: {'foo', 'ghost'},
        reasons: {'e2e/foo': 'stale', 'e2e/missing': 'unknown'},
      );
      expect(
        errors.join('\n'),
        allOf(
          contains("'e2e/bar' is in no workflow"),
          contains("'e2e/foo' is covered by a workflow"),
          contains("names 'e2e/missing'"),
          contains("references e2e module 'ghost'"),
        ),
      );
    });
  });
}
