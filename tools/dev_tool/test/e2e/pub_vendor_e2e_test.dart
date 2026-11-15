@Tags(['e2e'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'digest_probe.dart';

/// `bazel vendor` makes a pub package vendored as it would be fetched.
///
/// **The property:** a hosted pub package's source repository, and a Flutter
/// SDK package's, link their files in from a repository of their own. A
/// vendored source repository is never fetched again, so nothing but its BUILD
/// file can make Bazel set up that files repository in a new output base
/// before the repository's globs read through the links; a glob that reads
/// first finds no file (`lib/**` matches nothing). So a build from the
/// vendored directory, in an output base that has never fetched anything,
/// after the output base that vendored is deleted, sees each package's
/// sources, and no vendored link names the output base that vendored.
///
/// The bytes come from a distdir and a `file://` registry, as the other pub
/// tests have them, and the build of a package is a query of its `srcs`: the
/// glob is what reads through the links.
void main() {
  const hostedRepo = 'hosted';
  const sdkRepo = 'sdk';
  const targets = ['@$hostedRepo//:sample', '@$sdkRepo//:integration_test'];

  late Probe fetcher;
  late Directory scratch;
  late String vendor;
  late String vendoring;
  late String building;
  late FetchResult built;

  // Repositories are made in the output base, not taken from the shared
  // contents cache, whose copies would outlive the output base that made them.
  const common = ['--repo_contents_cache=', '--noshow_progress', '--curses=no'];

  // Not for an output base already deleted, which Bazel would make again.
  Future<void> shutdown(String outputBase) async {
    if (!Directory(outputBase).existsSync()) return;
    await Process.run('bazel', [
      '--output_base=$outputBase',
      'shutdown',
    ], workingDirectory: fetcher.root);
  }

  // Deletes only a directory Bazel marks as built for the probe's workspace.
  Future<void> remove(String outputBase) async {
    if (!Directory(outputBase).existsSync()) return;

    // Bazel writes the workspace's real path, which is not the temporary
    // directory's where that is a link (macOS).
    final mark = File(p.join(outputBase, 'DO_NOT_BUILD_HERE'));
    if (!mark.existsSync() ||
        mark.readAsStringSync() !=
            Directory(fetcher.root).resolveSymbolicLinksSync()) {
      stdout.writeln("not removing '$outputBase': not this test's output base");
      return;
    }
    await Process.run('chmod', ['-R', 'u+w', outputBase]);
    Directory(outputBase).deleteSync(recursive: true);
  }

  setUpAll(() async {
    final flutterSource = tarGzOf({
      'flutter-$fakeFlutterVersion/packages/integration_test/pubspec.yaml':
          'name: integration_test\nenvironment:\n  sdk: ^3.0.0\n',
      'flutter-$fakeFlutterVersion/packages/integration_test/lib/integration_test.dart':
          'const x = 1;\n',
    });
    final pubArchive = tarGzOf({
      'pubspec.yaml':
          'name: sample\nversion: 1.0.0\nenvironment:\n  sdk: ^3.0.0\n',
      'lib/sample.dart': 'const x = 1;\n',
    });
    final registry = await servePubArchive('sample', '1.0.0', pubArchive);

    fetcher = await probe(
      archives: {'$fakeFlutterVersion.tar.gz': flutterSource},
      repos: [
        ...hostedPubPackage(
          hostedRepo,
          package: 'sample',
          version: '1.0.0',
          sha256: sha256Hex(pubArchive),
          baseUrl: registry,
        ),
        ...sdkSourcePackage(
          sdkRepo,
          package: 'integration_test',
          sha256: sha256Hex(flutterSource),
          packages: ['integration_test'],
        ),
      ],
    );

    scratch = Directory(
      Directory.systemTemp
          .createTempSync('pub_vendor_')
          .resolveSymbolicLinksSync(),
    );
    vendor = p.join(scratch.path, 'vendor');
    vendoring = p.join(scratch.path, 'output_base_vendoring');
    building = p.join(scratch.path, 'output_base_building');
    addTearDown(() async {
      await shutdown(vendoring);
      await shutdown(building);
      await remove(vendoring);
      await remove(building);
      await Process.run('chmod', ['-R', 'u+w', scratch.path]);
      scratch.deleteSync(recursive: true);
    });

    final vendored = await fetcher.bazel([
      '--output_base=$vendoring',
      'vendor',
      '--vendor_dir=$vendor',
      ...common,
      ...targets,
    ]);
    expect(vendored.succeeded, isTrue, reason: 'bazel vendor: $vendored');

    // The vendoring output base is gone before anything is built, so what a
    // build finds is only what the vendored directory holds.
    await shutdown(vendoring);
    await remove(vendoring);
    expect(Directory(vendoring).existsSync(), isFalse);

    // The first command of its output base.
    built = await fetcher.bazel([
      '--output_base=$building',
      'query',
      '--vendor_dir=$vendor',
      ...common,
      targets.map((target) => 'labels(srcs, $target)').join(' + '),
    ]);
  });

  // A source repository's directory in the vendored directory.
  Directory source(String repo) {
    final matches = Directory(vendor)
        .listSync()
        .whereType<Directory>()
        .where((d) => p.basename(d.path).endsWith('+$repo'))
        .toList();
    expect(matches, hasLength(1), reason: '$repo under $vendor: $matches');
    return matches.single;
  }

  for (final (repo, package) in [
    (hostedRepo, 'sample'),
    (sdkRepo, 'integration_test'),
  ]) {
    test('$package: its BUILD file begins with the load that sets up its '
        'files repository', () {
      final build = File(p.join(source(repo).path, 'BUILD.bazel'));
      final first = build.readAsLinesSync().first;
      expect(
        first,
        allOf(startsWith('load("@@'), endsWith('//:pub_files.bzl", "FILES")')),
        reason: 'the first line of ${build.path}',
      );
    });

    test(
      '$package: no vendored link names the output base that vendored',
      () {
        final links = source(
          repo,
        ).listSync(followLinks: false).whereType<Link>().toList();
        expect(links, isNotEmpty, reason: '$repo links nothing in');
        for (final link in links) {
          expect(
            p.isAbsolute(link.targetSync()),
            isFalse,
            reason: '${link.path} names ${link.targetSync()}',
          );
        }
      },
      skip: Platform.isWindows ? 'symbolic links need privileges' : false,
    );

    test('$package: a build in a new output base sees its sources', () {
      expect(built.succeeded, isTrue, reason: '$built');
      expect(
        built.output,
        contains('//:lib/$package.dart'),
        reason: 'the package target lists no source file:\n$built',
      );
    });
  }
}
