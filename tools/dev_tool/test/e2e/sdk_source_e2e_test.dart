@Tags(['e2e'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'digest_probe.dart';

/// A Flutter SDK package of the lock is fetched from the pinned Flutter source.
///
/// **The property:** `flutter_pub_package` over `flutter_source_files` builds a
/// package out of `packages/<name>` of the Flutter source tarball, and
/// the package's files are at the repository's root as a hosted package's are.
/// Only that package is extracted: nothing else of `packages/` is in the
/// repository. A lock that lists an `sdk: flutter` package the release's
/// source does not have (one not in `packages`, the list
/// versions.bzl records per release) fails the fetch, naming the package, the
/// Flutter version and the command that re-resolves the lock, instead of
/// Bazel's message about archive prefixes.
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
  });
  final digest = sha256Hex(tarball);

  List<ProbeRepo> sdkPackage(String repo, String package) => sdkSourcePackage(
    repo,
    package: package,
    sha256: digest,
    packages: ['flutter_driver', 'integration_test'],
  );

  setUpAll(() async {
    fetcher = await probe(
      archives: {'$fakeFlutterVersion.tar.gz': tarball},
      repos: [
        ...sdkPackage('sdk_integration_test', 'integration_test'),
        ...sdkPackage('sdk_flutter_driver', 'flutter_driver'),
        ...sdkPackage('sdk_absent', 'package_the_release_lacks'),
        // As the extension would declare a Flutter SDK package under an SDK
        // that names neither a Flutter release nor a framework source.
        ProbeRepo('sdk_no_files', 'flutter_pub_package', {
          'package_name': str('integration_test'),
          'version': str('0.0.0'),
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
    'a package given no files fails the fetch, naming it and what it lacks',
    () async {
      final result = await fetcher.fetch('sdk_no_files');
      expect(result.succeeded, isFalse, reason: 'fetched a package of no files');
      expect(
        result.output,
        allOf(contains('integration_test'), contains('`files`')),
        reason: 'the failure does not name the package and its cause\n$result',
      );
    },
  );
}
