/// The reading of `bzl_library` calls and `load()` statements, and the check
/// built on it, on small inputs.
library;

import 'package:test/test.dart';

import '../bzl_library_deps.dart';

List<String> _check(
  Map<String, String> builds,
  Map<String, String> bzls, {
  ExternalExceptions exceptions = const ExternalExceptions(),
}) {
  final libraries = [
    for (final e in builds.entries) ...bzlLibrariesOf(e.key, e.value),
  ];
  return checkBzlLibraries(
    libraries,
    readBzl: (file) => bzls['${file.pkg}/${file.name}']!,
    exceptions: exceptions,
  );
}

void main() {
  group('loadsOf', () {
    test('reads single and multi-line loads, and ignores comments', () {
      expect(
        loadsOf('''
"""Docstring with load("//not:real.bzl", "x")."""

# load("//commented:out.bzl", "y")
load("//a:one.bzl", "one")
load(
    "@repo//b:two.bzl",
    "two",  # load("//nope:nope.bzl")
    three = "four",
)
load(":three.bzl", "three")

def f():
    return "load(\\"//in:string.bzl\\")"
'''),
        ['//a:one.bzl', '@repo//b:two.bzl', ':three.bzl'],
      );
    });
  });

  group('bzlLibrariesOf', () {
    test('reads name, srcs and deps as normalised labels', () {
      final libs = bzlLibrariesOf('pkg', '''
bzl_library(
    name = "a",
    srcs = ["a.bzl"],
    deps = [
        ":b",
        "//other:c",
        "@rules_flutter//third:d",
        "@ext//lib:e",
    ],
)
bzl_library(name = "b", srcs = ["b.bzl"])
''');
      expect(libs.map((l) => l.label.toString()), ['//pkg:a', '//pkg:b']);
      expect(libs[0].srcs.map((l) => l.toString()), ['//pkg:a.bzl']);
      expect(libs[0].deps.map((l) => l.toString()), [
        '//pkg:b',
        '//other:c',
        '//third:d',
        '@ext//lib:e',
      ]);
      expect(libs[1].deps, isEmpty);
    });

    test('refuses a srcs that is not a literal list', () {
      expect(
        () => bzlLibrariesOf('pkg', '''
bzl_library(
    name = "a",
    srcs = glob(["*.bzl"]),
)
'''),
        throwsFormatException,
      );
    });
  });

  group('checkBzlLibraries', () {
    const build = '''
bzl_library(name = "a", srcs = ["a.bzl"], deps = [":b", "@ext//lib:e"])
bzl_library(name = "b", srcs = ["b.bzl"])
''';
    final bzls = {
      'pkg/a.bzl': 'load(":b.bzl", "b")\nload("@ext//lib:e.bzl", "e")\n',
      'pkg/b.bzl': '',
    };

    test('accepts complete deps', () {
      expect(_check({'pkg': build}, bzls), isEmpty);
    });

    test('names a missing internal dep', () {
      final problems = _check({
        'pkg': build.replaceFirst('":b", ', ''),
      }, bzls);
      expect(problems, hasLength(1));
      expect(problems.single, contains('missing dep //pkg:b'));
    });

    test('names a missing external dep', () {
      final problems = _check({
        'pkg': build.replaceFirst(', "@ext//lib:e"', ''),
      }, bzls);
      expect(problems.single, contains('missing dep @ext//lib:e'));
    });

    test('names a dep nothing loads from', () {
      final problems = _check(
        {
          'pkg':
              build.replaceFirst('":b", ', '":b", ":c", ') +
              'bzl_library(name = "c", srcs = ["c.bzl"])\n',
        },
        {...bzls, 'pkg/c.bzl': ''},
      );
      expect(problems.single, contains('dep //pkg:c is not needed'));
    });

    test('a load of a sibling file in the same library needs no dep', () {
      expect(
        _check(
          {'pkg': 'bzl_library(name = "ab", srcs = ["a.bzl", "b.bzl"])\n'},
          {'pkg/a.bzl': 'load(":b.bzl", "b")\n', 'pkg/b.bzl': ''},
        ),
        isEmpty,
      );
    });

    test('a load no bzl_library holds is reported', () {
      final problems = _check(
        {'pkg': 'bzl_library(name = "a", srcs = ["a.bzl"])\n'},
        {'pkg/a.bzl': 'load("//pkg:loose.bzl", "x")\n'},
      );
      expect(problems.single, contains('no bzl_library'));
    });

    test('loads across packages resolve through the other BUILD file', () {
      expect(
        _check(
          {
            'one':
                'bzl_library(name = "a", srcs = ["a.bzl"], '
                'deps = ["//two:b"])\n',
            'two': 'bzl_library(name = "b", srcs = ["b.bzl"])\n',
          },
          {'one/a.bzl': 'load("//two:b.bzl", "b")\n', 'two/b.bzl': ''},
        ),
        isEmpty,
      );
    });

    test('exceptions: another name, and no library at all', () {
      expect(
        _check(
          {
            'pkg':
                'bzl_library(name = "a", srcs = ["a.bzl"], '
                'deps = ["@ext//lib:everything"])\n',
          },
          {
            'pkg/a.bzl':
                'load("@ext//lib:e.bzl", "e")\n'
                'load("@gen//:version.bzl", "v")\n',
          },
          exceptions: const ExternalExceptions(
            library: {'@ext//lib:e.bzl': '@ext//lib:everything'},
            noLibrary: {'@gen//:version.bzl': 'generated'},
          ),
        ),
        isEmpty,
      );
    });
  });
}
