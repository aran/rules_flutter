/// Pub inputs that rules_flutter honours today, and keeps honouring.
///
/// The counterpart of `pub_inputs_red_e2e_test.dart`: the same generated
/// `flutter_pub.from_lock()` hub over `file://` packages, asked the questions
/// whose answer is already right. They pin what a fix of the red tests must not
/// disturb, and they are the controls that show the red tests fail for the
/// reason they name: an overlay present at the first fetch is used, so the ones
/// added later failing is about being added later; a file name with a space
/// builds, so the ones with a quote failing is about the quote.
@Tags(['e2e'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'pub_inputs_fixture.dart';

String _pubspec(String name, String body) =>
    'name: $name\nversion: 1.0.0\nenvironment:\n  sdk: ^3.0.0\n$body';

void main() {
  group('a package that rules_flutter can build', () {
    // Legal file names with characters that are special somewhere else
    // (shell, Starlark format strings, labels' relatives), none to Bazel.
    final legal = {
      'space': 'sp ace.txt',
      'dollar': r'dollar$name.txt',
      'braces': 'brace{name}.txt',
      'unicode': 'üñí.txt',
    };
    late PubInputsWorkspace ws;

    setUpAll(() async {
      ws = await PubInputsFixture(
        hosted: [
          HostedPackage('plain'),
          for (final entry in legal.entries) ...[
            HostedPackage(
              'asset_${entry.key}',
              pubspec: _pubspec(
                'asset_${entry.key}',
                'flutter:\n  assets:\n    - assets/${entry.value}\n',
              ),
              files: {'assets/${entry.value}': 'x'},
            ),
            HostedPackage(
              'font_${entry.key}',
              pubspec: _pubspec(
                'font_${entry.key}',
                'flutter:\n  fonts:\n    - family: F\n'
                    '      fonts:\n        - asset: fonts/${entry.value}\n',
              ),
              files: {'fonts/${entry.value}': 'x'},
            ),
          ],
        ],
      ).materialize();
    });

    test('a plain package loads', () async {
      final result = await ws.loadSpoke('plain');
      expect(result.succeeded, isTrue, reason: '$result');
      expect(result.stdout, contains('@flutter_pub__plain//:plain'));
    });

    for (final kind in ['asset', 'font']) {
      for (final entry in legal.entries) {
        test(
          'a $kind file named ${entry.key} is declared under its name',
          () async {
            final package = '${kind}_${entry.key}';
            final declared = await ws.declaredFiles(kind, package);
            expect(declared.succeeded, isTrue, reason: '$declared');
            expect(
              declared.stdout,
              contains('@flutter_pub__$package//:${kind}s/${entry.value}\n'),
              reason:
                  'the package target does not declare the file:\n$declared',
            );
          },
        );
      }
    }
  });

  group('a lock entry for a Flutter SDK package', () {
    /// Every `sdk: flutter` entry is in the hub, whatever its name: the hub
    /// takes them from the lock, not from a list of the packages it knows.
    test('an `sdk: flutter` entry is in the hub', () async {
      final names = [
        'flutter_driver',
        'integration_test',
        'fuchsia_remote_debug_protocol',
      ];
      final ws = await PubInputsFixture(
        hosted: [HostedPackage('good')],
        extraLockEntries: [
          for (final name in names)
            '''
  $name:
    dependency: "direct dev"
    description: flutter
    source: sdk
    version: "0.0.0"
''',
        ].join(),
      ).materialize();
      final result = await ws.query('@pubhub//:all');
      expect(result.succeeded, isTrue, reason: '$result');
      for (final name in names) {
        expect(result.stdout, contains('@pubhub//:$name'));
      }
    });
  });

  group('a plugin overlay', () {
    String template(String marker) =>
        'filegroup(\n    name = "{PKG}",\n    srcs = [],\n{LICENSE}\n)\n'
        'filegroup(name = "$marker")\n';

    final rungs = {
      'the bare package directory': '',
      'the major version': '1',
      'the major and minor version': '1.0',
      'the exact version': '1.0.0',
    };
    String ladder(String rung) => 'ladder_${rung.replaceAll('.', '_')}';

    /// The overlays a user registers before the first build are used, at
    /// every rung of the version ladder, and an `android/` template beside
    /// the top-level one replaces the empty Android stub.
    test(
      'present at the first build is used, at every rung of the ladder',
      () async {
        final ws = await PubInputsFixture(
          hosted: [
            for (final rung in rungs.values) HostedPackage(ladder(rung)),
            HostedPackage(
              'android_ladder',
              pubspec: _pubspec(
                'android_ladder',
                'flutter:\n  plugin:\n    platforms:\n      android:\n'
                    '        package: dev.example\n        pluginClass: P\n',
              ),
            ),
          ],
          overlayRoots: ['//overlays:BUILD.bazel'],
          files: {
            'overlays/BUILD.bazel': '',
            for (final rung in rungs.values)
              p.join(
                'overlays',
                ladder(rung),
                rung,
                'BUILD.bazel.tpl',
              ): template(
                'rung_${ladder(rung)}',
              ),
            'overlays/android_ladder/BUILD.bazel.tpl': template('top'),
            'overlays/android_ladder/android/BUILD.bazel.tpl':
                'filegroup(name = "android_overlay")\n',
          },
        ).materialize();

        for (final rung in rungs.entries) {
          final result = await ws.loadSpoke(ladder(rung.value));
          expect(
            result.stdout,
            contains('//:rung_${ladder(rung.value)}'),
            reason: 'the overlay at ${rung.key} was not used:\n$result',
          );
        }
        final android = await ws.query(
          '@flutter_pub__android_ladder//android:all',
        );
        expect(
          android.stdout,
          contains('//android:android_overlay'),
          reason: '$android',
        );
      },
    );

    /// An overlay the build already read is a file the repository rule
    /// watches, so editing or deleting it takes effect on the next build.
    test('that was used is picked up again when it is edited, and dropped when it is deleted', () async {
      final ws = await PubInputsFixture(
        hosted: [HostedPackage('edited')],
        overlayRoots: ['//overlays:BUILD.bazel'],
        files: {
          'overlays/BUILD.bazel': '',
          'overlays/edited/BUILD.bazel.tpl': template('v1'),
        },
      ).materialize();
      final overlay = ws.file('overlays/edited/BUILD.bazel.tpl');

      expect((await ws.loadSpoke('edited')).stdout, contains('//:v1'));

      overlay.writeAsStringSync(template('v2'));
      final edited = await ws.loadSpoke('edited');
      expect(
        edited.stdout,
        contains('//:v2'),
        reason: 'edit not seen:\n$edited',
      );

      overlay.deleteSync();
      final deleted = await ws.loadSpoke('edited');
      expect(deleted.succeeded, isTrue, reason: '$deleted');
      expect(
        deleted.stdout,
        isNot(contains('//:v2')),
        reason: 'the deleted overlay is still in use:\n$deleted',
      );
    });
  });

  group('flutter_pub.annotation(android_deps)', () {
    late PubInputsWorkspace ws;
    setUpAll(() async {
      ws = await PubInputsFixture(
        hosted: [
          // Its only dependency is in a form the Gradle reader does not read.
          androidPlugin('catalog_plugin', {
            'android/build.gradle':
                'android {\n    namespace = "dev.example.catalog_plugin"\n}\n'
                'dependencies {\n'
                '    implementation(libs.androidx.browser)\n'
                '}\n',
          }),
          HostedPackage('dart_only'),
        ],
        annotations: {
          'catalog_plugin': ['androidx_browser_browser'],
          'dart_only': ['androidx_browser_browser'],
        },
      ).materialize();
    });

    test(
      'adds the artifact to the plugin Android library and its record',
      () async {
        expect((await ws.loadSpoke('catalog_plugin')).succeeded, isTrue);
        final dir = await ws.spokeDirectory('catalog_plugin');
        final build = File(p.join(dir.path, 'android', 'BUILD.bazel'))
            .readAsStringSync();
        expect(
          build,
          contains('rules_flutter_maven//:androidx_browser_browser'),
        );
        final record = jsonDecode(
          File(p.join(dir.path, 'flutter_android_maven_deps.json'))
              .readAsStringSync(),
        ) as Map<String, Object?>;
        expect(
          [for (final a in record['annotated']! as List) (a as Map)['name']],
          ['androidx_browser_browser'],
        );
        expect(
          (await recordedMavenDeps(ws, 'catalog_plugin')).unread,
          hasLength(1),
        );
      },
    );

    test(
      'a package with no Android library refuses it, naming the package',
      () async {
        final result = await ws.loadSpoke('dart_only');
        expect(result.succeeded, isFalse, reason: '$result');
        expect(result.output, contains('package = "dart_only"'));
        expect(result.output, contains('is not one'));
      },
    );

    test('a package no lock lists fails the build, naming it', () async {
      final other = await PubInputsFixture(
        hosted: [HostedPackage('real')],
        annotations: {
          'imaginary': ['androidx_browser_browser'],
        },
      ).materialize();
      final result = await other.loadSpoke('real');
      expect(result.succeeded, isFalse, reason: '$result');
      expect(result.output, contains('package = "imaginary"'));
      expect(result.output, contains('no `flutter_pub.from_lock` lock lists'));
    });
  });

  group('Gradle files of a plugin', () {
    late PubInputsWorkspace ws;
    setUpAll(() async {
      ws = await PubInputsFixture(
        hosted: [
          androidPlugin('kts_only', {
            'android/build.gradle.kts':
                'android {\n    namespace = "dev.example.kts_only"\n}\n'
                'dependencies {\n    implementation("kts.group:kts:1.0")\n}\n',
          }),
          androidPlugin('groovy_only', {
            'android/build.gradle':
                'android {\n    namespace = "dev.example.groovy_only"\n}\n'
                'dependencies {\n    implementation "groovy.group:groovy:1.0"\n}\n',
          }),
          androidPlugin('both_files', {
            'android/build.gradle':
                'android {\n    namespace = "dev.example.groovy"\n}\n',
            'android/build.gradle.kts':
                'android {\n    namespace = "dev.example.kts"\n}\n',
          }),
        ],
      ).materialize();
    });

    test('dependencies are read from either dialect', () async {
      for (final (package, coordinate) in [
        ('kts_only', 'kts.group:kts'),
        ('groovy_only', 'groovy.group:groovy'),
      ]) {
        expect((await ws.loadSpoke(package)).succeeded, isTrue);
        expect((await recordedMavenDeps(ws, package)).coordinates, [
          coordinate,
        ]);
      }
    });

    /// Gradle uses `build.gradle` when both exist, and the namespace reader
    /// agrees with it.
    test('the namespace comes from build.gradle when both exist', () async {
      expect((await ws.loadSpoke('both_files')).succeeded, isTrue);
      final dir = await ws.spokeDirectory('both_files');
      final build = File(p.join(dir.path, 'android', 'BUILD.bazel'))
          .readAsStringSync();
      expect(build, contains('custom_package = "dev.example.groovy"'));
    });
  });
}
