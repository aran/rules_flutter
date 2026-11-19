@Tags(['e2e'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'digest_probe.dart';

/// A `path` package whose pubspec names an entry the package's repository
/// writes itself.
///
/// **The property:** the source repository of a Flutter pub package writes its
/// own files at its root (`flutter_pub_member.json`, `BUILD.bazel`, ...), and
/// a package's directory is linked in beside them. A `path` package's entry
/// at one of those names cannot be linked in: the repository's own file would
/// take its place (the package would bundle the generated file as its asset),
/// and a write below a linked directory (`_fonts_of_other_packages/`) would
/// land in the user's checkout. The repository still fetches, as the package
/// may be one no build uses (`bazel fetch --all`), with the checkout
/// untouched; the package's target fails when a build uses it, naming the
/// package and the entry.
void main() {
  late Probe fetcher;
  late Directory package;
  const mine = 'the package\'s own file\n';

  setUpAll(() async {
    package = Directory.systemTemp.createTempSync('reserved_names_');
    addTearDown(() => package.deleteSync(recursive: true));
    File(p.join(package.path, 'pubspec.yaml')).writeAsStringSync(
      'name: reserved\n'
      'version: 1.0.0\n'
      'environment:\n  sdk: ^3.0.0\n'
      'flutter:\n'
      '  assets:\n'
      '    - flutter_pub_member.json\n',
    );
    Directory(p.join(package.path, 'lib')).createSync();
    File(
      p.join(package.path, 'lib', 'reserved.dart'),
    ).writeAsStringSync('const x = 1;\n');
    File(
      p.join(package.path, 'flutter_pub_member.json'),
    ).writeAsStringSync(mine);

    fetcher = await probe(
      repos: [
        ProbeRepo('path_reserved', 'flutter_pub_package', {
          'package_name': str('reserved'),
          'version': str('1.0.0'),
          'directory': str(package.path),
          'lock': str('@@//:pubspec.lock'),
          'path': str(package.path),
        }),
      ],
    );
  });

  test(
    'an entry at a name the repository writes fails the package\'s builds, '
    'and the checkout is untouched',
    () async {
      final result = await fetcher.fetch('path_reserved');
      expect(
        File(p.join(package.path, 'flutter_pub_member.json'))
            .readAsStringSync(),
        mine,
        reason: 'the fetch wrote into the package\'s directory\n$result',
      );
      expect(result.succeeded, isTrue, reason: '$result');
      final build = await fetcher.bazel([
        'build',
        '--nobuild',
        '@path_reserved//:reserved',
      ]);
      expect(build.succeeded, isFalse, reason: 'built the package\n$build');
      expect(
        build.output,
        allOf(
          contains('package reserved'),
          contains('flutter_pub_member.json'),
        ),
        reason: 'the failure does not name the package and the entry\n$build',
      );
    },
  );
}
