/// An app built against a framework and an engine that are not the release's.
///
/// **The properties** (`e2e/custom_engine`, whose checkout is the official
/// artifacts laid out as a flutter/flutter checkout with engine out dirs):
///
///  1. Built with the SDK that names the checkout, in release and in debug, the
///     macOS app carries `flutter_assets/flutter_sdk.json`: the out dirs and the
///     checkout it came from, the snapshot hash and the kernel format, and no
///     path of the machine that built it.
///  2. The release's apps carry no such file.
///  3. A gen_snapshot of another Dart than the engine's fails the build, naming
///     both and their hashes.
///  4. A checkout given by `--repo_env=FLUTTER_CHECKOUT` and `FLUTTER_ENGINE` works; not set, the
///     repositories still load (`bazel query`) and a build that selects the SDK
///     says what to set. `FLUTTER_LOCAL_ENGINES` chooses only for the slots its
///     names fit, and a name that is no out dir fails. A `flutter.checkout`
///     given by `FLUTTER_CHECKOUT` alone takes its engine from the checkout's
///     `engine/src`, never from `FLUTTER_ENGINE`: the dev tool and the
///     program are told the checkout's version and the revision its engine
///     was built at. The `local` SDK of the other cases is a
///     `flutter.checkout`.
///  5. The iOS simulator app (debug) and the iOS device framework (release) are
///     built from the checkout's `ios_debug_sim_arm64` and `ios_release` out
///     dirs and record them.
///  6. The Android APK is built from the checkout's `android_<mode>_<cpu>` out
///     dirs for each ABI it carries, and records the first ABI's.
///  7. The iOS device framework and the Android APK refuse a gen_snapshot of
///     another Dart, as the macOS app does.
///  8. A Linux bundle, cross-built from the Mac, is built from the checkout's
///     `linux_debug` out dir and records it; the Windows and Linux arm64
///     engines are slices too, and a desktop gen_snapshot is the machine's own.
///  9. The web app is built from the checkout's `wasm_release` web SDK with its
///     renderer, records it (the kernel check, no snapshot hash), passes the
///     web render check, and refuses a web SDK of another Dart.
/// 10. A `flutter_test` runs under the checkout's SDK: its modules compile
///     against the checkout's platform kernel and are told the checkout's
///     framework and engine.
/// 11. The dev tool is told the checkout's version and its engine's full
///     revision, the ones `FLUTTER_VERSION` and `FLUTTER_ENGINE_REVISION` tell
///     the program.
/// 12. The checkout's framework over the release engine takes the Material
///     fonts its `bin/internal/material_fonts.version` names.
/// 13. A release's framework over the checkout's engine
///     (`flutter.custom_engine`) builds the macOS app from the checkout's out
///     dirs and records the release's framework; pub resolves against the
///     release's packages.
/// 14. The analyzer's `sky_engine` and the licences `NOTICES` lists are the
///     selected SDK's engine's.
/// 15. Every repository of the `flutter` and `pub` extensions that reads an
///     SDK's sources fetches, with the checkouts unset and with a checkout
///     whose engine is not built: only a build that uses such an SDK fails. A
///     checkout's version is the one flutter_tools tells from its tags.
/// 16. A checkout SDK's toolchains, and a custom engine's whose `hosts` is
///     `host`, run on the machine alone, so another execution platform
///     listed first does not take the build.
/// 17. The Android plugins' Maven data and the Apple libraries that read the
///     app are those of the selected SDK's packages: building them reads no
///     other SDK's.
@Tags(['e2e', 'app_builds'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart' show E2eApp;

const _sdkFlag = '--@rules_flutter//flutter:sdk=';

/// Why a case cannot run here, for the ones that build Apple targets.
final String? _appleOnly = Platform.isMacOS ? null : 'builds Apple targets';

/// The stand-in checkout's host build: on a Mac `host_<mode>_arm64`, on an
/// x86_64 Linux machine `host_<mode>`, which also holds the Linux engine.
String _host(String mode) =>
    Platform.isLinux ? 'host_$mode' : 'host_${mode}_arm64';

/// The engine repository of the `local` SDK, the stand-in checkout's, which
/// `flutter.checkout` declares.
const _localEngineRepo = 'local_checkout_engine';
const _localEngine = '@@rules_flutter++flutter+$_localEngineRepo';

/// The stock Dart's snapshot hash, which the stand-in's engine and
/// gen_snapshot carry.
const _snapshotHash = '6b959e9909a17b8e29b0663a6d99e646';

/// The app under test.
const _app = E2eApp('custom_engine');

Future<ProcessResult> _bazel(List<String> args) => Process.run('bazel', [
  ...args,
  '--noshow_progress',
  '--curses=no',
  '--color=no',
], workingDirectory: _app.moduleRoot);

/// The `flutter_sdk.json` that [target] built with [sdk] and [extra] carries,
/// or null when it has none: in an archive of the app (`.zip`, `.ipa`, `.apk`)
/// or in the files it is made of.
Future<Map<String, Object?>?> _record(
  String sdk,
  List<String> extra, {
  String? target,
}) async {
  final label = target ?? _app.label(':app');
  final build = await _bazel([
    'build',
    label,
    '$_sdkFlag$sdk',
    ...extra,
  ]);
  expect(build.exitCode, 0, reason: '${build.stderr}');
  final files = await _bazel([
    'cquery',
    label,
    '$_sdkFlag$sdk',
    ...extra,
    '--output=files',
  ]);
  final out = Directory.systemTemp.createTempSync('custom_engine');
  addTearDown(() async {
    // Built files are read-only, and `cp -R` keeps that.
    await Process.run('chmod', ['-R', 'u+w', out.path]);
    out.deleteSync(recursive: true);
  });
  var unpacked = 0;
  final built = (files.stdout as String).split('\n').where((l) => l.isNotEmpty);
  for (final file in built) {
    final path = p.join(_app.root, file);
    final into = p.join(out.path, '${unpacked++}');
    if (RegExp(r'(?<!_unsigned)\.(zip|ipa|apk)$').hasMatch(file)) {
      await Process.run('unzip', ['-q', path, '-d', into]);
    } else if (Directory(path).existsSync()) {
      await Process.run('cp', ['-RL', path, into]);
    }
  }
  for (final f in out.listSync(recursive: true)) {
    if (f is File && p.basename(f.path) == 'flutter_sdk.json') {
      return jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
    }
  }
  return null;
}

/// The dev configs (`app_flutter_dev_config.json`) that building
/// `//:app_flutter` with [flags] wrote.
Future<List<Map<String, Object?>>> _devConfigs(List<String> flags) async {
  final target = _app.label(':app_flutter');
  final build = await _bazel(['build', target, ...flags]);
  expect(build.exitCode, 0, reason: '${build.stderr}');
  final files = await _bazel(['cquery', target, ...flags, '--output=files']);
  // cquery lists the target in every configuration it was analysed in,
  // the app's earlier builds' included: check each one that was built.
  final configs = (files.stdout as String)
      .split('\n')
      .where((f) => p.basename(f) == 'app_flutter_dev_config.json')
      .map((f) => File(p.join(_app.root, f)))
      .where((f) => f.existsSync())
      .map((f) => jsonDecode(f.readAsStringSync()) as Map<String, Object?>)
      .toList();
  expect(configs, isNotEmpty);
  return configs;
}

/// The directory of the stand-in checkout's [file], such as
/// `checkout/CHECKOUT`.
Future<String> _fakeCheckoutDir(String file) async {
  final location = await _bazel([
    'query',
    '@fake_checkout//:$file',
    '--output=location',
  ]);
  expect(location.exitCode, 0, reason: '${location.stderr}');
  return p.dirname(
    '${location.stdout}'.trim().replaceFirst(RegExp(r':\d+:\d+:.*$'), ''),
  );
}

/// The path of the one file [label] gives under [sdk].
Future<String> _fileOf(String label, String sdk) async {
  final files = await _bazel([
    'cquery',
    label,
    '$_sdkFlag$sdk',
    '--output=files',
  ]);
  expect(files.exitCode, 0, reason: '${files.stderr}');
  return '${files.stdout}'.trim();
}

/// The rules whose repositories only download pinned artifacts: their fetch
/// fails only for the network or a checksum, never for what an SDK's
/// sources hold, so the fetch case leaves them out.
const _downloads = {
  'dart_sdk_source_tool',
  'dart_source_packages',
  'flutter_archive_repo',
  'flutter_linux_runtime_repo',
  'flutter_source_files',
  'flutter_stock_engine_repo',
  'pub_archive_files',
};

/// The canonical names of the repositories of the `flutter` and `pub`
/// extensions, but for those of the rules in [_downloads].
Future<List<String>> _sourceReadingRepos() async {
  const extensions = {
    '@rules_flutter//flutter:extensions.bzl%flutter': 'rules_flutter++flutter+',
    '@rules_flutter//flutter/pub:extensions.bzl%pub': 'rules_flutter++pub+',
  };
  final repos = <String>[];
  for (final MapEntry(key: extension, value: prefix) in extensions.entries) {
    final shown = await _bazel(['mod', 'show_extension', extension]);
    expect(shown.exitCode, 0, reason: '${shown.stderr}');
    final listed = '${shown.stdout}'
        .split('Fetched repositories:')
        .last
        .split('\n## ')
        .first;
    repos.addAll(
      RegExp(
        r'^  - (\S+)',
        multiLine: true,
      ).allMatches(listed).map((m) => '$prefix${m[1]}'),
    );
  }
  final shown = await _bazel([
    'mod',
    'show_repo',
    for (final repo in repos) '@@$repo',
  ]);
  expect(shown.exitCode, 0, reason: '${shown.stderr}');
  final kept = <String>[];
  for (final block
      in '${shown.stdout}'.split(RegExp(r'^## @@', multiLine: true)).skip(1)) {
    final name = block.substring(0, block.indexOf(':'));
    final rule = RegExp(r'^(\w+)\($', multiLine: true).firstMatch(block)![1]!;
    if (!_downloads.contains(rule)) kept.add(name);
  }
  return kept;
}

/// A flutter/flutter checkout whose engine is not built: its framework,
/// one commit past the release's tag, and an empty `engine/src/out`.
Future<String> _unbuiltCheckout() async {
  final framework = await _fakeCheckoutDir('checkout/CHECKOUT');
  final dir = Directory.systemTemp.createTempSync('unbuilt_checkout');
  addTearDown(() => dir.deleteSync(recursive: true));
  Link(p.join(dir.path, 'packages')).createSync(p.join(framework, 'packages'));
  File(p.join(dir.path, 'bin', 'internal', 'material_fonts.version'))
    ..createSync(recursive: true)
    ..writeAsStringSync(
      File(
        p.join(framework, 'bin', 'internal', 'material_fonts.version'),
      ).readAsStringSync(),
    );
  Directory(p.join(dir.path, 'engine', 'src', 'out'))
      .createSync(recursive: true);
  for (final args in [
    ['init', '--quiet', '--initial-branch=main'],
    ['add', '--all'],
    ['commit', '--quiet', '--message=release'],
    ['tag', '3.50.0'],
    ['commit', '--quiet', '--allow-empty', '--message=past the release'],
  ]) {
    await _git(dir.path, args);
  }
  return dir.path;
}

/// Runs git in [dir] without the machine's git configuration: the commits
/// are the test's.
Future<void> _git(String dir, List<String> args) async {
  const environment = {
    'GIT_CONFIG_GLOBAL': '/dev/null',
    'GIT_CONFIG_NOSYSTEM': '1',
    'GIT_CONFIG_COUNT': '0',
    'GIT_AUTHOR_NAME': 'test',
    'GIT_AUTHOR_EMAIL': 'test@example.com',
    'GIT_COMMITTER_NAME': 'test',
    'GIT_COMMITTER_EMAIL': 'test@example.com',
  };
  final git = await Process.run(
    'git',
    ['-C', dir, ...args],
    environment: environment,
  );
  expect(git.exitCode, 0, reason: 'git $args: ${git.stderr}');
}

/// The `flutter_framework.json` of the `env_checkout` SDK, with
/// `FLUTTER_CHECKOUT` set to [checkout].
Future<Map<String, Object?>> _envCheckoutFramework(String checkout) async {
  final record = await _bazel([
    'query',
    '@@rules_flutter++flutter+env_checkout_checkout_framework//:flutter_framework.json',
    '--output=location',
    '--repo_env=FLUTTER_CHECKOUT=$checkout',
    '--repo_env=FLUTTER_ENGINE=$checkout/engine/src',
  ]);
  expect(record.exitCode, 0, reason: '${record.stderr}');
  return jsonDecode(
    File(
      '${record.stdout}'.trim().replaceFirst(RegExp(r':\d+:\d+:.*$'), ''),
    ).readAsStringSync(),
  ) as Map<String, Object?>;
}

/// The names of the out dirs [record] says its engine pieces came from.
Set<Object?> _outDirs(Map<String, Object?> record) =>
    (record['engine'] as Map).values.map((e) => (e as Map)['out_dir']).toSet();

/// What every record must be: the checkout's, with no path of this machine.
///
/// A web app links no engine binary or gen_snapshot, so its record has no
/// snapshot hash: the web SDK's kernel is what it checks.
void _expectRecordOfTheCheckout(
  Map<String, Object?> record, {
  bool hasSnapshotHash = true,
}) {
  expect(record['sdk'], 'local');
  if (hasSnapshotHash) {
    expect(record['snapshot_hash'], _snapshotHash);
  } else {
    expect(record, isNot(contains('snapshot_hash')));
  }
  expect(record['framework'], containsPair('origin', 'local'));
  expect(
    jsonEncode(record),
    isNot(contains(Directory.current.parent.path)),
    reason: 'no machine path in the record',
  );
  expect(
    jsonEncode(record).contains('"/'),
    isFalse,
    reason: 'no absolute path in the record',
  );
}

/// The `FLUTTER_FRAMEWORK_REVISION` define of the stand-in checkout: the first
/// ten characters of its commit, as `FlutterVersion.frameworkRevision` is.
Future<String> _standInRevisionDefine() async {
  final checkout = await _fakeCheckoutDir('checkout/CHECKOUT');
  final head = await Process.run('git', ['-C', checkout, 'rev-parse', 'HEAD']);
  expect(head.exitCode, 0, reason: '${head.stderr}');
  return 'FLUTTER_FRAMEWORK_REVISION=${(head.stdout as String).trim().substring(0, 10)}';
}

/// The Linux platform a Mac cross-builds a (debug) bundle for.
const _linuxPlatform =
    '--platforms=@rules_flutter//flutter/platforms:linux_x64';

/// The iOS device platform: the framework is built outside an application's
/// own platform transition here, so the platform is named.
const _iosDevice = '--platforms=@rules_flutter//flutter/platforms:ios_arm64';

const _allAbis =
    '--@rules_android//flags:android_platforms='
    '@rules_android//:armeabi-v7a,@rules_android//:arm64-v8a,@rules_android//:x86_64';

String _abiFlag(String abi) =>
    '--@rules_android//flags:android_platforms=@rules_android//:$abi';

void main() {
  // The tests are grouped by the options they build with: Bazel drops its
  // analysis cache whenever they change, and analysing this workspace again
  // costs more than most of the builds. Each group's options are the comment
  // above it; `--@rules_flutter//flutter:sdk=` is `local` unless it says
  // otherwise.

  void appRecordsTheCheckout(String mode, List<String> flags) {
    test('the $mode app records the checkout it was built from', () async {
      final record = (await _record('local', flags))!;
      _expectRecordOfTheCheckout(record);
      expect(_outDirs(record), contains('host_${mode}_arm64'));
    }, skip: _appleOnly);
  }

  void apkRecordsOutDir(String abi, String cpu) {
    test('the $abi APK records the $cpu out dir', skip: _appleOnly, () async {
      final record = (await _record(
        'local',
        [_abiFlag(abi)],
        target: _app.label(':android_app'),
      ))!;
      _expectRecordOfTheCheckout(record);
      expect(
        _outDirs(record),
        contains('android_release${cpu.isEmpty ? '' : '_$cpu'}'),
      );
    });
  }

  // The release SDK, then the local one.
  test('the program is told what the selected SDK is', () async {
    Future<String> kernelDefines(String sdk) async {
      final aquery = await _bazel([
        'aquery',
        'mnemonic(".*Kernel.*", //:app_flutter)',
        '$_sdkFlag$sdk',
        '--output=text',
      ]);
      expect(aquery.exitCode, 0, reason: '${aquery.stderr}');
      return RegExp(
        r'FLUTTER_[A-Z_]+=[^ ,\x27"]*',
      ).allMatches('${aquery.stdout}').map((m) => m.group(0)).toSet().join(' ');
    }

    // The release's framework revision is versions.bzl's; the stand-in
    // checkout's is its commit.
    expect(
      await kernelDefines('flutter'),
      isNot(matches(RegExp(r'FLUTTER_FRAMEWORK_REVISION=( |$)'))),
    );
    expect(
      await kernelDefines('local'),
      allOf(
        contains(await _standInRevisionDefine()),
        contains('FLUTTER_ENGINE_REVISION=371f77202a'),
      ),
    );
  });

  // The local SDK alone.
  appRecordsTheCheckout('release', const []);

  // .bazelrc's ABI, so these options too.
  apkRecordsOutDir('arm64-v8a', 'arm64');

  test(
    'a Linux machine builds its release bundle with its own gen_snapshot',
    () async {
      final record = (await _record(
        'local',
        const [],
        target: _app.label(':linux_app'),
      ))!;
      _expectRecordOfTheCheckout(record);
      expect(_outDirs(record), containsAll(['host_release']));
      expect(
        (record['engine'] as Map).keys,
        contains(endsWith('//linux-x64/release:gen_snapshot_linux-x64')),
      );
    },
    skip: Platform.isLinux ? null : 'a Linux machine only',
  );

  test('the web app is built from the web SDK and records it', () async {
    final record = (await _record(
      'local',
      const [],
      target: _app.label(':web_app'),
    ))!;
    _expectRecordOfTheCheckout(record, hasSnapshotHash: false);
    expect(_outDirs(record), containsAll(['wasm_release', _host('debug')]));

    // The renderer comes from the web SDK, as the CDN has none for this engine.
    final files = await _bazel([
      'cquery',
      _app.label(':web_app'),
      '${_sdkFlag}local',
      '--output=files',
    ]);
    final bundle = (files.stdout as String)
        .split('\n')
        .firstWhere((l) => l.endsWith('_web'));
    final root = p.join(_app.root, bundle);
    expect(
      File(p.join(root, 'canvaskit', 'canvaskit.wasm')).existsSync(),
      isTrue,
    );
    expect(
      File(p.join(root, 'flutter_bootstrap.js')).readAsStringSync(),
      contains('"useLocalCanvasKit":true'),
    );
  });

  test('the web compilers read the checkout\'s platform kernels', () async {
    final aquery = await _bazel([
      'aquery',
      'mnemonic("FlutterDart2JS|FlutterDart2Wasm", //:web_app)',
      '${_sdkFlag}local',
      '--output=text',
    ]);
    expect(aquery.exitCode, 0, reason: '${aquery.stderr}');
    final dills = RegExp(
      r'[\w+./-]*(?:dart2js|dart2wasm)_platform\.dill',
    ).allMatches('${aquery.stdout}').map((m) => m.group(0)!).toSet();
    expect(dills, isNotEmpty);
    expect(dills, everyElement(contains(_localEngineRepo)));
  });

  test('the web render check passes against the checkout\'s web SDK', () async {
    final test = await _bazel([
      'test',
      _app.label(':web_render_test'),
      '${_sdkFlag}local',
      '--test_output=errors',
    ]);
    expect(test.exitCode, 0, reason: '${test.stdout}${test.stderr}');
  });

  test('a flutter_test runs under the checkout\'s SDK', () async {
    final test = await _bazel([
      'test',
      _app.label(':widget_test'),
      '${_sdkFlag}local',
      '--test_output=errors',
    ]);
    expect(test.exitCode, 0, reason: '${test.stdout}${test.stderr}');

    // Its modules and its entrypoint compile against the checkout's platform
    // kernel, not the release's.
    final aquery = await _bazel([
      'aquery',
      'mnemonic("DartEntryKernel|DartModule", deps(//:widget_test))',
      '${_sdkFlag}local',
      '--output=text',
    ]);
    final dills = RegExp(
      r'[\w+./-]*platform_strong\.dill',
    ).allMatches('${aquery.stdout}').map((m) => m.group(0)!).toSet();
    expect(dills, isNotEmpty);
    expect(dills, everyElement(contains(_localEngineRepo)));
  });

  test('the checkout\'s packages are linked, never written into', () async {
    // integration_test has Android plugin code, so its repository writes an
    // `android/BUILD.bazel`: into a directory of its own, not through a link
    // into the checkout, which would leave a Bazel package in the user's tree.
    final load = await _bazel([
      'build',
      '--nobuild',
      _app.label(':web_render_test'),
      '${_sdkFlag}local',
    ]);
    expect(load.exitCode, 0, reason: '${load.stderr}');
    final base = await _bazel(['info', 'output_base']);
    final external = p.join((base.stdout as String).trim(), 'external');
    final spoke = Directory(external)
        .listSync()
        .whereType<Directory>()
        .singleWhere((d) => d.path.endsWith('-local__integration_test'));
    final android = p.join(spoke.path, 'android');
    expect(
      FileSystemEntity.isLinkSync(android),
      isFalse,
      reason: '$android links into the checkout',
    );
    expect(File(p.join(android, 'BUILD.bazel')).existsSync(), isTrue);
  });

  // The local SDK, then the release one.
  test('a flutter_test is told which SDK it runs under', () async {
    Future<String> defines(String sdk) async {
      final aquery = await _bazel([
        'aquery',
        'mnemonic("DartEntryKernel", deps(//:widget_test))',
        '$_sdkFlag$sdk',
        '--output=text',
      ]);
      expect(aquery.exitCode, 0, reason: '${aquery.stderr}');
      return RegExp(
        r'FLUTTER_[A-Z_]+=[^ ,\x27"]*',
      ).allMatches('${aquery.stdout}').map((m) => m.group(0)).toSet().join(' ');
    }

    expect(await defines('local'), contains(await _standInRevisionDefine()));
    expect(
      await defines('flutter'),
      isNot(matches(RegExp(r'FLUTTER_FRAMEWORK_REVISION=( |$)'))),
    );
  });

  // The release SDK (the default), then -c dbg and the Linux platform with it.
  test('the Windows and Linux arm64 engines are the checkout\'s too', () async {
    final build = await _bazel([
      'build',
      '$_localEngine//windows-x64/debug:engine',
      '$_localEngine//windows-x64/release:engine',
      '$_localEngine//linux-arm64/release:engine',
    ]);
    expect(build.exitCode, 0, reason: '${build.stderr}');
  });

  test(
    'a desktop gen_snapshot is the machine\'s own, and says so',
    skip: Platform.isMacOS ? null : 'a Mac cannot run the Linux one',
    () async {
      final build = await _bazel([
        'build',
        '$_localEngine//linux-x64/release:gen_snapshot_linux-x64',
      ]);
      expect(build.exitCode, isNot(0));
      expect(
        '${build.stderr}',
        contains(
          'runs on a linux-x64 machine, and the engine out dirs are read on',
        ),
      );
    },
  );

  test('the release SDK records nothing', () async {
    // The default options first, then each other set once.
    if (Platform.isMacOS) {
      expect(await _record('flutter', const []), isNull);
      expect(
        await _record('flutter', const [], target: _app.label(':android_app')),
        isNull,
      );
    }
    expect(
      await _record('flutter', const [], target: _app.label(':web_app')),
      isNull,
    );
    if (Platform.isMacOS) {
      expect(
        await _record('flutter', const [
          '-c',
          'dbg',
        ], target: _app.label(':ios_simulator')),
        isNull,
      );
    }
    expect(
      await _record(
        'flutter',
        const [_linuxPlatform, '-c', 'dbg'],
        target: _app.label(':linux_app'),
      ),
      isNull,
    );
  });

  // The Linux platform, -c dbg.
  test('the Linux bundle is built from the Linux out dir', () async {
    // Cross-built from a Mac (`linux_debug`), or built on a Linux machine from
    // its own host build.
    final record = (await _record(
      'local',
      const [_linuxPlatform, '-c', 'dbg'],
      target: _app.label(':linux_app'),
    ))!;
    _expectRecordOfTheCheckout(record);
    expect(
      _outDirs(record),
      containsAll([
        if (Platform.isLinux)
          'host_debug'
        else ...[
          'linux_debug',
          'host_debug_arm64',
        ],
      ]),
    );
    expect(
      (record['engine'] as Map).keys,
      contains(endsWith('//linux-x64/debug:engine')),
    );
  });

  // -c dbg.
  appRecordsTheCheckout('debug', const ['-c', 'dbg']);

  test('the dev tool is told the version and engine the program is', () async {
    // What DevTools shows (`flutterVersion` and `engineRevision` of the dev
    // config) and what the program's `FLUTTER_*` defines say are the
    // checkout's.
    for (final json in await _devConfigs(['${_sdkFlag}local', '-c', 'dbg'])) {
      expect(json['flutterVersion'], isNotEmpty);
      expect(
        json['dartDefines'],
        contains('FLUTTER_VERSION=${json['flutterVersion']}'),
      );
      // The full engine revision is the checkout's engine's commit, of which
      // `FLUTTER_ENGINE_REVISION` is the short form.
      final engineRevision = json['engineRevision'] as String;
      expect(engineRevision, matches(RegExp(r'^[0-9a-f]{40}$')));
      expect(
        json['dartDefines'],
        contains('FLUTTER_ENGINE_REVISION=${engineRevision.substring(0, 10)}'),
      );
    }
  });

  test(
    'the iOS simulator app records the simulator out dir',
    skip: _appleOnly,
    () async {
      final record = (await _record(
        'local',
        const ['-c', 'dbg'],
        target: _app.label(':ios_simulator'),
      ))!;
      _expectRecordOfTheCheckout(record);
      expect(
        _outDirs(record),
        containsAll(['ios_debug_sim_arm64', 'host_debug_arm64']),
      );
    },
  );

  test(
    'the debug APK is built from the debug out dir',
    skip: _appleOnly,
    () async {
      final record = (await _record(
        'local',
        const ['-c', 'dbg'],
        target: _app.label(':android_app'),
      ))!;
      _expectRecordOfTheCheckout(record);
      expect(_outDirs(record), contains('android_debug_arm64'));
    },
  );

  // The iOS device platform.
  test(
    'the iOS device framework records the release out dir',
    skip: _appleOnly,
    () async {
      final record = (await _record(
        'local',
        const [_iosDevice],
        target: _app.label(':ios_device_framework'),
      ))!;
      _expectRecordOfTheCheckout(record);
      expect(
        _outDirs(record),
        containsAll(['ios_release', 'host_release_arm64']),
      );
    },
  );

  // One Android ABI other than .bazelrc's, then all three.
  apkRecordsOutDir('x86_64', 'x64');

  apkRecordsOutDir('armeabi-v7a', '');

  test(
    'an APK for every ABI carries the engine of each',
    skip: _appleOnly,
    () async {
      const flags = [_allAbis];
      final build = await _bazel([
        'build',
        _app.label(':android_app'),
        '${_sdkFlag}local',
        ...flags,
      ]);
      expect(build.exitCode, 0, reason: '${build.stderr}');
      final files = await _bazel([
        'cquery',
        _app.label(':android_app'),
        '${_sdkFlag}local',
        ...flags,
        '--output=files',
      ]);
      final apk = (files.stdout as String)
          .split('\n')
          .firstWhere((l) => RegExp(r'(?<!_unsigned)\.apk$').hasMatch(l));
      final listing = await Process.run('unzip', [
        '-Z1',
        p.join(_app.root, apk),
      ]);
      final entries = '${listing.stdout}'.split('\n');
      for (final abi in ['armeabi-v7a', 'arm64-v8a', 'x86_64']) {
        expect(entries, contains('lib/$abi/libflutter.so'));
        expect(entries, contains('lib/$abi/libapp.so'));
      }
    },
  );

  // The mismatched SDK.
  test('a web SDK of another Dart is refused, naming both', () async {
    final build = await _bazel([
      'build',
      _app.label(':web_app'),
      '${_sdkFlag}mismatched',
      '--keep_going',
    ]);
    expect(build.exitCode, isNot(0));
    final err = '${build.stderr}';
    expect(err, contains('does not match itself for web'));
    expect(err, contains('dart2js_platform.dill'));
    expect(err, contains('kernel format 139'));
    expect(err, contains('kernel format 141'));
  });

  test('a gen_snapshot of another Dart is refused', () async {
    // The check and the AOT compile both fail: keep going, so the check's
    // message is not lost to whichever fails first.
    final build = await _bazel([
      'build',
      Platform.isMacOS ? _app.label(':app') : _app.label(':linux_app'),
      '${_sdkFlag}mismatched',
      '--keep_going',
    ]);
    expect(build.exitCode, isNot(0));
    final err = '${build.stderr}';
    expect(err, contains('does not match itself for release'));
    expect(err, contains('gen_snapshot'));
    expect(err, contains('snapshot hash $_snapshotHash'));
  });

  for (final target in [
    [_app.label(':ios_device_framework'), 'iOS device framework'],
    [_app.label(':android_app'), 'Android APK'],
  ]) {
    test(
      'a gen_snapshot of another Dart is refused for the ${target[1]}',
      skip: _appleOnly,
      () async {
        final build = await _bazel([
          'build',
          target[0],
          '${_sdkFlag}mismatched',
          '--keep_going',
        ]);
        expect(build.exitCode, isNot(0));
        final err = '${build.stderr}';
        expect(err, contains('does not match itself for release'));
        expect(err, contains('gen_snapshot'));
        expect(err, contains('snapshot hash $_snapshotHash'));
      },
    );
  }

  // The SDK the environment names.
  test(
    'an unset checkout loads, and a build that selects it says what to set',
    () async {
      final app = Platform.isMacOS
          ? _app.label(':app')
          : _app.label(':linux_app');
      final query = await _bazel([
        'query',
        'deps($app)',
        '--output=label_kind',
      ]);
      expect(query.exitCode, 0, reason: '${query.stderr}');
      // Both are unset, and which target Bazel analyses first is not fixed:
      // with --keep_going the build names each.
      final build = await _bazel([
        'build',
        app,
        '${_sdkFlag}env',
        '--keep_going',
      ]);
      expect(build.exitCode, isNot(0));
      expect('${build.stderr}', contains('FLUTTER_ENGINE is not set'));
      expect('${build.stderr}', contains('FLUTTER_CHECKOUT is not set'));
    },
  );

  test(
    'an unset flutter.checkout loads, and a build that selects it says what to set',
    () async {
      final app = Platform.isMacOS
          ? _app.label(':app')
          : _app.label(':linux_app');
      final query = await _bazel([
        'query',
        'deps($app)',
        '${_sdkFlag}env_checkout',
        '--output=label_kind',
      ]);
      expect(query.exitCode, 0, reason: '${query.stderr}');
      final build = await _bazel([
        'build',
        app,
        '${_sdkFlag}env_checkout',
        '--keep_going',
      ]);
      expect(build.exitCode, isNot(0));
      // One variable gives both halves: the engine is the checkout's own.
      expect('${build.stderr}', contains('FLUTTER_CHECKOUT is not set'));
      expect('${build.stderr}', isNot(contains('FLUTTER_ENGINE')));
    },
  );

  test(
    'flutter.checkout pairs the framework with the engine built in it',
    () async {
      // FLUTTER_ENGINE names no engine: the checkout's SDK never reads it.
      final checkout = await _fakeCheckoutDir('checkout/CHECKOUT');
      final flags = [
        '${_sdkFlag}env_checkout',
        '-c',
        'dbg',
        '--repo_env=FLUTTER_CHECKOUT=$checkout',
        '--repo_env=FLUTTER_ENGINE=/nonexistent',
      ];
      final version = jsonDecode(
        File(
          p.join(checkout, 'bin', 'cache', 'flutter.version.json'),
        ).readAsStringSync(),
      ) as Map<String, Object?>;
      final argsGn = File(
        p.join(checkout, 'engine', 'src', 'out', _host('debug'), 'args.gn'),
      ).readAsStringSync();
      final engineVersion = RegExp(
        r'engine_version = "([0-9a-f]+)"',
      ).firstMatch(argsGn)!.group(1)!;
      for (final json in await _devConfigs(flags)) {
        expect(json['flutterVersion'], version['flutterVersion']);
        expect(json['engineRevision'], engineVersion);
        expect(
          json['dartDefines'],
          allOf(
            contains('FLUTTER_VERSION=${version['flutterVersion']}'),
            contains(
              'FLUTTER_ENGINE_REVISION=${engineVersion.substring(0, 10)}',
            ),
          ),
        );
      }

      // The program compiles against the platform kernel of that engine. Only
      // paths: the compile also names the file alone.
      final aquery = await _bazel([
        'aquery',
        'mnemonic(".*Kernel.*", //:app_flutter)',
        ...flags,
        '--output=text',
      ]);
      expect(aquery.exitCode, 0, reason: '${aquery.stderr}');
      final dills = RegExp(
        r'[\w+./-]*/platform_strong\.dill',
      ).allMatches('${aquery.stdout}').map((m) => m.group(0)!).toSet();
      expect(dills, isNotEmpty);
      expect(dills, everyElement(contains('env_checkout_checkout_engine')));
    },
  );

  test('a framework over the release engine brings its own fonts', () async {
    final toolchain = await _bazel([
      'query',
      '@@rules_flutter++flutter+framework_only_sdk//:darwin-arm64_toolchain',
      '--output=build',
    ]);
    expect(toolchain.exitCode, 0, reason: '${toolchain.stderr}');
    expect(
      '${toolchain.stdout}',
      contains(
        'material_icons_font = "@@rules_flutter++flutter+framework_only_material_fonts//',
      ),
    );
    final fonts = await _bazel([
      'build',
      '@@rules_flutter++flutter+framework_only_material_fonts//:all',
    ]);
    expect(fonts.exitCode, 0, reason: '${fonts.stderr}');
  });

  // --@rules_flutter//flutter:sdk=engine_only.
  test(
    'a release\'s framework over the checkout\'s engine records both',
    skip: _appleOnly,
    () async {
      final record = (await _record('engine_only', const []))!;
      expect(record['sdk'], 'engine_only');
      expect(record['framework'], {'origin': 'release', 'version': '3.50.0'});
      expect(record['snapshot_hash'], _snapshotHash);
      expect(_outDirs(record), contains('host_release_arm64'));
      expect(
        (record['engine'] as Map).keys,
        everyElement(contains('stand_in_engine')),
      );
    },
  );

  test('a release\'s framework over another engine resolves against the '
      'release\'s packages', () async {
    // What `@rules_flutter//flutter/pub` gives pub as FLUTTER_ROOT under
    // this SDK: the release's tree, at its version.
    const devRoot = '@@rules_flutter++flutter+engine_only_dev_root_src';
    final build = await _bazel(['build', '$devRoot//:dev_root']);
    expect(build.exitCode, 0, reason: '${build.stderr}');
    final location = await _bazel([
      'query',
      '$devRoot//:bin/cache/flutter.version.json',
      '--output=location',
    ]);
    expect(location.exitCode, 0, reason: '${location.stderr}');
    final manifest = File(
      '${location.stdout}'.trim().replaceFirst(RegExp(r':\d+:\d+:.*$'), ''),
    );
    expect(
      jsonDecode(manifest.readAsStringSync()),
      allOf(
        containsPair('flutterVersion', '3.50.0'),
        containsPair('frameworkVersion', '3.50.0'),
      ),
    );
    final root = manifest.parent.parent.parent.path;
    expect(
      File(p.join(root, 'packages', 'flutter', 'pubspec.yaml')).existsSync(),
      isTrue,
    );

    // The engine's `sky_engine`, as flutter_tools takes it for an engine
    // that is not the release's, and as the analyzer and NOTICES read it.
    final engine = await _bazel([
      'query',
      '@stand_in_engine//sky_engine:pubspec.yaml',
      '--output=location',
    ]);
    expect(engine.exitCode, 0, reason: '${engine.stderr}');
    expect(
      File(
        p.join(root, 'bin', 'cache', 'pkg', 'sky_engine', 'pubspec.yaml'),
      ).resolveSymbolicLinksSync(),
      File(
        '${engine.stdout}'.trim().replaceFirst(RegExp(r':\d+:\d+:.*$'), ''),
      ).resolveSymbolicLinksSync(),
    );
  });

  test('FLUTTER_LOCAL_ENGINES chooses only for the slots it fits', () async {
    final engineSrc = await _fakeCheckoutDir(
      'checkout/engine/src/ENGINE_SRC',
    );
    const slot = '@env_engine//kernel/release:platform';
    List<String> env(String pins) => [
      '--repo_env=FLUTTER_ENGINE=$engineSrc',
      '--repo_env=FLUTTER_LOCAL_ENGINES=$pins',
    ];
    Future<ProcessResult> kind(String pins) =>
        _bazel(['query', slot, '--output=label_kind', ...env(pins)]);

    // A pin of the debug slot leaves the release slot its one out dir.
    final pinned = await kind(_host('debug'));
    expect(pinned.exitCode, 0, reason: '${pinned.stderr}');
    expect('${pinned.stdout}', startsWith('flutter_platform_kernel rule'));

    // A pin of no out dir still fetches, so that a build not using the engine
    // is unaffected; a build of its slot fails, naming the pin.
    const nonesuch = 'host_debug_nonesuch';
    final fetched = await kind(nonesuch);
    expect(fetched.exitCode, 0, reason: '${fetched.stderr}');
    final unknown = await _bazel([
      'build',
      '--nobuild',
      slot,
      ...env(nonesuch),
    ]);
    expect(unknown.exitCode, isNot(0));
    expect(
      '${unknown.stderr}',
      contains(
        'FLUTTER_LOCAL_ENGINES=host_debug_nonesuch names host_debug_nonesuch, '
        'which is no out dir',
      ),
    );
  });

  test(
    'the analyzer and NOTICES read the selected SDK\'s sky_engine',
    () async {
      // The `sky_engine` package's `lib/_embedder.yaml` is how the analyzer
      // resolves `dart:ui`, and its `LICENSE` the engine's licences.
      const face = '@@rules_flutter++flutter+flutter_sky_engine';
      expect(
        await _fileOf('$face//:LICENSE', 'local'),
        contains('$_localEngineRepo/sky_engine/LICENSE'),
      );
      expect(
        await _fileOf('$face//:LICENSE', 'flutter'),
        contains('flutter_stock_sky_engine/sky_engine/LICENSE'),
      );
      for (final (sdk, repo) in [
        ('local', _localEngineRepo),
        ('flutter', 'flutter_stock_engine'),
      ]) {
        final package = await _bazel([
          'cquery',
          'deps($face//:sky_engine, 1)',
          '$_sdkFlag$sdk',
          '--output=label',
        ]);
        expect(package.exitCode, 0, reason: '${package.stderr}');
        expect('${package.stdout}', contains('$repo//sky_engine:sky_engine'));
      }
    },
  );

  test(
    'the Android Maven data and the Apple app settings read the selected '
    'SDK\'s packages and no other SDK\'s',
    () async {
      // Each repository, and how it names the checkout's `integration_test`
      // where the release's would be `flutter_pub__integration_test` (which
      // comes from the release's source tarball).
      for (final (face, target, repo, local) in [
        (
          'flutter_pub_android_maven',
          'requirements',
          'android_maven_requirements',
          'flutter_pub-local__integration_test//',
        ),
        (
          'flutter_pub_apple_app_settings',
          'libraries',
          'apple_app_libraries',
          '"integration_test": "flutter_pub-local"',
        ),
      ]) {
        const prefix = '@@rules_flutter++pub+';
        final selected = '${prefix}flutter_pub-local_$repo';
        final deps = await _bazel([
          'cquery',
          'deps($prefix$face//:$target, 1)',
          '${_sdkFlag}local',
          '--output=label',
        ]);
        expect(deps.exitCode, 0, reason: '${deps.stderr}');
        expect('${deps.stdout}', contains('$selected//:$target'));

        final shown = await _bazel(['mod', 'show_repo', selected]);
        expect(shown.exitCode, 0, reason: '${shown.stderr}');
        expect('${shown.stdout}', contains(local));
        expect(
          '${shown.stdout}',
          isNot(contains('flutter_pub__integration_test')),
        );
        expect(
          '${shown.stdout}',
          isNot(contains('"integration_test": "flutter_pub"')),
        );
      }
    },
  );

  test(
    'every repository that reads an SDK\'s sources fetches, with the '
    'checkouts unset or their engine unbuilt',
    () async {
      final repos = await _sourceReadingRepos();
      expect(
        repos,
        contains('rules_flutter++flutter+env_checkout_dev_root_src'),
      );
      expect(repos, contains('rules_flutter++pub+flutter_pub_android_maven'));
      final fetchAll = ['fetch', for (final repo in repos) '--repo=@@$repo'];

      final unset = await _bazel(fetchAll);
      expect(unset.exitCode, 0, reason: '${unset.stderr}');

      final checkout = await _unbuiltCheckout();
      final unbuilt = await _bazel([
        ...fetchAll,
        '--repo_env=FLUTTER_CHECKOUT=$checkout',
        '--repo_env=FLUTTER_ENGINE=$checkout/engine/src',
      ]);
      expect(unbuilt.exitCode, 0, reason: '${unbuilt.stderr}');

      // The version flutter_tools tells, one commit past the tag, and the
      // checkout's branch.
      final framework = await _envCheckoutFramework(checkout);
      expect(framework['version'], '3.50.1-0.0.pre-1');
      expect(framework['channel'], 'main');
      expect(framework['repository_url'], isNull);
    },
  );

  test(
    'a checkout that is a git worktree is read again when its HEAD moves',
    () async {
      // A worktree's HEAD is in its own git directory, and its branches and
      // tags in the repository's, neither of which is its `.git`, a file.
      final repository = await _unbuiltCheckout();
      final worktree = p.join(
        Directory.systemTemp.createTempSync('worktree').path,
        'checkout',
      );
      addTearDown(() => Directory(worktree).parent.deleteSync(recursive: true));
      await _git(repository, [
        'worktree',
        'add',
        '--quiet',
        worktree,
        '3.50.0',
      ]);
      expect(File(p.join(worktree, '.git')).existsSync(), isTrue);

      expect((await _envCheckoutFramework(worktree))['version'], '3.50.0');
      await _git(worktree, ['checkout', '--quiet', '--detach', 'main']);
      expect(
        (await _envCheckoutFramework(worktree))['version'],
        '3.50.1-0.0.pre-1',
      );
      await _git(repository, ['tag', '3.50.1', 'main']);
      expect((await _envCheckoutFramework(worktree))['version'], '3.50.1');
    },
  );

  for (final sdk in ['local', 'engine_only']) {
    test(
      'the $sdk SDK builds on the machine though another OS is an '
      'execution platform first',
      () async {
        // The out dirs hold this machine's host tools alone: no toolchain of
        // the SDK may claim the other platform, which Bazel tries first. A
        // checkout's are the machine's; `hosts` says so for `engine_only`.
        final other = Platform.isMacOS ? 'linux_x64' : 'macos_arm64';
        final build = await _bazel([
          'build',
          '--nobuild',
          Platform.isMacOS
              ? _app.label(':app_flutter')
              : _app.label(':linux_app'),
          '$_sdkFlag$sdk',
          '--extra_execution_platforms=@rules_flutter//flutter/platforms:$other',
        ]);
        expect(build.exitCode, 0, reason: '${build.stderr}');
      },
    );
  }
}
