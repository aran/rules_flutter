/// Pub inputs rules_flutter cannot honour must not become a quiet, degraded
/// build. Each test here states one property.
///
/// Three properties, each quantified over several inputs so that a different
/// bug breaking the same promise fails too:
///
///  1. **Refuse what cannot be honoured, loudly.** A pub input rules_flutter
///     cannot build exactly as `flutter` would (an asset transformer it does
///     not run, a file name it cannot put in a BUILD file, a lock entry it has
///     no repository for) fails with a message that names the package and the
///     input, while the repository is fetched or, for a lock entry nothing
///     has to use, when something depends on it. It never yields a green
///     build of something else. Where rules_flutter can honour the input
///     instead, that is as good: every test accepts "builds, and the input is
///     there" as well.
///  2. **A repository rule re-runs when anything it read, or looked for,
///     changes.** Adding an overlay file the rule looked for and did not find
///     is a change.
///  3. **Running pub through Bazel leaves the user's HOME alone.**
///
/// The workspaces are generated (`pub_inputs_fixture.dart`): a real
/// `flutter_pub.from_lock()` hub over packages served from `file://`.
@Tags(['e2e'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'pub_inputs_fixture.dart';

/// Fail unless [result], the analysis of [package]'s target, is rules_flutter
/// refusing the package's input there, with [mentions] in the message. The
/// repository fetches, so a package no target uses breaks nothing.
///
/// [what] is the input, for the failure message.
void expectRefused(
  BazelResult result, {
  required String package,
  required String what,
  required List<String> mentions,
}) {
  expect(
    result.succeeded,
    isFalse,
    reason:
        'rules_flutter built @flutter_pub__$package from $what without a word',
  );
  expect(
    refusedAtAnalysis(result),
    isTrue,
    reason:
        'the failure should be the target of $package refusing $what at '
        'analysis, not its fetch or something Bazel hit afterwards:\n$result',
  );
  expect(
    namesPackage(result.output, package),
    isTrue,
    reason: 'the refusal of $what does not name the package $package:\n$result',
  );
  final lower = result.output.toLowerCase();
  for (final mention in mentions) {
    expect(
      lower,
      contains(mention.toLowerCase()),
      reason: 'the refusal of $what does not say "$mention":\n$result',
    );
  }
}

String _pubspec(String name, String body) =>
    'name: $name\nversion: 1.0.0\nenvironment:\n  sdk: ^3.0.0\n$body';

void main() {
  group('a file name in a package', () {
    // Names a pubspec may list and a filesystem may hold. Space, `$`, braces
    // and non-ASCII are fine for Bazel and are in the control test.
    final odd = {
      'quote': ('quote"name.txt', 'name.txt'),
      'backslash': (r'back\slash.txt', 'slash.txt'),
      'colon': ('colon:name.txt', 'name.txt'),
      // Starlark in the name. Evaluating it makes `fail` print INJE+CTED.
      'injection': ('inj"+fail("INJE"+"CTED")+".txt', '.txt'),
    };
    late PubInputsWorkspace ws;

    String assetPubspec(String name, String path) =>
        _pubspec(name, 'flutter:\n  assets:\n    - assets/$path\n');
    String fontPubspec(String name, String path) => _pubspec(
      name,
      'flutter:\n  fonts:\n    - family: F\n      fonts:\n        - asset: fonts/$path\n',
    );

    setUpAll(() async {
      ws = await PubInputsFixture(
        hosted: [
          for (final entry in odd.entries) ...[
            HostedPackage(
              'asset_${entry.key}',
              pubspec: assetPubspec('asset_${entry.key}', entry.value.$1),
              files: {'assets/${entry.value.$1}': 'x'},
            ),
            HostedPackage(
              'font_${entry.key}',
              pubspec: fontPubspec('font_${entry.key}', entry.value.$1),
              files: {'fonts/${entry.value.$1}': 'x'},
            ),
          ],
        ],
      ).materialize();
    });

    /// The name is data. It is written into a generated BUILD file, so a
    /// name that is not a valid string there breaks the file, and one that is
    /// Starlark runs as the spoke's own code. The spoke always loads. Either
    /// the package builds with the file under the name it has, or its target
    /// refuses it at analysis, naming the package and the file. A syntax
    /// error from a BUILD file nobody wrote, or a label error from the
    /// generated one, is neither.
    for (final kind in ['asset', 'font']) {
      for (final entry in odd.entries) {
        test(
          '$kind named ${entry.key} builds or is refused naming package and file',
          () async {
            final package = '${kind}_${entry.key}';
            final fragment = entry.value.$2;
            final loaded = await ws.loadSpoke(package);
            expect(loaded.succeeded, isTrue, reason: '$loaded');
            final result = await ws.analyzeSpoke(package);
            for (final run in [loaded, result]) {
              expect(
                run.output,
                isNot(contains('INJECTED')),
                reason: 'a file name ran as code in the spoke:\n$run',
              );
            }
            if (result.succeeded) {
              final declared = await ws.declaredFiles(kind, package);
              expect(
                declared.stdout,
                contains(
                  '@flutter_pub__$package//:${kind}s/${entry.value.$1}\n',
                ),
                reason:
                    'the package loads but its target has lost the file:\n'
                    '$declared',
              );
              return;
            }
            expectRefused(
              result,
              package: package,
              what: 'a $kind file named ${entry.value.$1}',
              mentions: [fragment],
            );
          },
        );
      }
    }
  });

  group('an Android namespace in a package', () {
    // The namespace is written into the plugin's generated Android BUILD file
    // (the library's `custom_package` and a genrule that emits BuildConfig),
    // so it must be a dotted Java name, not text that ends a string. Only the
    // plugin's Android library needs it: the package fetches and loads, and
    // that library fails at analysis.
    final hostile = {
      'gradle': (
        'android/build.gradle',
        "android {\n    namespace = 'dev.x\"+fail(\"INJE\"+\"CTED\")+\"'\n}\n",
      ),
      'manifest': (
        'android/src/main/AndroidManifest.xml',
        '<manifest package=\'dev.x"+fail("INJE"+"CTED")+"\'>\n</manifest>\n',
      ),
    };
    late PubInputsWorkspace ws;
    setUpAll(() async {
      ws = await PubInputsFixture(
        hosted: [
          for (final entry in hostile.entries)
            androidPlugin('ns_${entry.key}', {entry.value.$1: entry.value.$2}),
        ],
      ).materialize();
    });

    for (final key in hostile.keys) {
      test('from the $key fails the Android library naming the package, '
          'never run', () async {
        final loaded = await ws.loadSpoke('ns_$key');
        expect(loaded.succeeded, isTrue, reason: '$loaded');
        final spoke = PubInputsWorkspace.spoke('ns_$key');
        final result = await ws.bazel([
          'build',
          '--nobuild',
          '$spoke//android:lib',
        ]);
        for (final run in [loaded, result]) {
          expect(
            run.output,
            isNot(contains('INJECTED')),
            reason: 'a namespace ran as code in the spoke:\n$run',
          );
        }
        expect(result.succeeded, isFalse, reason: 'built from $key: $result');
        expect(
          namesPackage(result.output, 'ns_$key'),
          isTrue,
          reason: 'the failure does not name the package:\n$result',
        );
        expect(
          result.output,
          contains('is not a Java package name'),
          reason: '$result',
        );
        expect(
          result.output,
          isNot(contains('package contains errors')),
          reason: 'the Android package should load:\n$result',
        );
      });
    }
  });

  group('an asset or shader with transformers', () {
    late PubInputsWorkspace ws;
    setUpAll(() async {
      ws = await PubInputsFixture(
        hosted: [
          HostedPackage(
            'transformed',
            pubspec: _pubspec(
              'transformed',
              'flutter:\n'
                  '  assets:\n'
                  '    - path: assets/data.txt\n'
                  '      transformers:\n'
                  '        - package: some_transformer\n',
            ),
            files: {'assets/data.txt': 'x'},
          ),
          HostedPackage(
            'transformed_shader',
            pubspec: _pubspec(
              'transformed_shader',
              'flutter:\n'
                  '  shaders:\n'
                  '    - path: shaders/a.frag\n'
                  '      transformers:\n'
                  '        - package: some_transformer\n',
            ),
            files: {'shaders/a.frag': 'void main() {}\n'},
          ),
        ],
      ).materialize();
    });

    /// `transformers:` on an asset runs a program over the file before it is
    /// bundled. rules_flutter does not run it, so building without it ships
    /// the untransformed file under the transformed file's name.
    test('is refused naming the package and the key', () async {
      final result = await ws.analyzeSpoke('transformed');
      expectRefused(
        result,
        package: 'transformed',
        what: 'an asset with transformers',
        mentions: ['transformers'],
      );
    });

    /// flutter_tools runs a shader's transformers on its source before it
    /// compiles it, so a shader built without them is not the one
    /// `flutter build` ships.
    test('on a shader is refused naming the package and the key', () async {
      final result = await ws.analyzeSpoke('transformed_shader');
      expectRefused(
        result,
        package: 'transformed_shader',
        what: 'a shader with transformers',
        mentions: ['transformers', 'shader'],
      );
    });
  });

  group('a lock entry rules_flutter has no repository for (an unknown source)', () {
    late PubInputsWorkspace ws;
    setUpAll(() async {
      ws = await PubInputsFixture(hosted: [HostedPackage('good')])
          .materialize();
    });

    // Entries a lock can hold that rules_flutter cannot provide, with what
    // the lock calls their source. (A `path` entry is the user's own target:
    // see `pub_resolve_e2e_test.dart`.) (An `sdk: flutter` entry, whatever its
    // name, is built from the Flutter source; see `sdk_source_e2e_test.dart`.)
    final entries = {
      'from_elsewhere': (
        'elsewhere',
        '  from_elsewhere:\n'
            '    dependency: "direct main"\n'
            '    description:\n'
            '      url: "https://example.invalid/from_elsewhere"\n'
            '    source: elsewhere\n'
            '    version: "1.0.0"\n',
      ),
    };

    setUp(() {
      ws.writeLock(ws.lockWith(entries.values.map((e) => e.$2).join()));
    });

    /// Most apps that list one of these never depend on it from Bazel, and must
    /// not pay for it: the hub loads, lists the package, and everything else
    /// builds.
    test(
      'the hub still loads, and what does not depend on it builds',
      () async {
        final hub = await ws.query('@pubhub//:all');
        expect(hub.succeeded, isTrue, reason: '$hub');
        for (final name in entries.keys) {
          expect(hub.stdout, contains('@pubhub//:$name'), reason: '$hub');
        }
        final good = await ws.bazel(['build', '--nobuild', '@pubhub//:good']);
        expect(good.succeeded, isTrue, reason: '$good');
      },
    );

    /// What something that does depend on one gets instead of a package: a
    /// failure that names the package, where the lock got it from and what to
    /// do, not an unknown package in an import.
    for (final entry in entries.entries) {
      test(
        'depending on ${entry.key} fails naming it, its source and the fix',
        () async {
          final result = await ws.bazel([
            'build',
            '--nobuild',
            '@pubhub//:${entry.key}',
          ]);
          expect(result.succeeded, isFalse, reason: '$result');
          expect(
            result.output,
            contains('package "${entry.key}" (source: ${entry.value.$1})'),
            reason: 'the failure does not say what the entry is:\n$result',
          );
          expect(result.output, contains('pubspec.lock'), reason: '$result');
          expect(
            result.output,
            contains('re-resolve the lock'),
            reason: '$result',
          );
          expect(
            result.output,
            isNot(contains('no such target')),
            reason: 'a missing target is not an explanation:\n$result',
          );
        },
      );
    }
  });

  group('a plugin overlay', () {
    String template(String marker) =>
        'filegroup(\n    name = "{PKG}",\n    srcs = [],\n{LICENSE}\n)\n'
        'filegroup(name = "$marker")\n';

    // Where, in the overlay root, a template may sit. A package at 1.0.0
    // matches each; a more specific one wins over a less specific one.
    final rungs = {
      'the bare package directory': '',
      'the major version': '1',
      'the major and minor version': '1.0',
      'the exact version': '1.0.0',
    };

    /// Registers `overlays/` as an overlay root and gives each rung a package.
    Future<PubInputsWorkspace> workspaceWith({
      Map<String, String> files = const {},
    }) => PubInputsFixture(
      hosted: [
        for (final name in rungs.values.map(
          (r) => 'ladder_${r.replaceAll('.', '_')}',
        ))
          HostedPackage(name),
        HostedPackage(
          'android_ladder',
          pubspec: _pubspec(
            'android_ladder',
            'flutter:\n  plugin:\n    platforms:\n      android:\n        package: dev.example\n        pluginClass: P\n',
          ),
        ),
      ],
      overlayRoots: ['//overlays:BUILD.bazel'],
      files: {'overlays/BUILD.bazel': '', ...files},
    ).materialize();

    String ladder(String rung) => 'ladder_${rung.replaceAll('.', '_')}';

    void write(PubInputsWorkspace ws, String relative, String content) {
      final file = ws.file(p.join('overlays', relative));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(content);
    }

    /// An overlay is how a user fixes a plugin rules_flutter cannot build. One
    /// written after the package was first built, which is when the user finds
    /// out they need it, must be used by the next build. Adding it changes the
    /// answer of a lookup the repository rule already made (it asked whether
    /// the file existed), so the repository has to be fetched again.
    for (final rung in rungs.entries) {
      test('added at ${rung.key} after the first build is used by the next', () async {
        final ws = await workspaceWith();
        final package = ladder(rung.value);
        final before = await ws.loadSpoke(package);
        expect(before.succeeded, isTrue, reason: '$before');
        expect(before.stdout, isNot(contains('//:added')));

        write(
          ws,
          p.join(package, rung.value, 'BUILD.bazel.tpl'),
          template('added'),
        );

        final after = await ws.loadSpoke(package);
        expect(after.succeeded, isTrue, reason: '$after');
        expect(
          after.stdout,
          contains('//:added'),
          reason:
              'the overlay at ${rung.key} was written after the spoke was '
              'fetched and the next build still got the generated BUILD:\n$after',
        );
      });
    }

    /// The ladder is most specific first, so an overlay for the exact version
    /// written next to a working bare one has to win. The bare one is the
    /// file the rule read, so changing it is seen; the new one is not a file it
    /// read at all.
    test('a more specific overlay added beside an existing one wins on the next build', () async {
      final package = ladder('1.0');
      final ws = await workspaceWith(
        files: {'overlays/$package/BUILD.bazel.tpl': template('bare')},
      );
      final before = await ws.loadSpoke(package);
      expect(before.stdout, contains('//:bare'), reason: '$before');

      write(
        ws,
        p.join(package, '1.0', 'BUILD.bazel.tpl'),
        template('specific'),
      );

      final after = await ws.loadSpoke(package);
      expect(
        after.stdout,
        contains('//:specific'),
        reason:
            'a version-specific overlay was added beside the bare one and '
            'the next build still used the bare one:\n$after',
      );
    });

    /// A top-level overlay without an `android/` template has no Android
    /// package. Adding the template later must create it.
    test('an android/ template added beside an existing overlay is used by the next build', () async {
      final ws = await workspaceWith(
        files: {'overlays/android_ladder/BUILD.bazel.tpl': template('top')},
      );
      final before = await ws.query(
        '@flutter_pub__android_ladder//android:all',
      );
      expect(before.succeeded, isFalse, reason: '$before');

      write(
        ws,
        'android_ladder/android/BUILD.bazel.tpl',
        'filegroup(name = "android_added")\n',
      );

      final after = await ws.query(
        '@flutter_pub__android_ladder//android:all',
      );
      expect(
        after.stdout,
        contains('//android:android_added'),
        reason:
            'the android/ overlay was added and the next build ignored it:\n$after',
      );
    });
  });

  group('Gradle files of a plugin', () {
    late PubInputsWorkspace ws;
    setUpAll(() async {
      ws = await PubInputsFixture(
        hosted: [
          androidPlugin('apply_from', {
            'android/build.gradle': 'apply from: "deps.gradle"\n',
            'android/deps.gradle': 'dependencies {\n    implementation "applied.group:applied:3.0"\n}\n',
          }),
          androidPlugin('both_files', {
            'android/build.gradle':
                'android {\n    namespace = "dev.example.groovy"\n}\n'
                'dependencies {\n    implementation "groovy.group:groovy:1.0"\n}\n',
            'android/build.gradle.kts':
                'android {\n    namespace = "dev.example.kts"\n}\n'
                'dependencies {\n    implementation("kts.group:kts:1.0")\n}\n',
          }),
        ],
      ).materialize();
    });

    /// A dependency the reader cannot see is reported, not dropped: a build
    /// that compiles without it fails at javac or kotlinc, far from the cause.
    /// `apply from:` pulls a dependency block in from another script. Following
    /// it and reporting that it was not followed are both honest.
    test('a dependency in an applied script is read or reported', () async {
      expect((await ws.loadSpoke('apply_from')).succeeded, isTrue);
      final deps = await recordedMavenDeps(ws, 'apply_from');
      final read = deps.coordinates.contains('applied.group:applied');
      final reported = deps.unread.any(
        (line) => line.contains('deps.gradle') || line.contains('apply'),
      );
      expect(
        read || reported,
        isTrue,
        reason:
            '`apply from: "deps.gradle"` declares applied.group:applied and '
            'the spoke recorded neither it nor the line:\n'
            'read: ${deps.coordinates}, unread: ${deps.unread}',
      );
    });

    /// When a plugin has both `build.gradle` and `build.gradle.kts`, Gradle
    /// uses `build.gradle`. The namespace reader does; the dependency reader
    /// must read the same file, or the library is compiled with one script's
    /// namespace and another script's dependencies.
    test(
      'the dependencies come from the build file Gradle uses when both exist',
      () async {
        expect((await ws.loadSpoke('both_files')).succeeded, isTrue);
        final deps = await recordedMavenDeps(ws, 'both_files');
        expect(deps.coordinates, ['groovy.group:groovy']);
      },
    );
  });

  group('running pub through Bazel', () {
    /// `dart pub` records a telemetry identity and a first-run notice state
    /// under `$HOME/.dart-tool` the first time it runs. A build tool that
    /// runs it on a developer's behalf, to resolve a lock file, has no
    /// business making that choice for them: `bazel run
    /// @rules_flutter//flutter/pub` must leave the HOME it ran under as it
    /// found it. The cache is given a directory of its own so that the only
    /// thing the canary could receive is what pub writes besides packages.
    test('leaves the HOME it runs under untouched', () async {
      final ws = await PubInputsFixture(
        files: {'pubspec.yaml': 'name: app\nenvironment:\n  sdk: ^3.0.0\n'},
      ).materialize();
      final home = Directory.systemTemp.createTempSync('canary_home_');
      final cache = Directory.systemTemp.createTempSync('pub_cache_');
      addTearDown(() {
        home.deleteSync(recursive: true);
        cache.deleteSync(recursive: true);
      });

      // `--run_under` sets HOME for the tool alone: setting it for the
      // `bazel` client would move Bazel's own output base into the canary.
      final result = await ws.bazel([
        'run',
        '--run_under=env -u CI -u GITHUB_ACTIONS -u BUILD_ID '
            'HOME=${home.path} PUB_CACHE=${cache.path}',
        '@rules_flutter//flutter/pub',
        '--',
        'get',
      ]);
      expect(result.succeeded, isTrue, reason: 'pub get failed:\n$result');

      final written = [
        for (final entity in home.listSync(recursive: true, followLinks: false))
          p.relative(entity.path, from: home.path),
      ];
      expect(
        written,
        isEmpty,
        reason: 'pub wrote into the HOME it was run under',
      );
    });
  });
}
