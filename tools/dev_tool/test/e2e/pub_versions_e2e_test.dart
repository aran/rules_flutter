/// Several `flutter_pub.from_lock()` locks share one repository per package, so
/// they must agree on what a package is.
///
/// **The properties:**
///
///  1. Two hubs that list a package at one version share it: both labels reach
///     the one `flutter_pub_lib__<package>` repository, and no repository of
///     either hub's name exists.
///  2. Each lock's version is a minimum and the highest is built, in whichever
///     module's lock it is. Raising another module's lock says nothing.
///     Raising one of the root's own prints a warning naming both versions,
///     both locks and the command that raises the root's;
///     `flutter_pub.settings(check_direct_dependencies = ...)` silences it at
///     `"off"` and makes it fail at `"error"`. That command runs while the
///     failure stands (the toolchain it needs is another extension's), and
///     after it the hub analyses.
///  3. Locks that disagree on where a package comes from, on its registry, or
///     on the digest of one version, fail naming both, at every level.
///  4. A package mapped with `resolve` is that target for every hub and the
///     locked package is never fetched; two different maps fail naming both.
///  5. Two tags of one name are one hub.
///  6. Only the root may ignore a hook: a dependency module's `ignore_hooks`
///     fails, so it cannot silence the root's programs.
///  7. A lock moved to another version of a package builds that version with
///     the dependencies its own pubspec declares, in the output base that
///     built the old one.
///
/// Package names no lock of this repository lists, so the repository's own
/// tool lock (which every consumer build reads) does not take part.
@Tags(['e2e'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'pub_inputs_fixture.dart';

const _otherHub = 'otherhub';

FixtureHub _other(
  List<HostedPackage> hosted, {
  String extraLockEntries = '',
  Map<String, String> resolve = const {},
  String name = _otherHub,
}) => FixtureHub(
  name: name,
  lockPackage: 'other',
  hosted: hosted,
  extraLockEntries: extraLockEntries,
  resolve: resolve,
);

const _depModule = 'depmod';

/// A module the root depends on, whose one lock holds [hosted].
FixtureModule _dependency(
  List<HostedPackage> hosted, {
  List<String> ignoreHooks = const [],
}) => FixtureModule(
  _depModule,
  hubs: [
    FixtureHub(
      name: 'dephub',
      lockPackage: '',
      hosted: hosted,
      ignoreHooks: ignoreHooks,
    ),
  ],
);

/// What the warning or error for a raised root lock says first.
const _raised = 'newer than the root module asks for';

/// The pubspec of the version of [package] the build fetched.
Future<String> _builtPubspec(
  PubInputsWorkspace ws, [
  String package = 'vplain',
]) async {
  final spoke = await ws.spokeDirectory(package);
  return File(p.join(spoke.path, 'pubspec.yaml')).readAsStringSync();
}

/// A `dart_library` for [name], at `<dir>/BUILD.bazel`.
Map<String, String> _target(String dir, String name) => {
  p.posix.join(dir, 'lib', '$name.dart'): 'int value = 1;\n',
  p.posix.join(dir, 'BUILD.bazel'):
      'load("@rules_dart//dart:defs.bzl", "dart_library", "dart_package_metadata")\n'
      'dart_package_metadata(name = "pubspec-metadata", package_name = "$name")\n'
      'dart_library(\n'
      '    name = "$name",\n'
      '    package = ":pubspec-metadata",\n'
      '    srcs = glob(["lib/**/*.dart"]),\n'
      '    visibility = ["//visibility:public"],\n'
      ')\n',
};

/// A package [name] at [version] whose library uses [dependency]'s, as its
/// pubspec declares.
HostedPackage _using(String name, String version, String dependency) =>
    HostedPackage(
      name,
      version: version,
      pubspec:
          '${HostedPackage.defaultPubspec(name, version)}'
          'dependencies:\n  $dependency: ^1.0.0\n',
      files: {
        'lib/$name.dart':
            "import 'package:$dependency/$dependency.dart' as dep;\n"
            'int value = dep.value;\n',
      },
    );

void main() {
  test(
    'a lock moved to another version builds it with that version\'s '
    'dependencies',
    () async {
      // vmover 1.0.0 uses vdep_a and 2.0.0 uses vdep_b, as package_config 2.2.0
      // uses `path` and 3.0.0 `meta`. The lock lists both dependencies
      // throughout, so only what each version declares tells them apart.
      final depA = HostedPackage('vdep_a');
      final depB = HostedPackage('vdep_b');
      final old = _using('vmover', '1.0.0', 'vdep_a');
      final moved = _using('vmover', '2.0.0', 'vdep_b');
      final ws = await PubInputsFixture(
        hosted: [old, depA, depB],
        served: [moved],
        files: {
          'app/main.dart':
              "import 'package:vmover/vmover.dart';\n"
              'void main() => print(value);\n',
          'app/BUILD.bazel':
              'load("@rules_dart//dart:defs.bzl", "dart_binary")\n'
              'dart_binary(\n'
              '    name = "app",\n'
              '    main = "main.dart",\n'
              '    deps = ["@$pubHub//:vmover"],\n'
              ')\n',
        },
      ).materialize();

      Future<String> recorded() async {
        final spoke = await ws.spokeDirectory('vmover');
        return File(
          p.join(spoke.path, 'pubspec_dependencies.txt'),
        ).readAsStringSync().trim();
      }

      final before = await ws.bazel(['build', '//app']);
      expect(before.succeeded, isTrue, reason: '$before');
      expect(await recorded(), 'vdep_a');

      ws.writeLock(ws.lockOf([moved, depA, depB]));
      final after = await ws.bazel(['build', '//app']);
      expect(await _builtPubspec(ws, 'vmover'), contains('version: 2.0.0'));
      expect(after.succeeded, isTrue, reason: '$after');
      expect(await recorded(), 'vdep_b');
    },
  );

  test('two hubs listing a package share one repository', () async {
    final plain = HostedPackage('vplain');
    final ws = await PubInputsFixture(
      hosted: [plain],
      otherHubs: [
        _other([plain]),
      ],
    ).materialize();

    for (final label in ['@pubhub//:vplain', '@$_otherHub//:vplain']) {
      final result = await ws.query(label);
      expect(result.succeeded, isTrue, reason: '$result');
    }
    final deps = await ws.bazel([
      'query',
      'deps(@pubhub//:vplain + @$_otherHub//:vplain, 1)',
      '--output=label',
    ]);
    expect(deps.succeeded, isTrue, reason: '$deps');
    final libraries = deps.stdout
        .split('\n')
        .where((l) => l.endsWith('flutter_pub_lib__vplain//:vplain'))
        .toSet();
    expect(libraries, hasLength(1), reason: '$deps');
    expect(deps.stdout, isNot(contains('pubhub__vplain')));
    expect(deps.stdout, isNot(contains('${_otherHub}__vplain')));
  });

  test(
    'raising a dependency module\'s lock builds the higher version, saying '
    'nothing',
    () async {
      final ws = await PubInputsFixture(
        hosted: [HostedPackage('vplain', version: '1.1.0')],
        modules: [
          _dependency([HostedPackage('vplain', version: '1.0.0')]),
        ],
      ).materialize();

      final result = await ws.loadSpoke('vplain');
      expect(result.succeeded, isTrue, reason: '$result');
      expect(result.output, isNot(contains(_raised)), reason: '$result');
      expect(await _builtPubspec(ws), contains('version: 1.1.0'));
    },
  );

  for (final check in [null, 'off'])
    test(
      'a dependency module raising the root\'s lock builds the higher version'
      '${check == null ? ', warning' : ', silently at "$check"'}',
      () async {
        final ws = await PubInputsFixture(
          hosted: [HostedPackage('vplain', version: '1.0.0')],
          checkDirectDependencies: check,
          modules: [
            _dependency([HostedPackage('vplain', version: '1.1.0')]),
          ],
        ).materialize();

        final result = await ws.loadSpoke('vplain');
        expect(result.succeeded, isTrue, reason: '$result');
        if (check == null) {
          expect(
            result.output,
            allOf(
              contains('"vplain" is built at 1.1.0, $_raised'),
              contains('1.0.0, from the lock `//:pubspec.lock`\n'),
              contains(
                '1.1.0, from the lock `//:pubspec.lock` in module `$_depModule`',
              ),
              contains(
                'bazel run @rules_flutter//flutter/pub -- upgrade vplain',
              ),
              contains(
                '`flutter_pub.settings(check_direct_dependencies = "off")`',
              ),
            ),
            reason: '$result',
          );
        } else {
          expect(result.output, isNot(contains(_raised)), reason: '$result');
        }
        expect(await _builtPubspec(ws), contains('version: 1.1.0'));
      },
    );

  test(
    'a root lock behind another of the root\'s builds the higher version, '
    'warning',
    () async {
      final ws = await PubInputsFixture(
        hosted: [HostedPackage('vplain', version: '1.0.0')],
        otherHubs: [
          _other([HostedPackage('vplain', version: '1.1.0')]),
        ],
      ).materialize();

      final result = await ws.loadSpoke('vplain');
      expect(result.succeeded, isTrue, reason: '$result');
      expect(
        result.output,
        allOf(
          contains('"vplain" is built at 1.1.0, $_raised'),
          contains('1.1.0, from the lock `//other:pubspec.lock`'),
        ),
        reason: '$result',
      );
      expect(await _builtPubspec(ws), contains('version: 1.1.0'));
    },
  );

  test(
    'a raised root lock at "error" fails when the module is read',
    () async {
      final ws = await PubInputsFixture(
        hosted: [HostedPackage('vplain', version: '1.0.0')],
        checkDirectDependencies: 'error',
        modules: [
          _dependency([HostedPackage('vplain', version: '1.1.0')]),
        ],
      ).materialize();

      final result = await ws.query('@pubhub//:vplain');
      expect(result.succeeded, isFalse, reason: '$result');
      expect(
        result.output,
        allOf(
          contains('"vplain" is built at 1.1.0, $_raised'),
          contains('1.0.0, from the lock `//:pubspec.lock`\n'),
          contains('in module `$_depModule`'),
          contains('pub -- upgrade vplain'),
        ),
        reason: '$result',
      );
    },
  );

  // The runner must not build anything from either pub extension: rules_dart's
  // own `pub` fails on the same conflict, and the command is what fixes it.
  for (final alsoRulesDart in [false, true])
    test(
      'the command a raised root lock names at "error" runs while the failure '
      'stands, and fixes it${alsoRulesDart ? ', with rules_dart\'s pub extension failing on the same locks' : ''}',
      () async {
        final ws = await PubInputsFixture(
          http: true,
          lockPackage: 'app',
          rulesDartPubLocks: alsoRulesDart ? ['app', 'other'] : [],
          checkDirectDependencies: 'error',
          hosted: [HostedPackage('vplain', version: '1.0.0')],
          files: {
            'app/pubspec.yaml':
                'name: app\n'
                'environment:\n'
                '  sdk: ^3.0.0\n'
                'dependencies:\n'
                '  vplain:\n'
                '    hosted: "{{SERVER}}"\n'
                '    version: ^1.0.0\n',
          },
          otherHubs: [
            _other([HostedPackage('vplain', version: '1.1.0')]),
          ],
        ).materialize();

        if (alsoRulesDart) {
          // rules_dart's own extension really does refuse these locks.
          final dart = await ws.query('@dartdeps//:vplain');
          expect(dart.succeeded, isFalse, reason: '$dart');
          expect(
            dart.output,
            allOf(contains('rules_dart'), contains('vplain')),
            reason: '$dart',
          );
        }

        final conflict = await ws.query('@pubhub//:vplain');
        expect(conflict.succeeded, isFalse, reason: '$conflict');
        final commands =
            RegExp(
                  r'^\s*bazel run (\S+) -- (.+)$',
                  multiLine: true,
                )
                .allMatches(conflict.output)
                .where((m) => m.group(1)!.contains('flutter/pub'))
                .toList();
        expect(commands, hasLength(1), reason: '$conflict');
        final command = commands.single;

        // The cache is the test's own, so the packages of its registry do not
        // land in the developer's.
        final cache = Directory.systemTemp.createTempSync('pub_cache_');
        addTearDown(() => cache.deleteSync(recursive: true));
        final fixed = await ws.bazel(
          [
            'run',
            command.group(1)!,
            '--',
            ...command.group(2)!.trim().split(RegExp(r'\s+')),
          ],
          environment: {'PUB_CACHE': cache.path},
        );
        expect(fixed.succeeded, isTrue, reason: '$fixed');
        expect(
          ws.file('app/pubspec.lock').readAsStringSync(),
          contains('version: "1.1.0"'),
        );

        final analysed = await ws.bazel([
          'build',
          '--nobuild',
          '@pubhub//:vplain',
        ]);
        expect(analysed.succeeded, isTrue, reason: '$analysed');
      },
    );

  test(
    'a package hosted in one lock and in a repository in another fails',
    () async {
      final ws = await PubInputsFixture(
        git: [GitPackage('vplain')],
        otherHubs: [
          _other([HostedPackage('vplain')]),
        ],
      ).materialize();

      final result = await ws.query('@pubhub//:vplain');
      expect(result.succeeded, isFalse, reason: '$result');
      expect(
        result.output,
        allOf(
          contains('"vplain" is a git package in'),
          contains('and a hosted package in'),
          contains('//other:pubspec.lock'),
        ),
        reason: '$result',
      );
    },
  );

  test(
    'one version with two digests fails, naming both, at any level',
    () async {
      final plain = HostedPackage('vplain');
      final ws = await PubInputsFixture(
        hosted: [plain],
        checkDirectDependencies: 'off',
        otherHubs: [
          _other(
            [],
            extraLockEntries:
                '  vplain:\n'
                '    dependency: "direct main"\n'
                '    description:\n'
                '      name: vplain\n'
                '      sha256: "${'ab' * 32}"\n'
                '      url: "{{SERVER}}"\n'
                '    source: hosted\n'
                '    version: "1.0.0"\n',
          ),
        ],
      ).materialize();

      final result = await ws.query('@pubhub//:vplain');
      expect(result.succeeded, isFalse, reason: '$result');
      expect(
        result.output,
        allOf(
          contains('"vplain" 1.0.0 has conflicting sha256 digests'),
          contains('ab' * 32),
          contains('//other:pubspec.lock'),
          contains(
            'bazel run @rules_flutter//flutter/pub -- get --directory=other',
          ),
        ),
        reason: '$result',
      );
    },
  );

  test(
    'two registries for one package fail, naming both, at any level',
    () async {
      final ws = await PubInputsFixture(
        hosted: [HostedPackage('vplain')],
        checkDirectDependencies: 'off',
        otherHubs: [
          _other(
            [],
            extraLockEntries:
                '  vplain:\n'
                '    dependency: "direct main"\n'
                '    description:\n'
                '      name: vplain\n'
                '      sha256: "${'ab' * 32}"\n'
                '      url: "https://pub.example.invalid"\n'
                '    source: hosted\n'
                '    version: "1.1.0"\n',
          ),
        ],
      ).materialize();

      final result = await ws.query('@pubhub//:vplain');
      expect(result.succeeded, isFalse, reason: '$result');
      expect(
        result.output,
        allOf(
          contains('"vplain" is fetched from different registries'),
          contains('https://pub.example.invalid'),
          contains('//other:pubspec.lock'),
        ),
        reason: '$result',
      );
    },
  );

  test(
    'a mapped package is that target for every hub, never fetched',
    () async {
      final plain = HostedPackage('vplain');
      final ws = await PubInputsFixture(
        hosted: [plain],
        resolve: {'vplain': '//mapped:vplain'},
        files: _target('mapped', 'vplain'),
        otherHubs: [
          _other([HostedPackage('vplain', version: '9.9.9')]),
        ],
      ).materialize();

      for (final hub in ['pubhub', _otherHub]) {
        final deps = await ws.bazel([
          'query',
          'deps(@$hub//:vplain, 2)',
          '--output=label',
        ]);
        expect(deps.succeeded, isTrue, reason: '$deps');
        expect(deps.stdout, contains('//mapped:vplain'), reason: '$deps');
      }
      // The repository is the mapped target's forwarder: none of a package's
      // files, though two of the locks list one.
      final spoke = await ws.spokeDirectory('vplain');
      expect(File(p.join(spoke.path, 'pubspec.yaml')).existsSync(), isFalse);
    },
  );

  test('a package mapped to two targets fails, naming both', () async {
    final plain = HostedPackage('vplain');
    final ws = await PubInputsFixture(
      hosted: [plain],
      resolve: {'vplain': '//mapped:vplain'},
      files: {..._target('mapped', 'vplain'), ..._target('remapped', 'vplain')},
      otherHubs: [
        _other([plain], resolve: {'vplain': '//remapped:vplain'}),
      ],
    ).materialize();

    final result = await ws.query('@pubhub//:vplain');
    expect(result.succeeded, isFalse, reason: '$result');
    expect(
      result.output,
      allOf(
        contains('"vplain" is mapped to different targets'),
        contains('//mapped:vplain'),
        contains('//remapped:vplain'),
      ),
      reason: '$result',
    );
  });

  test('a dependency module\'s ignore_hooks fails', () async {
    final ws = await PubInputsFixture(
      hosted: [HostedPackage('vplain')],
      modules: [
        _dependency([HostedPackage('vplain')], ignoreHooks: ['vplain']),
      ],
    ).materialize();

    final result = await ws.query('@pubhub//:vplain');
    expect(result.succeeded, isFalse, reason: '$result');
    expect(
      result.output,
      allOf(
        contains('Module `$_depModule` ignores the build hooks of `vplain`'),
        contains('only the root module may do'),
      ),
      reason: '$result',
    );
  });

  test('two tags of one name are one hub holding both locks', () async {
    final ws = await PubInputsFixture(
      hosted: [HostedPackage('vone')],
      otherHubs: [
        _other([HostedPackage('vtwo')], name: 'pubhub'),
      ],
    ).materialize();

    final hub = await ws.query('@pubhub//:all');
    expect(hub.succeeded, isTrue, reason: '$hub');
    expect(hub.stdout, contains('@pubhub//:vone'));
    expect(hub.stdout, contains('@pubhub//:vtwo'));
  });
}
