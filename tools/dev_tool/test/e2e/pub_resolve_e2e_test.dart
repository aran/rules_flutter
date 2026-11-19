/// A lock's packages are built from workspace targets the user maps with
/// `flutter_pub.from_lock(resolve = {...})`.
///
/// **The properties:**
///
///  1. A map that does not fit the lock is refused when the lock is read,
///     naming the lock and the package, so every Bazel command fails the same
///     way: a `path` package mapped to no target, and a mapped name the lock
///     lacks. A hosted package may be mapped.
///  2. Where a mapped `path` entry points is pub's concern: an absolute path,
///     one out of the repository, and a target in another module or another
///     Bazel package than the path names are all accepted.
///  3. The hub reaches the workspace target, and so does a hosted package that
///     depends on the mapped one; a target built once however it is reached.
///     The mapped package's pubspec is read where the lock says it is, inside
///     the repository or out, so a dependency cycle through it and a hosted
///     package is refused when the packages are planned, naming the target;
///     a pubspec outside the repository that is not there fails nothing, and
///     one inside it that is not there fails the builds reaching it.
///  4. A hosted package mapped to a workspace target replaces it for the whole
///     graph and is never fetched; a target that declares another package name
///     than its key fails analysis, naming both.
@Tags(['e2e'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'pub_inputs_fixture.dart';

/// The lock's Bazel package, as a monorepo has it.
const _app = 'apps/app';

/// A lock entry of a `path` package.
String pathEntry(
  String name,
  String path, {
  String version = '1.0.0',
  bool relative = true,
  String dependency = 'direct main',
}) =>
    '  $name:\n'
    '    dependency: "$dependency"\n'
    '    description:\n'
    '      path: "$path"\n'
    '      relative: $relative\n'
    '    source: path\n'
    '    version: "$version"\n';

/// The files of a package at `packages/<name>`: a pubspec, a library, and a
/// `dart_library` named [target] (public, as the hub's repository needs).
Map<String, String> pathPackage(
  String name, {
  String version = '1.0.0',
  String? pubspec,
  String target = '',
  String dependencies = '',
  List<String> deps = const [],
  bool withPubspec = true,
}) {
  final dir = 'packages/$name';
  return {
    if (withPubspec)
      '$dir/pubspec.yaml':
          pubspec ??
          'name: $name\n'
              'version: $version\n'
              'environment:\n'
              '  sdk: ^3.0.0\n'
              '$dependencies',
    '$dir/lib/$name.dart': 'int value = 1;\n',
    '$dir/BUILD.bazel':
        'load("@rules_dart//dart:defs.bzl", "dart_library", "dart_package_metadata")\n'
        'dart_package_metadata(name = "pubspec-metadata", package_name = "$name")\n'
        'dart_library(\n'
        '    name = "${target.isEmpty ? name : target}",\n'
        '    package = ":pubspec-metadata",\n'
        '    srcs = glob(["lib/**/*.dart"]),\n'
        '    deps = [${deps.map((d) => '"$d"').join(', ')}],\n'
        '    visibility = ["//visibility:public"],\n'
        ')\n',
  };
}

/// What a fixture with one path package `greeting` looks like; the keyword
/// arguments change one thing about it.
PubInputsFixture greetingFixture({
  Map<String, String>? package,
  Map<String, String> files = const {},
  String? lockEntry,
  Map<String, String>? resolve,
  List<HostedPackage> hosted = const [],
  String extraLockEntries = '',
}) => PubInputsFixture(
  hosted: hosted,
  lockPackage: _app,
  spokes: ['greeting'],
  resolve: resolve ?? {'greeting': '//packages/greeting'},
  files: {...(package ?? pathPackage('greeting')), ...files},
  extraLockEntries:
      (lockEntry ?? pathEntry('greeting', '../../packages/greeting')) +
      extraLockEntries,
);

/// That [result] refused the cycle between `greeting`, which a target of the
/// workspace builds, and the hosted `uses_greeting`, when the packages were
/// planned, rather than leaving it to Bazel's own cycle error.
void _expectRefusedCycle(BazelResult result) {
  expect(result.succeeded, isFalse, reason: '$result');
  for (final words in [
    'depend on each other',
    'greeting',
    'uses_greeting',
    'a target of yours',
    'flutter_pub.from_lock()',
    'flutter_pub.cycle(',
  ]) {
    expect(result.output, contains(words), reason: '$result');
  }
}

void main() {
  group(
    'a map that does not match the lock is refused when the lock is read',
    () {
      final cases = <String, ({PubInputsFixture fixture, List<String> says})>{
        'a path package mapped to no target': (
          fixture: greetingFixture(resolve: {}),
          says: [
            'it lists `greeting` as a `path` package',
            '"greeting": "//packages/greeting:<target>"',
            'build_from_pubspec',
            'ignored',
          ],
        ),
        'a mapped name the lock does not list': (
          fixture: greetingFixture(
            resolve: {
              'greeting': '//packages/greeting',
              'ghost': '//packages/ghost',
            },
          ),
          says: ['`resolve` maps `ghost`, which the lock does not list'],
        ),
      };

      for (final entry in cases.entries) {
        test(entry.key, () async {
          final ws = await entry.value.fixture.materialize();
          final result = await ws.query('@pubhub//:all');
          expect(
            result.succeeded,
            isFalse,
            reason: 'the hub loaded with a wrong map\n$result',
          );
          expect(
            result.output,
            isNot(contains('during the fetch of repository')),
            reason:
                'the refusal should come from reading the lock, not from a '
                'later fetch\n$result',
          );
          expect(
            result.output,
            contains('pubspec.lock'),
            reason: 'the refusal should name the lock\n$result',
          );
          for (final fragment in entry.value.says) {
            expect(
              result.output,
              contains(fragment),
              reason: 'the refusal should say "$fragment"\n$result',
            );
          }
        });
      }
    },
  );

  group('where a mapped path entry points is not checked', () {
    final cases = <String, PubInputsFixture>{
      'an absolute path': greetingFixture(
        lockEntry: pathEntry('greeting', '/abs/greeting', relative: false),
      ),
      'a path out of the repository': greetingFixture(
        lockEntry: pathEntry('greeting', '../../../../outside/greeting'),
      ),
      'a target in another module': greetingFixture(
        resolve: {'greeting': '@bazel_skylib//packages/greeting'},
      ),
      'a target in another Bazel package than the path names': greetingFixture(
        resolve: {'greeting': '//packages/other:greeting'},
      ),
    };
    for (final entry in cases.entries) {
      test(entry.key, () async {
        final ws = await entry.value.materialize();
        final result = await ws.query('@pubhub//:all');
        expect(result.succeeded, isTrue, reason: '$result');
      });
    }
  });

  group('the workspace target', () {
    /// A hosted `uses_greeting` that depends on `greeting`, as a package does
    /// that a `dependency_overrides` entry points at a workspace one.
    final usesGreeting = HostedPackage(
      'uses_greeting',
      pubspec:
          'name: uses_greeting\nversion: 1.0.0\nenvironment:\n  sdk: ^3.0.0\n'
          'dependencies:\n  greeting: ^1.0.0\n',
    );

    PubInputsFixture fixture({
      List<String> greetingDeps = const [],
      String path = '../../packages/greeting',
      bool withPubspec = true,
    }) => greetingFixture(
      hosted: [usesGreeting],
      lockEntry: pathEntry('greeting', path, dependency: 'direct overridden'),
      package: pathPackage(
        'greeting',
        deps: greetingDeps,
        withPubspec: withPubspec,
        // What pub sees it depend on, as its BUILD file says.
        dependencies: greetingDeps.isEmpty
            ? ''
            : 'dependencies:\n  uses_greeting: ^1.0.0\n',
      ),
      files: {
        'BUILD.bazel':
            'load("@rules_dart//dart:defs.bzl", "dart_library", "dart_package_metadata")\n'
            'dart_package_metadata(name = "pubspec-metadata", package_name = "app")\n'
            'dart_library(\n'
            '    name = "app",\n'
            '    package = ":pubspec-metadata",\n'
            '    srcs = ["lib/app.dart"],\n'
            '    deps = ["//packages/greeting", "@pubhub//:uses_greeting"],\n'
            ')\n',
        'lib/app.dart': 'int value = 1;\n',
      },
    );

    test('is what the hub aliases', () async {
      final ws = await fixture().materialize();
      final deps = await ws.bazel([
        'cquery',
        '--output=label',
        'deps(@pubhub//:greeting, 2)',
      ]);
      expect(deps.succeeded, isTrue, reason: '$deps');
      expect(
        deps.stdout,
        contains('//packages/greeting:greeting'),
        reason: '$deps',
      );
      final build = await ws.bazel([
        'build',
        '--nobuild',
        '@pubhub//:greeting',
      ]);
      expect(build.succeeded, isTrue, reason: '$build');
    });

    test('is what a hosted package that depends on it gets', () async {
      final ws = await fixture().materialize();
      final deps = await ws.bazel([
        'cquery',
        '--output=label',
        'deps(@pubhub//:uses_greeting)',
      ]);
      expect(deps.succeeded, isTrue, reason: '$deps');
      expect(
        deps.stdout,
        contains('//packages/greeting:greeting'),
        reason: '$deps',
      );
      final build = await ws.bazel([
        'build',
        '--nobuild',
        '@pubhub//:uses_greeting',
      ]);
      expect(build.succeeded, isTrue, reason: '$build');
    });

    test('is built once, however it is reached', () async {
      final ws = await fixture().materialize();
      final deps = await ws.bazel(['cquery', '--output=label', 'deps(//:app)']);
      expect(deps.succeeded, isTrue, reason: '$deps');
      final configured = deps.stdout
          .split('\n')
          .where((l) => l.contains('//packages/greeting:greeting'))
          .toList();
      expect(configured, hasLength(1), reason: '$configured\n$deps');
    });

    test(
      'depending back on the package that depends on it is a cycle',
      () async {
        final ws = await fixture(
          greetingDeps: ['@pubhub//:uses_greeting'],
        ).materialize();
        _expectRefusedCycle(await ws.bazel(['build', '--nobuild', '//:app']));
      },
    );

    test('whose pubspec is not there fails the builds reaching it', () async {
      final ws = await fixture(withPubspec: false).materialize();
      final result = await ws.bazel(['build', '--nobuild', '//:app']);
      expect(result.succeeded, isFalse, reason: '$result');
      expect(result.output, contains('pubspec.yaml'), reason: '$result');
      expect(result.output, contains('does not exist'), reason: '$result');
      expect(
        result.output,
        contains('flutter_pub.from_lock()'),
        reason: '$result',
      );
    });

    group('whose pubspec is outside the repository', () {
      /// Beside the generated workspace, as a sibling checkout is: the lock
      /// reaches it through `..`s past the repository's root.
      Future<(PubInputsWorkspace, Directory)> outside({
        bool cycle = false,
        bool pubspec = true,
      }) async {
        final ws = await fixture(
          greetingDeps: cycle ? ['@pubhub//:uses_greeting'] : const [],
        ).materialize();
        final sibling = Directory('${ws.root}_sibling');
        addTearDown(() => sibling.delete(recursive: true));
        sibling.createSync();
        if (pubspec) {
          File(p.join(sibling.path, 'greeting', 'pubspec.yaml'))
            ..createSync(recursive: true)
            ..writeAsStringSync(
              'name: greeting\nversion: 1.0.0\nenvironment:\n  sdk: ^3.0.0\n'
              '${cycle ? 'dependencies:\n  uses_greeting: ^1.0.0\n' : ''}',
            );
        }
        ws.writeLock(
          ws.lockWith(
            pathEntry(
              'greeting',
              '../../../${p.basename(sibling.path)}/greeting',
              dependency: 'direct overridden',
            ),
          ),
        );
        return (ws, sibling);
      }

      test('builds', () async {
        final (ws, _) = await outside();
        final build = await ws.bazel(['build', '--nobuild', '//:app']);
        expect(build.succeeded, isTrue, reason: '$build');
      });

      test('finds a cycle through it', () async {
        final (ws, _) = await outside(cycle: true);
        _expectRefusedCycle(await ws.bazel(['build', '--nobuild', '//:app']));
      });

      test('that is not there fails nothing', () async {
        final (ws, _) = await outside(pubspec: false);
        final build = await ws.bazel(['build', '--nobuild', '//:app']);
        expect(build.succeeded, isTrue, reason: '$build');
      });
    });
  });

  group('a hosted package mapped to a workspace target', () {
    /// A hosted package that depends on `forkme`, which the workspace replaces.
    final usesFork = HostedPackage(
      'uses_fork',
      pubspec:
          'name: uses_fork\nversion: 1.0.0\nenvironment:\n  sdk: ^3.0.0\n'
          'dependencies:\n  forkme: ^1.0.0\n',
    );

    /// A lock entry for `forkme` whose archive does not exist: fetching it
    /// would fail, so a build that passes never fetched it.
    final forkmeEntry =
        '  forkme:\n'
        '    dependency: "transitive"\n'
        '    description:\n'
        '      name: forkme\n'
        '      sha256: "${'0' * 64}"\n'
        '      url: "file:///nonexistent"\n'
        '    source: hosted\n'
        '    version: "9.9.9"\n';

    PubInputsFixture fixture({
      String packageName = 'forkme',
    }) => PubInputsFixture(
      hosted: [usesFork],
      extraLockEntries: forkmeEntry,
      spokes: ['forkme'],
      resolve: {'forkme': '//third_party/forkme:forkme_fork'},
      files: {
        'third_party/forkme/BUILD.bazel':
            'load("@rules_dart//dart:defs.bzl", "dart_library", "dart_package_metadata")\n'
            'dart_package_metadata(name = "pubspec-metadata", package_name = "$packageName")\n'
            'dart_library(\n'
            '    name = "forkme_fork",\n'
            '    package = ":pubspec-metadata",\n'
            '    srcs = ["lib/forkme.dart"],\n'
            '    visibility = ["//visibility:public"],\n'
            ')\n',
        'third_party/forkme/lib/forkme.dart': 'int value = 2;\n',
        'BUILD.bazel':
            'load("@rules_dart//dart:defs.bzl", "dart_library", "dart_package_metadata")\n'
            'dart_package_metadata(name = "pubspec-metadata", package_name = "app")\n'
            'dart_library(\n'
            '    name = "app",\n'
            '    package = ":pubspec-metadata",\n'
            '    srcs = ["lib/app.dart"],\n'
            '    deps = ["@pubhub//:forkme", "@pubhub//:uses_fork"],\n'
            ')\n',
        'lib/app.dart': 'int value = 1;\n',
      },
    );

    test('is what the hub label and its dependents get, and is never '
        'fetched', () async {
      final ws = await fixture().materialize();
      final deps = await ws.bazel(['cquery', '--output=label', 'deps(//:app)']);
      expect(deps.succeeded, isTrue, reason: '$deps');
      final replacements = deps.stdout
          .split('\n')
          .where((l) => l.contains('//third_party/forkme:forkme_fork'))
          .toList();
      expect(replacements, hasLength(1), reason: '$replacements\n$deps');
      expect(
        deps.stdout,
        isNot(contains('flutter_pub_lib__forkme')),
        reason: 'the locked package was built\n$deps',
      );
    });

    test(
      'declaring another package name fails analysis, naming both',
      () async {
        final ws = await fixture(packageName: 'other').materialize();
        final result = await ws.bazel([
          'build',
          '--nobuild',
          '@pubhub//:forkme',
        ]);
        expect(result.succeeded, isFalse, reason: '$result');
        expect(
          result.output,
          isNot(contains('during the fetch of repository')),
          reason: '$result',
        );
        expect(result.output, contains('//third_party/forkme:forkme_fork'));
        expect(result.output, contains('"forkme"'), reason: '$result');
        expect(result.output, contains('"other"'), reason: '$result');
      },
    );
  });
}
