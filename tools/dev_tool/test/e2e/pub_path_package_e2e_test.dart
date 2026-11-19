/// A lock's `path` packages that no Bazel target builds:
/// `flutter_pub.from_lock(build_from_pubspec = [...])` builds one from its
/// directory, and `flutter_pub.from_lock(ignored = {...})` keeps one out of
/// every build, saying why.
///
/// **The properties:**
///
///  1. A package built from its pubspec is its directory, wherever the lock's
///     path points, in this repository or outside it; a target that depends
///     on the hub's label builds.
///  2. Its repository follows the directory: a file added to `lib/` is built
///     by the next build, and the tool output a package directory collects
///     (`build/`, `.dart_tool/`, `android/.gradle/`, `android/build/`) neither
///     enters the repository nor fetches it again.
///  3. A directory with a Bazel build of its own, with no pubspec, or none
///     at all, is refused by the builds that use the package, saying what to
///     do; the package's repository still fetches (`bazel fetch --all`).
///  4. An ignored package leaves the hub loading, and a target that depends
///     on it fails at analysis with the reason the module gives.
@Tags(['e2e'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'pub_inputs_fixture.dart';
import 'pub_resolve_e2e_test.dart' show pathEntry;

/// The lock's Bazel package, as a monorepo has it.
const _app = 'apps/app';

/// A Dart package's files under [dir], with no Bazel build.
Map<String, String> _package(String dir) => {
  '$dir/pubspec.yaml':
      'name: greeting\nversion: 1.0.0\nenvironment:\n  sdk: ^3.0.0\n',
  '$dir/lib/greeting.dart': 'int value = 1;\n',
};

/// A library of the workspace that depends on the hub's `greeting`.
const _appBuild = {
  'BUILD.bazel':
      'load("@rules_dart//dart:defs.bzl", "dart_library", "dart_package_metadata")\n'
      'dart_package_metadata(name = "pubspec-metadata", package_name = "app")\n'
      'dart_library(\n'
      '    name = "app",\n'
      '    package = ":pubspec-metadata",\n'
      '    srcs = ["lib/app.dart"],\n'
      '    deps = ["@pubhub//:greeting"],\n'
      ')\n',
  'lib/app.dart':
      'import "package:greeting/greeting.dart";\n'
      'int app = value;\n',
};

PubInputsFixture _fixture({
  String path = '../../packages/greeting',
  Map<String, String>? package,
  Map<String, String> files = const {},
  List<String> buildFromPubspec = const ['greeting'],
  Map<String, String> ignored = const {},
}) => PubInputsFixture(
  lockPackage: _app,
  buildFromPubspec: buildFromPubspec,
  ignored: ignored,
  files: {
    ...(package ?? _package('packages/greeting')),
    ..._appBuild,
    ...files,
  },
  extraLockEntries: pathEntry('greeting', path),
);

void main() {
  group('a package built from its pubspec', () {
    test('is its directory in this repository', () async {
      final ws = await _fixture().materialize();
      final build = await ws.bazel(['build', '//:app']);
      expect(build.succeeded, isTrue, reason: '$build');
      final spoke = await ws.spokeDirectory('greeting');
      expect(
        Directory(p.join(spoke.path, 'lib')).resolveSymbolicLinksSync(),
        Directory(
          p.join(ws.root, 'packages', 'greeting', 'lib'),
        ).resolveSymbolicLinksSync(),
      );
    });

    test('is its directory outside the repository', () async {
      final outside = await Directory.systemTemp.createTemp('path_package_');
      addTearDown(() => outside.delete(recursive: true));
      for (final MapEntry(:key, :value) in _package(outside.path).entries) {
        File(key)
          ..createSync(recursive: true)
          ..writeAsStringSync(value);
      }
      final ws = await _fixture(package: {}).materialize();

      // Relative to the lock's directory, as pub writes it.
      final relative = p.relative(outside.path, from: p.join(ws.root, _app));
      ws.writeLock(ws.lockWith(pathEntry('greeting', relative)));
      final build = await ws.bazel(['build', '//:app']);
      expect(build.succeeded, isTrue, reason: '$build');
    });

    test('follows its directory, and not the tool output in it', () async {
      final ws = await _fixture(
        files: {
          'packages/greeting/android/src/main/AndroidManifest.xml':
              '<manifest/>\n',
          // Gradle's directories in `android/`, there before the first fetch:
          // a new entry of `android/` fetches the package again, once.
          'packages/greeting/android/.gradle/version.txt': '8\n',
          'packages/greeting/android/build/marker.txt': 'build\n',
        },
      ).materialize();
      final first = await ws.bazel(['build', '//:app']);
      expect(first.succeeded, isTrue, reason: '$first');
      final spoke = await ws.spokeDirectory('greeting');

      // A fetch makes the repository afresh, so this file outlives the next
      // build only if the package is not fetched again.
      final sentinel = File(p.join(spoke.path, 'not_fetched_again'))
        ..writeAsStringSync('');

      // What tools write into a package's directory.
      for (final output in [
        'packages/greeting/build/app.dill',
        'packages/greeting/.dart_tool/package_config.json',
        'packages/greeting/android/.gradle/state.bin',
        'packages/greeting/android/build/out.jar',
      ]) {
        ws.file(output)
          ..createSync(recursive: true)
          ..writeAsStringSync('tool output\n');
      }
      final again = await ws.bazel(['build', '//:app']);
      expect(again.succeeded, isTrue, reason: '$again');
      expect(
        sentinel.existsSync(),
        isTrue,
        reason: 'tool output fetched the package again',
      );
      for (final entry in [
        'build',
        '.dart_tool',
        'android/.gradle',
        'android/build',
      ]) {
        expect(
          FileSystemEntity.typeSync(p.join(spoke.path, entry)),
          FileSystemEntityType.notFound,
          reason: '$entry is in the package repository',
        );
      }

      // A new library, which only a fetch that follows the directory finds.
      ws
          .file('packages/greeting/lib/extra.dart')
          .writeAsStringSync('int extra = 2;\n');
      ws
          .file('lib/app.dart')
          .writeAsStringSync(
            'import "package:greeting/greeting.dart";\n'
            'import "package:greeting/extra.dart";\n'
            'int app = value + extra;\n',
          );
      final added = await ws.bazel(['build', '//:app']);
      expect(added.succeeded, isTrue, reason: '$added');
    });

    final refusals = <String, ({PubInputsFixture fixture, List<String> says})>{
      'a directory with a Bazel build': (
        fixture: _fixture(files: {'packages/greeting/lib/BUILD.bazel': ''}),
        says: ['has a Bazel build of its own (lib/BUILD.bazel)', '`resolve`'],
      ),
      'no directory': (
        fixture: _fixture(path: '../../packages/missing'),
        says: ['packages/missing does not exist', '`resolve`', '`ignored`'],
      ),
      'no pubspec': (
        fixture: _fixture(
          path: '../../packages/empty',
          files: {'packages/empty/lib/greeting.dart': 'int value = 1;\n'},
        ),
        says: ['packages/empty has no pubspec.yaml', '`resolve`', '`ignored`'],
      ),
    };
    for (final MapEntry(:key, :value) in refusals.entries) {
      test('is refused for $key', () async {
        final ws = await value.fixture.materialize();
        final fetch = await ws.bazel([
          'fetch',
          '--repo=@@rules_flutter++pub+flutter_pub__greeting',
        ]);
        expect(fetch.succeeded, isTrue, reason: '$fetch');
        final result = await ws.bazel(['build', '//:app']);
        expect(result.succeeded, isFalse, reason: '$result');
        for (final fragment in value.says) {
          expect(
            result.output,
            contains(fragment),
            reason: 'the refusal should say "$fragment"\n$result',
          );
        }
      });
    }
  });

  test(
    'an ignored package fails what depends on it, with the reason',
    () async {
      final ws = await _fixture(
        buildFromPubspec: const [],
        ignored: const {'greeting': 'only a release script uses it'},
      ).materialize();
      final hub = await ws.query('@pubhub//:all');
      expect(hub.succeeded, isTrue, reason: '$hub');
      final build = await ws.bazel(['build', '//:app']);
      expect(build.succeeded, isFalse, reason: '$build');
      expect(
        build.output,
        contains(
          'package `greeting` (in @@//$_app:pubspec.lock) is ignored: '
          'only a release script uses it. Something depends on it',
        ),
        reason: '$build',
      );
    },
  );
}
