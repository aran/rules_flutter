@Tags(['e2e'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'digest_probe.dart';

/// A Flutter SDK package of the lock is fetched from the pinned Flutter source.
///
/// **The property:** `flutter_pub_package` over `flutter_source_files` builds a
/// package out of `packages/<name>` of the Flutter source tarball, and
/// the package's files are at the repository's root as a hosted package's are.
/// Only that package is linked in: nothing else of `packages/` is in the
/// repository. Every SDK package of a release links from the one extraction
/// of its source (`flutter_source_packages`): the tarball holds the whole
/// monorepo, so extracting it for each package would read all of it each
/// time. A files repository of an `sdk: flutter` package the release's
/// source does not have (one not in `packages`, the list versions.bzl records
/// per release) fails the fetch, naming the package, the Flutter version and
/// the command that re-resolves the lock, instead of Bazel's message about
/// archive prefixes. The pub extension declares none for such a package: its
/// target fails with that message when a build of that release uses it.
///
/// What a release's SDK package needs of the locked packages is checked when
/// it is fetched: a version the build uses that the package's pubspec does not
/// allow (`flutter_test` holds `test_api` at exactly one version) leaves the
/// repository fetching, as every SDK's must for `bazel fetch --all`, and its
/// target failing at analysis, naming the SDK, the lock that brings the
/// version and the command that re-resolves it.
///
/// The tarball is served from a distdir, as in `digest_probe.dart`, under the
/// name GitHub's tag archive has, so no network is involved.
void main() {
  late Probe fetcher;

  const root = 'flutter-$fakeFlutterVersion/packages';
  final tarball = tarGzOf({
    '$root/analysis_options.yaml': 'linter:\n',
    '$root/integration_test/pubspec.yaml':
        'name: integration_test\n'
        'environment:\n  sdk: ^3.11.0-0\n',
    '$root/integration_test/lib/integration_test.dart': 'const x = 1;\n',
    '$root/flutter_driver/pubspec.yaml':
        'name: flutter_driver\n'
        'environment:\n  sdk: ^3.11.0-0\n',
    '$root/flutter_driver/lib/flutter_driver.dart': 'const y = 1;\n',
    '$root/flutter_test/pubspec.yaml':
        'name: flutter_test\n'
        'environment:\n  sdk: ^3.11.0-0\n'
        'dependencies:\n  test_api: 0.7.14\n',
    '$root/flutter_test/lib/flutter_test.dart': 'const z = 1;\n',
  });
  final digest = sha256Hex(tarball);
  const source = 'sdk_source';

  List<ProbeRepo> sdkPackage(
    String repo,
    String package, {
    Map<String, String> attrs = const {},
  }) => sdkSourcePackage(
    repo,
    package: package,
    source: source,
    sha256: digest,
    packages: ['flutter_driver', 'flutter_test', 'integration_test'],
    attrs: attrs,
  );

  /// The index of locks that hold `test_api` at [version], which the lock
  /// at [lock] records, and a `flutter_test` of the release planned against
  /// it, as the extension declares them for the SDK "beta".
  List<ProbeRepo> plannedFlutterTest(
    String prefix,
    String version,
    String lock,
  ) => [
    ProbeRepo('${prefix}_index', 'flutter_pub_index', {
      'built': '["flutter_test", "test_api"]',
      'other': '[]',
      'sdk_packages': '["flutter_test"]',
      'versions': strDict({'test_api': version}),
      'version_locks': '{"test_api": [${str(lock)}]}',
      'locks': '[${str(lock)}]',
    }),
    ...sdkPackage(
      '${prefix}_flutter_test',
      'flutter_test',
      attrs: {'sdks': '[${str('beta')}]', 'prefix': str(prefix)},
    ),
  ];

  setUpAll(() async {
    fetcher = await probe(
      archives: {'$fakeFlutterVersion.tar.gz': tarball},
      repos: [
        flutterSourcePackages(source, sha256: digest),
        ...sdkPackage('sdk_integration_test', 'integration_test'),
        ...sdkPackage('sdk_flutter_driver', 'flutter_driver'),
        ...sdkPackage('sdk_absent', 'package_the_release_lacks'),
        ...plannedFlutterTest('pinned', '0.7.14', '@@//app:pubspec.lock'),
        ...plannedFlutterTest('raised', '0.7.15', '@@//tools:pubspec.lock'),
        // As the extension would declare a Flutter SDK package under an SDK
        // that names neither a Flutter release nor a framework source.
        ProbeRepo('sdk_no_files', 'flutter_pub_package', {
          'package_name': str('integration_test'),
          'version': str('0.0.0'),
        }),
        // As the extension declares a Flutter SDK package the SDK lacks.
        ProbeRepo('sdk_stub', 'flutter_pub_package', {
          'package_name': str('integration_test'),
          'version': str('0.0.0'),
          'unusable': str('The release lacks packages/integration_test.'),
        }),
      ],
    );
  });

  for (final (repo, package) in [
    ('sdk_integration_test', 'integration_test'),
    ('sdk_flutter_driver', 'flutter_driver'),
  ]) {
    test('$package: its own files are at the repository root', () async {
      final fetched = await fetcher.fetch(repo);
      expect(fetched.succeeded, isTrue, reason: '$fetched');

      // The package's own sources, found by the glob of the generated target.
      final srcs = await fetcher.bazel([
        'query',
        'labels(srcs, @$repo//:$package)',
      ]);
      expect(srcs.succeeded, isTrue, reason: '$srcs');
      expect(
        srcs.output,
        contains('//:lib/$package.dart'),
        reason: 'the package target does not list its source file:\n$srcs',
      );

      // Nothing else of the source's `packages/`.
      // The repository's directory, from where its BUILD file is.
      final location = await fetcher.bazel([
        'query',
        '--output=location',
        '@$repo//:$package',
      ]);
      expect(location.succeeded, isTrue, reason: '$location');
      final build = RegExp(
        r'^(/\S+)/BUILD\.bazel:',
        multiLine: true,
      ).firstMatch(location.output);
      expect(build, isNotNull, reason: '$location');
      final root = Directory(build![1]!);
      final entries = [
        for (final e in root.listSync()) p.basename(e.path),
      ];
      expect(entries, contains('pubspec.yaml'), reason: '${root.path}');
      for (final other in [
        'analysis_options.yaml',
        'flutter_driver',
        'integration_test',
      ]) {
        if (other == package) continue;
        expect(entries, isNot(contains(other)), reason: '${root.path}');
      }
    });
  }

  test(
    'the packages of a release link from one extraction of its source',
    () async {
      // Where each package's pubspec really is, through the links of its
      // source repository and its files repository.
      final extracted = <String>{};
      for (final (repo, package) in [
        ('sdk_integration_test', 'integration_test'),
        ('sdk_flutter_driver', 'flutter_driver'),
      ]) {
        final fetched = await fetcher.fetch(repo);
        expect(fetched.succeeded, isTrue, reason: '$fetched');
        final location = await fetcher.bazel([
          'query',
          '--output=location',
          '@$repo//:$package',
        ]);
        expect(location.succeeded, isTrue, reason: '$location');
        final root = RegExp(
          r'^(/\S+)/BUILD\.bazel:',
          multiLine: true,
        ).firstMatch(location.output)![1]!;
        final pubspec = File(
          p.join(root, 'pubspec.yaml'),
        ).resolveSymbolicLinksSync();
        expect(p.basename(p.dirname(pubspec)), package, reason: pubspec);
        extracted.add(p.dirname(p.dirname(pubspec)));
      }
      expect(
        extracted,
        hasLength(1),
        reason: 'each package was extracted on its own: $extracted',
      );
    },
  );

  test(
    'a package the release lacks fails the fetch, saying how to fix it',
    () async {
      final result = await fetcher.fetch('sdk_absent');
      expect(result.succeeded, isFalse, reason: 'fetched a package not there');
      expect(result.output, contains('package_the_release_lacks'));
      expect(result.output, contains('Flutter $fakeFlutterVersion'));
      expect(
        result.output,
        contains('packages/package_the_release_lacks'),
        reason: '$result',
      );
      expect(
        result.output,
        contains('bazel run @rules_flutter//flutter/pub -- get'),
        reason: 'the failure does not say how to re-resolve the lock\n$result',
      );
    },
  );

  test(
    'a package the SDK lacks fetches, with the records every package has, '
    'and its target fails saying why',
    () async {
      final fetched = await fetcher.fetch('sdk_stub');
      expect(fetched.succeeded, isTrue, reason: '$fetched');
      final location = await fetcher.bazel([
        'query',
        '--output=location',
        '@sdk_stub//:integration_test',
      ]);
      expect(location.succeeded, isTrue, reason: '$location');
      final root = RegExp(
        r'^(/\S+)/BUILD\.bazel:',
        multiLine: true,
      ).firstMatch(location.output)![1]!;
      // Every built package's Maven records are read by an Android build's
      // check, whatever package it is.
      final maven = jsonDecode(
        File(
          p.join(root, 'flutter_android_maven_deps.json'),
        ).readAsStringSync(),
      ) as Map<String, Object?>;
      expect(maven['deps'], isEmpty);
      expect(maven['unread'], isEmpty);
      final member = jsonDecode(
        File(p.join(root, 'flutter_pub_member.json')).readAsStringSync(),
      ) as Map<String, Object?>;
      expect(member['kind'], 'stub');

      final build = await fetcher.bazel([
        'build',
        '--nobuild',
        '@sdk_stub//:integration_test',
      ]);
      expect(build.succeeded, isFalse, reason: 'built a package not there');
      expect(
        build.output,
        contains('The release lacks packages/integration_test.'),
        reason: '$build',
      );
    },
  );

  test(
    'a package given no files fails the fetch, naming it and what it lacks',
    () async {
      final result = await fetcher.fetch('sdk_no_files');
      expect(
        result.succeeded,
        isFalse,
        reason: 'fetched a package of no files',
      );
      expect(
        result.output,
        allOf(contains('integration_test'), contains('`files`')),
        reason: 'the failure does not name the package and its cause\n$result',
      );
    },
  );

  test(
    'a release\'s package that allows the version the build uses fetches',
    () async {
      final result = await fetcher.fetch('pinned_flutter_test');
      expect(result.succeeded, isTrue, reason: '$result');
    },
  );

  test(
    'a release\'s package that forbids the version the build uses fetches, '
    'and its target fails naming the SDK, the lock and the command',
    () async {
      final fetched = await fetcher.fetch('raised_flutter_test');
      expect(fetched.succeeded, isTrue, reason: '$fetched');
      final result = await fetcher.bazel([
        'build',
        '--nobuild',
        '@raised_flutter_test//:flutter_test',
      ]);
      expect(result.succeeded, isFalse, reason: 'built past the pin');
      expect(
        result.output,
        allOf(
          contains('"beta" Flutter SDK'),
          contains(
            'package:flutter_test needs test_api 0.7.14, and the build uses '
            'test_api 0.7.15, which @@//tools:pubspec.lock records',
          ),
          contains(
            'bazel run --@rules_flutter//flutter:sdk=beta '
            '@rules_flutter//flutter/pub -- get --directory=tools',
          ),
        ),
        reason: '$result',
      );
    },
  );
}
