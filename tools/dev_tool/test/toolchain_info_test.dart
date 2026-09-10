import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter_bazel_dev_tool/dev_tool_exception.dart';
import 'package:flutter_bazel_dev_tool/toolchain_info.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('ToolchainPaths', () {
    test('constructor holds all fields', () {
      final paths = ToolchainPaths(
        dart: '/sdk/bin/dart',
        dartaotruntime: '/sdk/bin/dartaotruntime',
        frontendServer: '/tools/frontend_server_aot.dart.snapshot',
        platformDill: '/patched-sdk/platform_strong.dill',
        patchedSdkRoot: '/patched-sdk/flutter_patched_sdk',
      );
      expect(paths.dart, '/sdk/bin/dart');
      expect(paths.dartaotruntime, '/sdk/bin/dartaotruntime');
      expect(paths.frontendServer, '/tools/frontend_server_aot.dart.snapshot');
      expect(paths.platformDill, '/patched-sdk/platform_strong.dill');
      expect(paths.patchedSdkRoot, '/patched-sdk/flutter_patched_sdk');
    });
  });

  group('flutterToolchainRepoNames', () {
    test('is the two module positions rules_flutter can occupy', () {
      // Not a search list. A module extension's repos are named
      // `<canonical repo of the module defining the extension>+<ext>+<repo>`,
      // and rules_flutter's own canonical name is `''` as the root module and
      // `rules_flutter+` as a dependency.
      expect(flutterToolchainRepoNames('darwin-arm64'), [
        'rules_flutter++flutter+flutter_darwin-arm64',
        '+flutter+flutter_darwin-arm64',
      ]);
    });
  });

  group('resolveToolchainPaths', () {
    /// A [BazelRunner] answering from [replies], keyed by the command word.
    /// Records what it was asked, so a test can assert a fetch did *not*
    /// happen.
    ({BazelRunner run, List<List<String>> calls}) fakeBazel(
      Map<String, ProcessResult> replies,
    ) {
      final calls = <List<String>>[];
      return (
        run: (args, {required String workingDirectory}) async {
          calls.add(args);
          final reply = replies[args.first];
          if (reply == null) {
            throw StateError('unexpected `bazel ${args.join(' ')}`');
          }
          return reply;
        },
        calls: calls,
      );
    }

    /// An output base directory holding [repoName] under `external/`.
    String outputBaseWith(String? repoName) {
      final dir = Directory.systemTemp.createTempSync('toolchain_ob_');
      addTearDown(() => dir.deleteSync(recursive: true));
      if (repoName != null) {
        Directory(
          p.join(dir.path, 'external', repoName),
        ).createSync(recursive: true);
      }
      return dir.path;
    }

    ProcessResult ok(String stdout) => ProcessResult(0, 0, stdout, '');

    test('resolves the five paths out of the repo that exists', () async {
      final platform = detectHostPlatform();
      final base = outputBaseWith('rules_flutter++flutter+flutter_$platform');
      final bazel = fakeBazel({'info': ok('$base\n')});

      final paths = await resolveToolchainPaths(
        '//:app',
        workspace: '/ws',
        runBazel: bazel.run,
      );

      final repo = p.join(
        base,
        'external',
        'rules_flutter++flutter+flutter_$platform',
      );
      expect(
        p.split(paths.dartaotruntime),
        p.split(
          p.join(
            repo,
            'dart-sdk',
            'bin',
            Platform.isWindows ? 'dartaotruntime.exe' : 'dartaotruntime',
          ),
        ),
      );
      expect(
        p.split(paths.frontendServer),
        p.split(
          p.join(repo, 'host-tools', 'frontend_server_aot.dart.snapshot'),
        ),
      );
      expect(
        p.split(paths.patchedSdkRoot),
        p.split(p.join(repo, 'patched-sdk', 'flutter_patched_sdk')),
      );
      // The repo was already there, so nothing had to be fetched.
      expect(bazel.calls.map((c) => c.first), ['info']);
    });

    test('finds the toolchain when rules_flutter is the root module', () async {
      // The name `+flutter+flutter_<platform>`: without it, `flutter_bazel
      // run` inside rules_flutter's own workspace cannot resolve a toolchain
      // however warm the output base is.
      final platform = detectHostPlatform();
      final base = outputBaseWith('+flutter+flutter_$platform');
      final bazel = fakeBazel({'info': ok('$base\n')});

      final paths = await resolveToolchainPaths(
        '//:app',
        workspace: '/ws',
        runBazel: bazel.run,
      );
      expect(paths.dart, contains('+flutter+flutter_$platform'));
      expect(bazel.calls.map((c) => c.first), ['info']);
    });

    test('fetches when the output base has never been built', () async {
      // A cold output base — every `editableWorkspace` copy, and every first
      // run in a fresh clone — has no external repo to find. The fetch is the
      // step that creates it, not a retry.
      final platform = detectHostPlatform();
      final base = outputBaseWith(null);
      final repoName = 'rules_flutter++flutter+flutter_$platform';
      final calls = <List<String>>[];
      Future<ProcessResult> run(
        List<String> args, {
        required String workingDirectory,
      }) async {
        calls.add(args);
        if (args.first == 'info') return ok('$base\n');
        // The fetch materializes the repo, as bazel's would.
        Directory(
          p.join(base, 'external', repoName),
        ).createSync(recursive: true);
        return ok('');
      }

      final paths = await resolveToolchainPaths(
        '//:app',
        workspace: '/ws',
        runBazel: run,
      );
      expect(paths.dart, contains(repoName));
      expect(calls.map((c) => c.join(' ')), [
        'info output_base',
        'fetch //:app',
      ]);
    });

    test('reports bazel’s own error when the fetch fails', () async {
      // A workspace that cannot be analysed at all is reported as bazel's own
      // failure, naming it and its remedy, rather than as a missing Flutter
      // toolchain.
      const ndk =
          'ERROR: Analysis of target \'//:plugin_macos\' failed; build '
          'aborted: Either the ANDROID_NDK_HOME environment variable or the '
          'path attribute of android_ndk_repository must be set.';
      final base = outputBaseWith(null);
      final bazel = fakeBazel({
        'info': ok('$base\n'),
        'fetch': ProcessResult(0, 2, '', ndk),
      });

      expect(
        () => resolveToolchainPaths(
          '//:plugin_macos',
          workspace: '/ws',
          runBazel: bazel.run,
        ),
        throwsA(
          isA<DevToolException>()
              .having((e) => e.message, 'message', contains('ANDROID_NDK_HOME'))
              .having(
                (e) => e.message,
                'message',
                contains('bazel fetch //:plugin_macos'),
              )
              .having((e) => e.message, 'message', contains('/ws')),
        ),
      );
    });

    test('separates a fetch that succeeded and left no toolchain', () async {
      // A different fact from the one above, and it has a different remedy:
      // bazel is happy, so the target simply does not resolve a rules_flutter
      // toolchain. Merging the two points the message at the toolchain for
      // failures that have nothing to do with it.
      final base = outputBaseWith(null);
      final bazel = fakeBazel({
        'info': ok('$base\n'),
        'fetch': ok(''),
      });

      expect(
        () => resolveToolchainPaths(
          '//:app',
          workspace: '/ws',
          runBazel: bazel.run,
        ),
        throwsA(
          isA<DevToolException>()
              .having(
                (e) => e.message,
                'message',
                contains('register_toolchains'),
              )
              .having(
                (e) => e.message,
                'message',
                contains('flutter+flutter_${detectHostPlatform()}'),
              ),
        ),
      );
    });

    test('reports a failed `bazel info output_base`', () async {
      final bazel = fakeBazel({
        'info': ProcessResult(0, 36, '', 'ERROR: not a workspace'),
      });
      expect(
        () => resolveToolchainPaths(
          '//:app',
          workspace: '/ws',
          runBazel: bazel.run,
        ),
        throwsA(
          isA<DevToolException>()
              .having((e) => e.message, 'message', contains('not a workspace'))
              .having(
                (e) => e.message,
                'message',
                contains('bazel info output_base'),
              ),
        ),
      );
    });
  });

  group('detectHostPlatform', () {
    test('returns correct platform for current OS', () {
      final platform = detectHostPlatform();
      if (Platform.isMacOS) {
        expect(platform, startsWith('darwin-'));
      } else if (Platform.isLinux) {
        expect(platform, startsWith('linux-'));
      } else if (Platform.isWindows) {
        expect(platform, startsWith('windows-'));
      }
      expect(
        platform,
        matches(RegExp(r'^(darwin|linux|windows)-(arm64|x64)$')),
      );
    });
  });

  group('detectArch', () {
    test('returns arm64 or x64', () {
      final arch = detectArch();
      expect(arch, anyOf('arm64', 'x64'));
    });

    test('is consistent with dart:ffi Abi', () {
      final arch = detectArch();
      // On arm64 hosts, Abi.current() returns an arm64 variant.
      final isArm64Host =
          Abi.current() == Abi.macosArm64 ||
          Abi.current() == Abi.linuxArm64 ||
          Abi.current() == Abi.windowsArm64;
      expect(arch, isArm64Host ? 'arm64' : 'x64');
    });
  });

  group('DevConfig', () {
    test('fromJson parses all fields', () {
      final config = DevConfig.fromJson({
        'engineRevision': 'abc123',
        'flutterVersion': '3.41.2',
        'dartSdkRoot': '/ext/dart-sdk',
        'dartaotruntime': '/ext/dart-sdk/bin/dartaotruntime',
        'frontendServer': '/ext/host-tools/frontend_server_aot.dart.snapshot',
        'patchedSdkRoot': '/ext/patched-sdk/flutter_patched_sdk',
        'appEntrypoint': 'package:my_app/main.dart',
      });
      expect(config.engineRevision, 'abc123');
      expect(config.flutterVersion, '3.41.2');
      expect(config.dartSdkRoot, '/ext/dart-sdk');
      expect(config.dartaotruntime, '/ext/dart-sdk/bin/dartaotruntime');
      expect(
        config.frontendServer,
        '/ext/host-tools/frontend_server_aot.dart.snapshot',
      );
      expect(config.patchedSdkRoot, '/ext/patched-sdk/flutter_patched_sdk');
      expect(config.appEntrypoint, 'package:my_app/main.dart');
    });

    test('fromJson parses dartDefines', () {
      final config = DevConfig.fromJson({
        'engineRevision': 'abc123',
        'flutterVersion': '3.41.2',
        'dartSdkRoot': '/ext/dart-sdk',
        'dartaotruntime': '/ext/dart-sdk/bin/dartaotruntime',
        'frontendServer': '/ext/host-tools/frontend_server_aot.dart.snapshot',
        'patchedSdkRoot': '/ext/patched-sdk/flutter_patched_sdk',
        'appEntrypoint': 'package:my_app/main.dart',
        'dartDefines': ['A=1', 'B=x,y'],
      });
      expect(config.dartDefines, ['A=1', 'B=x,y']);
    });

    test('fromJson parses dartPluginRegistrants, defaults empty', () {
      Map<String, dynamic> base() => {
        'engineRevision': 'abc123',
        'flutterVersion': '3.41.2',
        'dartSdkRoot': '/ext/dart-sdk',
        'dartaotruntime': '/ext/dart-sdk/bin/dartaotruntime',
        'frontendServer': '/ext/host-tools/fs.snapshot',
        'patchedSdkRoot': '/ext/patched-sdk/flutter_patched_sdk',
        'appEntrypoint': 'package:my_app/main.dart',
      };
      expect(DevConfig.fromJson(base()).dartPluginRegistrants, isEmpty);
      expect(
        DevConfig.fromJson({
          ...base(),
          'dartPluginRegistrants': {
            'ios': 'bazel-out/cfg/bin/app.dev_plugin_registrant.ios.dart',
            'macos': 'bazel-out/cfg/bin/app.dev_plugin_registrant.macos.dart',
          },
        }).dartPluginRegistrants,
        {
          'ios': 'bazel-out/cfg/bin/app.dev_plugin_registrant.ios.dart',
          'macos': 'bazel-out/cfg/bin/app.dev_plugin_registrant.macos.dart',
        },
      );
    });

    test('registrantFor answers with the launch platform’s registrant', () {
      // The dev build runs in the HOST configuration, but the launch platform
      // can differ (an iOS run on a macOS host). The map is keyed by platform
      // so the dev tool feeds its frontend_server the registrant filtered for
      // the platform the app is actually running on — not the host's.
      final config = DevConfig(
        engineRevision: 'abc',
        flutterVersion: '3.41.2',
        dartSdkRoot: '/sdk',
        dartaotruntime: '/bin/dartaotruntime',
        frontendServer: '/tools/fs.snapshot',
        patchedSdkRoot: '/patched',
        appEntrypoint: 'package:my_app/main.dart',
        dartPluginRegistrants: const {
          'ios': '/exec/bin/app.dev_plugin_registrant.ios.dart',
          'macos': '/exec/bin/app.dev_plugin_registrant.macos.dart',
        },
      );
      expect(
        config.registrantFor('ios'),
        '/exec/bin/app.dev_plugin_registrant.ios.dart',
      );
    });

    test('registrantFor fails by name on a platform the config lacks', () {
      // A missing key is rules/dev-tool version skew (or an unknown platform
      // string), not "no registrant" — guessing here is how the wrong plugin
      // set gets registered silently.
      final config = DevConfig(
        engineRevision: 'abc',
        flutterVersion: '3.41.2',
        dartSdkRoot: '/sdk',
        dartaotruntime: '/bin/dartaotruntime',
        frontendServer: '/tools/fs.snapshot',
        patchedSdkRoot: '/patched',
        appEntrypoint: 'package:my_app/main.dart',
        dartPluginRegistrants: const {'macos': '/exec/bin/r.macos.dart'},
      );
      expect(
        () => config.registrantFor('ios'),
        throwsA(
          isA<DevToolException>().having(
            (e) => e.message,
            'message',
            contains('ios'),
          ),
        ),
      );
    });

    test('registrantFor passes an empty entry through', () {
      // An empty value is an explicit statement: this platform has no Dart
      // plugins and no agent to register. Distinct from a missing key.
      final config = DevConfig(
        engineRevision: 'abc',
        flutterVersion: '3.41.2',
        dartSdkRoot: '/sdk',
        dartaotruntime: '/bin/dartaotruntime',
        frontendServer: '/tools/fs.snapshot',
        patchedSdkRoot: '/patched',
        appEntrypoint: 'package:my_app/main.dart',
        dartPluginRegistrants: const {'ios': ''},
      );
      expect(config.registrantFor('ios'), isEmpty);
    });

    test('fromJson defaults dartDefines to empty when absent', () {
      final config = DevConfig.fromJson({
        'engineRevision': 'abc123',
        'flutterVersion': '3.41.2',
        'dartSdkRoot': '/ext/dart-sdk',
        'dartaotruntime': '/ext/dart-sdk/bin/dartaotruntime',
        'frontendServer': '/ext/host-tools/frontend_server_aot.dart.snapshot',
        'patchedSdkRoot': '/ext/patched-sdk/flutter_patched_sdk',
        'appEntrypoint': 'package:my_app/main.dart',
      });
      expect(config.dartDefines, isEmpty);
    });

    test('fromJson parses enableExperiments, defaults empty', () {
      // Raw experiment names, no `--enable-experiment=` prefix — the same
      // shape the build emits for dartDefines. The compiler config is what
      // adds the flag spelling.
      Map<String, dynamic> base() => {
        'engineRevision': 'abc123',
        'flutterVersion': '3.41.2',
        'dartSdkRoot': '/ext/dart-sdk',
        'dartaotruntime': '/ext/dart-sdk/bin/dartaotruntime',
        'frontendServer': '/ext/host-tools/fs.snapshot',
        'patchedSdkRoot': '/ext/patched-sdk/flutter_patched_sdk',
        'appEntrypoint': 'package:my_app/main.dart',
      };
      expect(DevConfig.fromJson(base()).enableExperiments, isEmpty);
      expect(
        DevConfig.fromJson({
          ...base(),
          'enableExperiments': ['records', 'macros'],
        }).enableExperiments,
        ['records', 'macros'],
      );
    });

    test('fromJson parses nativeNullAssertions, defaults true', () {
      // The build's attr default is true, so an absent key means true. A
      // build that turned it off has to reach the dev loop's bootstrap, or
      // the app runs with assertions the build said not to emit.
      Map<String, dynamic> base() => {
        'engineRevision': 'abc123',
        'flutterVersion': '3.41.2',
        'dartSdkRoot': '/ext/dart-sdk',
        'dartaotruntime': '/ext/dart-sdk/bin/dartaotruntime',
        'frontendServer': '/ext/host-tools/fs.snapshot',
        'patchedSdkRoot': '/ext/patched-sdk/flutter_patched_sdk',
        'appEntrypoint': 'package:my_app/main.dart',
      };
      expect(DevConfig.fromJson(base()).nativeNullAssertions, isTrue);
      expect(
        DevConfig.fromJson({
          ...base(),
          'nativeNullAssertions': false,
        }).nativeNullAssertions,
        isFalse,
      );
      expect(
        DevConfig.fromJson({
          ...base(),
          'nativeNullAssertions': true,
        }).nativeNullAssertions,
        isTrue,
      );
    });
  });

  group('findDevConfig', () {
    test('finds _dev_config.json in output files', () {
      final result = findDevConfig([
        '/bazel-out/k8-dbg/bin/hello_world_web',
        '/bazel-out/k8-dbg/bin/hello_world_dev_config.json',
        '/bazel-out/k8-dbg/bin/hello_world_ddc_dart_sdk.js',
      ]);
      expect(result, '/bazel-out/k8-dbg/bin/hello_world_dev_config.json');
    });

    test('returns null when no _dev_config.json present', () {
      final result = findDevConfig([
        '/bazel-out/k8-opt/bin/hello_world_web',
      ]);
      expect(result, isNull);
    });

    test(
      'skips a dangling candidate and picks the one that resolves on disk',
      () {
        // A cross-platform app's `flutter_application` dev config is listed by
        // cquery in BOTH the platform-transitioned config and the default host
        // config, but only the host one is built (the transitioned path is a
        // dangling symlink). findDevConfig must skip the dangling path and return
        // the resolvable one — otherwise iOS/Android hot reload fails with
        // "Cannot resolve symbolic links" at frontend-server startup.
        final tmpDir = Directory.systemTemp.createTempSync('find_dev_config_');
        addTearDown(() => tmpDir.deleteSync(recursive: true));
        final real = File('${tmpDir.path}/app_dev_config.json')
          ..writeAsStringSync('{}');
        final dangling =
            '${tmpDir.path}/ios_sim-ST-deadbeef/app_dev_config.json';

        // Dangling candidate listed FIRST, as cquery often orders it.
        final result = findDevConfig([dangling, real.path]);
        expect(result, real.path);
      },
    );

    test('falls back to the first candidate when none resolve', () {
      // Preserves behavior for pure in-memory path lists (no disk): callers
      // still get a path to surface a clear downstream error.
      final result = findDevConfig([
        '/bazel-out/ios_sim-ST-x/bin/a_dev_config.json',
        '/bazel-out/darwin_arm64-dbg/bin/a_dev_config.json',
      ]);
      expect(result, '/bazel-out/ios_sim-ST-x/bin/a_dev_config.json');
    });
  });

  group('parseDevConfig', () {
    test('reads and parses a JSON file with absolute paths', () {
      final tmpDir = Directory.systemTemp.createTempSync('test_dev_config_');
      final configFile = File('${tmpDir.path}/test_dev_config.json');
      configFile.writeAsStringSync(
        jsonEncode({
          'engineRevision': 'rev123',
          'flutterVersion': '3.41.2',
          'dartSdkRoot': '/sdk',
          'dartaotruntime': '/bin/dartaotruntime',
          'frontendServer': '/tools/fs.snapshot',
          'patchedSdkRoot': '/patched',
          'appEntrypoint': 'package:my_app/main.dart',
        }),
      );

      final config = parseDevConfig(configFile.path);
      expect(config.engineRevision, 'rev123');
      expect(config.dartSdkRoot, '/sdk');
      // Absolute paths remain unchanged.
      expect(config.dartaotruntime, '/bin/dartaotruntime');
      // appEntrypoint is not a filesystem path — left as-is.
      expect(config.appEntrypoint, 'package:my_app/main.dart');

      tmpDir.deleteSync(recursive: true);
    });

    test('resolves relative paths using execution root from file location', () {
      // Simulate a Bazel output tree: .../execroot/_main/bazel-out/cfg/bin/
      final tmpDir = Directory.systemTemp.createTempSync('test_exec_root_');
      // Resolve tmpDir to handle /var → /private/var on macOS.
      final resolvedTmpDir = tmpDir.resolveSymbolicLinksSync();
      final execRoot = '$resolvedTmpDir/execroot/_main';
      final binDir = Directory('$execRoot/bazel-out/cfg/bin');
      binDir.createSync(recursive: true);

      // Create the external tool so resolveSymbolicLinksSync succeeds.
      final extDir = Directory('$execRoot/external/flutter/dart-sdk/bin');
      extDir.createSync(recursive: true);
      File('${extDir.path}/dartaotruntime').writeAsStringSync('');

      final configFile = File('${binDir.path}/app_dev_config.json');
      configFile.writeAsStringSync(
        jsonEncode({
          'engineRevision': 'abc',
          'flutterVersion': '3.41.2',
          'dartSdkRoot': 'external/flutter/dart-sdk',
          'dartaotruntime': 'external/flutter/dart-sdk/bin/dartaotruntime',
          'frontendServer': 'external/flutter/fs.snapshot',
          'patchedSdkRoot': 'external/flutter/patched',
          'appEntrypoint': 'package:my_app/main.dart',
          'flutterBootstrapJs':
              'bazel-out/cfg/bin/app_dev_flutter_bootstrap.js',
        }),
      );

      final config = parseDevConfig(configFile.path);
      // The bootstrap the dev server serves is a path like any other, and the
      // server opens it directly — a relative one would be opened against
      // whatever the tool's cwd happened to be.
      expect(
        p.split(config.flutterBootstrapJs),
        p.split('$execRoot/bazel-out/cfg/bin/app_dev_flutter_bootstrap.js'),
      );
      // Relative paths should be resolved to absolute using the exec root.
      // Compare on path components so the assertion is independent of the host
      // OS separator (Windows resolves to '\', the literals here use '/').
      expect(
        p.split(config.dartSdkRoot),
        p.split('$execRoot/external/flutter/dart-sdk'),
      );
      expect(
        p.split(config.dartaotruntime),
        p.split('$execRoot/external/flutter/dart-sdk/bin/dartaotruntime'),
      );
      expect(
        p.split(config.frontendServer),
        p.split('$execRoot/external/flutter/fs.snapshot'),
      );
      expect(
        p.split(config.patchedSdkRoot),
        p.split('$execRoot/external/flutter/patched'),
      );

      tmpDir.deleteSync(recursive: true);
    });

    test('absolutizes dartPluginRegistrants against the exec root', () {
      // Unlike dartDefines, the registrants ARE paths — the dev tool turns
      // the chosen one into a file:// URI for the frontend_server
      // --source/-D trio. Empty entries (a platform with no registrant)
      // stay empty rather than becoming a path to the exec root.
      final tmpDir = Directory.systemTemp.createTempSync('test_dev_cfg_reg_');
      final resolvedTmpDir = tmpDir.resolveSymbolicLinksSync();
      final execRoot = '$resolvedTmpDir/execroot/_main';
      final binDir = Directory('$execRoot/bazel-out/cfg/bin');
      binDir.createSync(recursive: true);
      addTearDown(() => tmpDir.deleteSync(recursive: true));

      final configFile = File('${binDir.path}/app_dev_config.json');
      configFile.writeAsStringSync(
        jsonEncode({
          'engineRevision': 'abc',
          'flutterVersion': '3.41.2',
          'dartSdkRoot': '/sdk',
          'dartaotruntime': '/bin/dartaotruntime',
          'frontendServer': '/tools/fs.snapshot',
          'patchedSdkRoot': '/patched',
          'appEntrypoint': 'package:my_app/main.dart',
          'dartPluginRegistrants': {
            'ios': 'bazel-out/cfg/bin/app.dev_plugin_registrant.ios.dart',
            'windows': '',
          },
        }),
      );

      final config = parseDevConfig(configFile.path);
      expect(
        p.split(config.registrantFor('ios')),
        p.split(
          '$execRoot/bazel-out/cfg/bin/app.dev_plugin_registrant.ios.dart',
        ),
      );
      expect(config.registrantFor('windows'), isEmpty);
    });

    test('does not absolutize dartDefines, even path-like values', () {
      final tmpDir = Directory.systemTemp.createTempSync('test_dev_cfg_dd_');
      final resolvedTmpDir = tmpDir.resolveSymbolicLinksSync();
      final execRoot = '$resolvedTmpDir/execroot/_main';
      final binDir = Directory('$execRoot/bazel-out/cfg/bin');
      binDir.createSync(recursive: true);
      addTearDown(() => tmpDir.deleteSync(recursive: true));

      final configFile = File('${binDir.path}/app_dev_config.json');
      configFile.writeAsStringSync(
        jsonEncode({
          'engineRevision': 'abc',
          'flutterVersion': '3.41.2',
          'dartSdkRoot': '/sdk',
          'dartaotruntime': '/bin/dartaotruntime',
          'frontendServer': '/tools/fs.snapshot',
          'patchedSdkRoot': '/patched',
          'appEntrypoint': 'package:my_app/main.dart',
          // Defines are KEY=VALUE strings, never paths — a value that merely
          // looks exec-root-relative must pass through untouched.
          'dartDefines': ['ASSET_DIR=external/foo', 'MSG=hello'],
        }),
      );

      final config = parseDevConfig(configFile.path);
      expect(config.dartDefines, ['ASSET_DIR=external/foo', 'MSG=hello']);
    });

    test('parses + absolutizes the codegen multi-root fields', () {
      final tmpDir = Directory.systemTemp.createTempSync('test_dev_cfg_mr_');
      final resolvedTmpDir = tmpDir.resolveSymbolicLinksSync();
      final execRoot = '$resolvedTmpDir/execroot/_main';
      final binDir = Directory('$execRoot/bazel-out/cfg/bin');
      binDir.createSync(recursive: true);
      Directory(
        '$execRoot/external/flutter/dart-sdk/bin',
      ).createSync(recursive: true);
      File(
        '$execRoot/external/flutter/dart-sdk/bin/dartaotruntime',
      ).writeAsStringSync('');

      final configFile = File('${binDir.path}/app_dev_config.json');
      configFile.writeAsStringSync(
        jsonEncode({
          'engineRevision': 'abc',
          'flutterVersion': '3.44.0',
          'dartSdkRoot': 'external/flutter/dart-sdk',
          'dartaotruntime': 'external/flutter/dart-sdk/bin/dartaotruntime',
          'frontendServer': 'external/flutter/fs.snapshot',
          'patchedSdkRoot': 'external/flutter/patched',
          'appEntrypoint': 'package:codegen_e2e/main.dart',
          'devPackageConfig': 'bazel-out/cfg/bin/app.dev_package_config.json',
          'buildPackageConfig': 'bazel-out/cfg/bin/app.package_config.json',
          'filesystemScheme': 'org-dartlang-app',
          'filesystemRoots': ['', 'bazel-out/cfg/bin'],
          'generatedSourcePaths': ['bazel-out/cfg/bin/lib/user.g.dart'],
          'generatedSourceUris': ['package:codegen_e2e/user.g.dart'],
        }),
      );

      final config = parseDevConfig(configFile.path);
      expect(config.filesystemScheme, 'org-dartlang-app');
      // devPackageConfig + filesystemRoots + generatedSourcePaths are
      // exec-relative paths → absolutized (incl. "" → the exec root itself).
      expect(
        p.split(config.devPackageConfig),
        p.split('$execRoot/bazel-out/cfg/bin/app.dev_package_config.json'),
      );
      // Carried as its own field, and absolutized the same way. The dev loop
      // uses both at once — the compiler the dev one, DWDS this one — so a
      // config that collapsed them into "the package config" could not say
      // which a caller meant. Asserted as a distinct path for that reason.
      expect(
        p.split(config.buildPackageConfig),
        p.split('$execRoot/bazel-out/cfg/bin/app.package_config.json'),
      );
      expect(config.buildPackageConfig, isNot(config.devPackageConfig));
      expect(p.split(config.filesystemRoots[0]), p.split(execRoot));
      expect(
        p.split(config.filesystemRoots[1]),
        p.split('$execRoot/bazel-out/cfg/bin'),
      );
      expect(
        p.split(config.generatedSourcePaths.single),
        p.split('$execRoot/bazel-out/cfg/bin/lib/user.g.dart'),
      );
      // URIs are NOT paths — left untouched.
      expect(
        config.generatedSourceUris.single,
        'package:codegen_e2e/user.g.dart',
      );
      // The zipped uri→path map used for reload invalidation.
      expect(
        config.generatedFileUris['package:codegen_e2e/user.g.dart'],
        isNotNull,
      );

      tmpDir.deleteSync(recursive: true);
    });
  });

  group('buildWebToolchainFromOutputs', () {
    test('constructs WebToolchainPaths from output file list', () {
      // Create temp files so resolveSymbolicLinksSync works.
      final tmpDir = Directory.systemTemp.createTempSync('test_web_outputs_');
      final files = <String>[];
      for (final suffix in [
        'app_ddc_outline.dill',
        'app_ddc_libraries.json',
        'app_ddc_dart_sdk.js',
        'app_ddc_module_loader.js',
        'app_ddc_stack_trace_mapper.js',
      ]) {
        final f = File('${tmpDir.path}/$suffix');
        f.writeAsStringSync('dummy');
        files.add(f.path);
      }

      final devConfig = DevConfig(
        engineRevision: 'abc',
        flutterVersion: '3.41.2',
        dartSdkRoot: '/ext/dart-sdk',
        dartaotruntime: '/bin/dartaotruntime',
        frontendServer: '/tools/fs.snapshot',
        patchedSdkRoot: '/patched',
        appEntrypoint: 'package:test_app/main.dart',
      );

      final result = buildWebToolchainFromOutputs(files, devConfig);
      expect(result.ddcOutlineDill, contains('app_ddc_outline.dill'));
      expect(result.librariesSpec, contains('app_ddc_libraries.json'));
      expect(result.dartSdkJs, contains('app_ddc_dart_sdk.js'));
      expect(result.ddcModuleLoaderJs, contains('app_ddc_module_loader.js'));
      expect(
        result.stackTraceMapperJs,
        contains('app_ddc_stack_trace_mapper.js'),
      );
      expect(result.dartSdkRoot, '/ext/dart-sdk');

      tmpDir.deleteSync(recursive: true);
    });

    test('throws when DDC files missing', () {
      final devConfig = DevConfig(
        engineRevision: 'abc',
        flutterVersion: '3.41.2',
        dartSdkRoot: '/ext/dart-sdk',
        dartaotruntime: '/bin/dartaotruntime',
        frontendServer: '/tools/fs.snapshot',
        patchedSdkRoot: '/patched',
        appEntrypoint: 'package:test_app/main.dart',
      );

      expect(
        () => buildWebToolchainFromOutputs([], devConfig),
        throwsStateError,
      );
    });
  });

  group('findWebOutputDir', () {
    test('finds directory ending with _web', () {
      final tmpDir = Directory.systemTemp.createTempSync('test_web_dir_');
      final webDir = Directory('${tmpDir.path}/app_web');
      webDir.createSync();

      final result = findWebOutputDir([
        '${tmpDir.path}/app_dev_config.json',
        webDir.path,
      ]);
      expect(result, webDir.path);

      tmpDir.deleteSync(recursive: true);
    });

    test('throws when no _web directory found', () {
      expect(
        () => findWebOutputDir(['/some/file.json']),
        throwsStateError,
      );
    });
  });
}
