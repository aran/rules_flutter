/// What `package:flutter`'s repository takes from the pubspec it is fetched
/// with, which is read the way pub reads it.
///
/// **The properties:**
///
///  1. The language version is the one `environment.sdk` implies (`^3.11.0-0`
///     is `3.11`), and a pubspec without a constraint gets pub's default
///     (`2.7`), as pub writes for such a package.
///  2. The library depends on the runtime dependencies the lock lists, and on
///     no `dev_dependencies`, whatever comments and nested entries the
///     dependency block has.
///  3. A pubspec pub refuses, or none, leaves the repository fetching (as
///     `bazel fetch --all` needs of every SDK's) and its target failing at
///     analysis, naming the package.
///  4. A release's `package:flutter` whose pubspec forbids the version the
///     build uses of a locked package (it holds `material_color_utilities` at
///     exactly one version) still fetches, so that every SDK's packages do
///     (`bazel fetch --all`); its target fails at analysis, naming the lock
///     that brings the version.
///
/// The Flutter source tarball is served from a distdir, as in
/// `digest_probe.dart`, so no network is involved.
@Tags(['e2e'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'digest_probe.dart';

/// Verbatim `packages/flutter/pubspec.yaml` of a Flutter release, kept whole
/// rather than trimmed: the shapes that break a line-based reader are all here
/// (comments *inside* the dependency block, a nested `sky_engine: {sdk: flutter}`
/// entry, and a `dev_dependencies:` section whose members must not be
/// mistaken for runtime dependencies).
const _flutterPubspec = '''
name: flutter
description: A framework for writing Flutter applications
homepage: https://flutter.dev

environment:
  sdk: ^3.11.0-0

resolution: workspace

dependencies:
  # To update these, use "flutter update-packages --force-upgrade".
  #
  # For detailed instructions, refer to:
  # https://github.com/flutter/flutter/blob/main/docs/infra/Updating-dependencies-in-Flutter.md
  characters: ^1.4.1
  collection: ^1.19.1
  # This is not unpinned currently.
  # See https://github.com/flutter/flutter/issues/185017
  material_color_utilities: 0.13.0
  meta: ^1.18.3
  vector_math: ^2.4.0
  sky_engine:
    sdk: flutter

dev_dependencies:
  flutter_driver:
    sdk: flutter
  flutter_test:
    sdk: flutter
  fake_async: any
  web: any

# PUBSPEC CHECKSUM: i71l78
''';

const _hub = 'probe_hub';

/// Every package a lock could list here: the runtime dependencies and the
/// development ones, so that leaving a development one out is the pubspec
/// reading's doing and not the index's.
const _locked = [
  'characters',
  'collection',
  'material_color_utilities',
  'meta',
  'vector_math',
  'sky_engine',
  'flutter_driver',
  'flutter_test',
  'fake_async',
  'web',
];

/// A fake Flutter release number whose tarball holds `packages/flutter` with
/// [pubspec] (none when null) and one library file, planned against the index
/// of [prefix] (the build's when null).
class _Release {
  _Release(this.version, this.pubspec, {this.prefix}) {
    const root = 'packages/flutter';
    final prefix = 'flutter-$version/$root';
    tarball = tarGzOf({
      if (pubspec != null) '$prefix/pubspec.yaml': pubspec!,
      '$prefix/lib/flutter.dart': 'const x = 1;\n',
    });
  }

  final String version;
  final String? pubspec;
  final String? prefix;
  late final List<int> tarball;

  String get repo => '${_hub}__flutter_$version'.replaceAll('.', '_');

  /// The declaration of the repository and of the release's source packages
  /// it links from, in the probe's module extension.
  String get declaration =>
      """
    flutter_source_packages(
        name = ${str('${repo}_source')},
        flutter_version = ${str(version)},
        sha256 = ${str(sha256Hex(tarball))},
    )
    flutter_framework_package(
        name = ${str(repo)},
        flutter_version = ${str(version)},
        source = ${str('@${repo}_source//:BUILD.bazel')},${prefix == null ? '' : '\n        prefix = ${str(prefix!)},'}
    )
""";
}

void main() {
  late Probe fetcher;

  final releases = {
    'real': _Release('0.0.1', _flutterPubspec),
    'no_constraint': _Release('0.0.2', 'name: flutter\n'),
    'none': _Release('0.0.3', null),
    'wrong_name': _Release('0.0.4', 'name: not_flutter\n'),
    'bad_yaml': _Release('0.0.5', 'name: flutter\ndependencies: [unclosed\n'),
    'raised': _Release('0.0.6', _flutterPubspec, prefix: 'raised'),
  };

  /// What the generated BUILD file of [release]'s repository says.
  Future<String> buildFile(_Release release) async {
    final fetched = await fetcher.fetch(release.repo);
    expect(fetched.succeeded, isTrue, reason: '$fetched');
    final base = await fetcher.bazel(['info', 'output_base']);
    expect(base.succeeded, isTrue, reason: '$base');
    final external = Directory(
      p.join(base.output.trim().split('\n').first, 'external'),
    );
    final matches = external
        .listSync()
        .whereType<Directory>()
        .where((d) => p.basename(d.path).endsWith('+${release.repo}'))
        .toList();
    expect(matches, hasLength(1), reason: 'the repository of ${release.repo}');
    return File(p.join(matches.single.path, 'BUILD.bazel')).readAsStringSync();
  }

  setUpAll(() async {
    fetcher = await probe(
      archives: {
        for (final r in releases.values) '${r.version}.tar.gz': r.tarball,
      },
      repos: [],
      // The framework's repository reads the hub's index by the canonical
      // name of a sibling of the same extension.
      extension:
          """
load("@rules_flutter//flutter/private:generated_repos.bzl", "flutter_framework_package", "flutter_pub_index", "flutter_source_packages")

def _impl(_):
    flutter_pub_index(
        name = 'flutter_pub_index',
        built = [${_locked.map(str).join(', ')}],
        other = [],
    )
    flutter_pub_index(
        name = 'raised_index',
        built = [${_locked.map(str).join(', ')}],
        other = [],
        versions = {'material_color_utilities': '0.14.0'},
        version_locks = {'material_color_utilities': ['@@//tools:pubspec.lock']},
        locks = ['@@//app:pubspec.lock', '@@//tools:pubspec.lock'],
    )
${releases.values.map((r) => r.declaration).join()}
probe = module_extension(implementation = _impl)
""",
      extensionRepos: [
        'flutter_pub_index',
        'raised_index',
        for (final r in releases.values) r.repo,
      ],
    );
  });

  test('the language version is the one environment.sdk implies', () async {
    final build = await buildFile(releases['real']!);
    expect(build, contains('language_version = "3.11",'), reason: build);
  });

  test('a pubspec with no environment.sdk gets pub\'s default', () async {
    final build = await buildFile(releases['no_constraint']!);
    expect(build, contains('language_version = "2.7",'), reason: build);
  });

  test(
    'the runtime dependencies are the library\'s deps, and no others',
    () async {
      final build = await buildFile(releases['real']!);
      final deps =
          RegExp(r'"@[^"]*//:(\w+)"')
              .allMatches(
                RegExp(r'deps = \[[^\]]*\]').firstMatch(build)!.group(0)!,
              )
              .map((m) => m.group(1))
              .toList()
            ..sort();
      expect(deps, [
        'characters',
        'collection',
        'material_color_utilities',
        'meta',
        'sky_engine',
        'vector_math',
      ], reason: build);
    },
  );

  group('a pubspec pub refuses, or none,', () {
    for (final (key, mention) in [
      ('none', 'pubspec.yaml'),
      ('wrong_name', 'doesn\'t match expected name "flutter"'),
      ('bad_yaml', 'pub would refuse'),
    ]) {
      test('fetches, and fails its target naming the package: $key', () async {
        final repo = releases[key]!.repo;
        final fetched = await fetcher.fetch(repo);
        expect(fetched.succeeded, isTrue, reason: '$fetched');
        final result = await fetcher.bazel([
          'build',
          '--nobuild',
          '@$repo//:flutter',
        ]);
        expect(result.succeeded, isFalse, reason: 'built a refused pubspec');
        expect(result.output, contains(mention), reason: '$result');
        expect(result.output, contains('"flutter"'), reason: '$result');
      });
    }
  });

  test(
    'a release\'s pubspec that forbids the version the build uses fetches, '
    'and its target fails naming the lock that brings it',
    () async {
      final repo = releases['raised']!.repo;
      final fetched = await fetcher.fetch(repo);
      expect(fetched.succeeded, isTrue, reason: '$fetched');
      final result = await fetcher.bazel([
        'build',
        '--nobuild',
        '@$repo//:flutter',
      ]);
      expect(result.succeeded, isFalse, reason: 'built past the pin');
      expect(
        result.output,
        allOf(
          contains(
            'package:flutter needs material_color_utilities 0.13.0, and the '
            'build uses material_color_utilities 0.14.0, which '
            '@@//tools:pubspec.lock records',
          ),
          contains('-- get --directory=tools'),
        ),
        reason: '$result',
      );
    },
  );
}
