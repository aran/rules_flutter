import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter_bazel_dev_tool/toolchain_info.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('discoverPackageConfig', () {
    test('finds package_config.json directly in build outputs', () {
      final result = discoverPackageConfig([
        '/bazel-out/k8-dbg/bin/app.dill',
        '/bazel-out/k8-dbg/bin/package_config.json',
      ]);
      expect(result, '/bazel-out/k8-dbg/bin/package_config.json');
    });

    test('finds .dart_tool/package_config.json in build outputs', () {
      final result = discoverPackageConfig([
        '/bazel-out/k8-dbg/bin/app.dill',
        '/bazel-out/k8-dbg/bin/.dart_tool/package_config.json',
      ]);
      expect(result, '/bazel-out/k8-dbg/bin/.dart_tool/package_config.json');
    });

    test('returns null when no package_config.json in outputs', () {
      final result = discoverPackageConfig([
        '/bazel-out/k8-dbg/bin/app.dill',
        '/bazel-out/k8-dbg/bin/app.so',
      ]);
      expect(result, isNull);
    });

    test('prefers exact package_config.json over nested path', () {
      final result = discoverPackageConfig([
        '/bazel-out/k8-dbg/bin/.dart_tool/package_config.json',
        '/bazel-out/k8-dbg/bin/package_config.json',
      ]);
      expect(result, '/bazel-out/k8-dbg/bin/package_config.json');
    });
  });

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
      expect(paths.frontendServer,
          '/tools/frontend_server_aot.dart.snapshot');
      expect(paths.platformDill, '/patched-sdk/platform_strong.dill');
      expect(paths.patchedSdkRoot, '/patched-sdk/flutter_patched_sdk');
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
      expect(platform, matches(RegExp(r'^(darwin|linux|windows)-(arm64|x64)$')));
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
      final isArm64Host = Abi.current() == Abi.macosArm64 ||
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
      expect(config.frontendServer,
          '/ext/host-tools/frontend_server_aot.dart.snapshot');
      expect(config.patchedSdkRoot,
          '/ext/patched-sdk/flutter_patched_sdk');
      expect(config.appEntrypoint, 'package:my_app/main.dart');
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
  });

  group('parseDevConfig', () {
    test('reads and parses a JSON file with absolute paths', () {
      final tmpDir = Directory.systemTemp.createTempSync('test_dev_config_');
      final configFile = File('${tmpDir.path}/test_dev_config.json');
      configFile.writeAsStringSync(jsonEncode({
        'engineRevision': 'rev123',
        'flutterVersion': '3.41.2',
        'dartSdkRoot': '/sdk',
        'dartaotruntime': '/bin/dartaotruntime',
        'frontendServer': '/tools/fs.snapshot',
        'patchedSdkRoot': '/patched',
        'appEntrypoint': 'package:my_app/main.dart',
      }));

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
      configFile.writeAsStringSync(jsonEncode({
        'engineRevision': 'abc',
        'flutterVersion': '3.41.2',
        'dartSdkRoot': 'external/flutter/dart-sdk',
        'dartaotruntime': 'external/flutter/dart-sdk/bin/dartaotruntime',
        'frontendServer': 'external/flutter/fs.snapshot',
        'patchedSdkRoot': 'external/flutter/patched',
        'appEntrypoint': 'package:my_app/main.dart',
      }));

      final config = parseDevConfig(configFile.path);
      // Relative paths should be resolved to absolute using the exec root.
      // Compare on path components so the assertion is independent of the host
      // OS separator (Windows resolves to '\', the literals here use '/').
      expect(p.split(config.dartSdkRoot),
          p.split('$execRoot/external/flutter/dart-sdk'));
      expect(p.split(config.dartaotruntime),
          p.split('$execRoot/external/flutter/dart-sdk/bin/dartaotruntime'));
      expect(p.split(config.frontendServer),
          p.split('$execRoot/external/flutter/fs.snapshot'));
      expect(p.split(config.patchedSdkRoot),
          p.split('$execRoot/external/flutter/patched'));

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
      expect(result.stackTraceMapperJs,
          contains('app_ddc_stack_trace_mapper.js'));
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
