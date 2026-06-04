/// Extracts Flutter toolchain paths from Bazel.
///
/// Uses `bazel cquery` to discover the paths to:
/// - dart binary
/// - dartaotruntime binary
/// - frontend_server_aot.dart.snapshot
/// - platform_strong.dill (debug)
/// - patched SDK root
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:path/path.dart' as p;

/// Toolchain paths resolved from Bazel.
class ToolchainPaths {
  final String dart;
  final String dartaotruntime;
  final String frontendServer;
  final String platformDill;
  final String patchedSdkRoot;

  ToolchainPaths({
    required this.dart,
    required this.dartaotruntime,
    required this.frontendServer,
    required this.platformDill,
    required this.patchedSdkRoot,
  });
}

/// Resolve Flutter toolchain paths from Bazel for a given target.
///
/// This runs `bazel cquery` to find the toolchain repo, then constructs
/// paths to the specific binaries within the external repo. [workspace]
/// must be the consumer's workspace root — it's used as the spawned
/// bazel process's `workingDirectory` so the call works under
/// `bazel run` (where `Directory.current` is the runfiles execroot).
Future<ToolchainPaths> resolveToolchainPaths(
  String target, {
  required String workspace,
}) async {
  // Use bazel info to find the output base.
  final infoResult = await Process.run('bazel', ['info', 'output_base'],
      workingDirectory: workspace);
  if (infoResult.exitCode != 0) {
    throw StateError('Failed to get bazel output_base: ${infoResult.stderr}');
  }
  final outputBase = (infoResult.stdout as String).trim();

  // Find the Flutter toolchain repo in the external directory.
  // With bzlmod the repo name is 'rules_flutter++flutter+flutter_{platform}',
  // with WORKSPACE it's just 'flutter_{platform}'.
  final platform = detectHostPlatform();
  final externalBase = p.join(outputBase, 'external');
  final candidates = [
    'rules_flutter++flutter+flutter_$platform',  // bzlmod
    'flutter_engine_$platform',  // WORKSPACE
    'flutter_$platform',  // legacy
  ];
  String? externalDir;
  for (final name in candidates) {
    final dir = p.join(externalBase, name);
    if (Directory(dir).existsSync()) {
      externalDir = dir;
      break;
    }
  }
  if (externalDir == null) {
    // Try fetching the repo first.
    await Process.run('bazel', ['fetch', target],
        workingDirectory: workspace,
        stderrEncoding: utf8, stdoutEncoding: utf8);
    for (final name in candidates) {
      final dir = p.join(externalBase, name);
      if (Directory(dir).existsSync()) {
        externalDir = dir;
        break;
      }
    }
  }
  if (externalDir == null) {
    throw StateError(
      'Could not find Flutter toolchain in $externalBase. '
      'Tried: ${candidates.join(", ")}',
    );
  }

  final isWindows = Platform.isWindows;
  final dartBin = isWindows ? 'dart.exe' : 'dart';
  final dartaotruntimeBin = isWindows ? 'dartaotruntime.exe' : 'dartaotruntime';

  return ToolchainPaths(
    dart: p.join(externalDir, 'dart-sdk', 'bin', dartBin),
    dartaotruntime: p.join(externalDir, 'dart-sdk', 'bin', dartaotruntimeBin),
    frontendServer: p.join(externalDir, 'host-tools', 'frontend_server_aot.dart.snapshot'),
    platformDill: p.join(
      externalDir,
      'patched-sdk',
      'flutter_patched_sdk',
      'platform_strong.dill',
    ),
    patchedSdkRoot: p.join(externalDir, 'patched-sdk', 'flutter_patched_sdk'),
  );
}

/// Discover the Bazel-generated package_config.json for the frontend server.
///
/// Returns the symlink-resolved path to the config file. The frontend server
/// resolves the relative URIs in the config relative to the config file's
/// real location in the Bazel output tree.
String? discoverPackageConfig(List<String> outputFiles) {
  String? nested;
  for (final f in outputFiles) {
    if (f.endsWith('package_config.json')) {
      if (!f.contains('.dart_tool')) {
        return _resolve(f);
      }
      nested ??= f;
    }
  }
  if (nested != null) return _resolve(nested);
  return null;
}

String detectHostPlatform() {
  final os = Platform.operatingSystem;
  final arch = detectArch();

  switch (os) {
    case 'macos':
      return 'darwin-$arch';
    case 'linux':
      return 'linux-$arch';
    case 'windows':
      return 'windows-$arch';
    default:
      throw UnsupportedError('Unsupported OS: $os');
  }
}

String detectArch() {
  final abi = Abi.current();
  if (abi == Abi.macosArm64 ||
      abi == Abi.linuxArm64 ||
      abi == Abi.windowsArm64) {
    return 'arm64';
  }
  return 'x64';
}

/// Paths to web SDK artifacts for DDC dev mode.
class WebToolchainPaths {
  final String ddcOutlineDill;
  final String librariesSpec;
  final String dartSdkJs;
  final String ddcModuleLoaderJs;
  final String stackTraceMapperJs;
  final String dartSdkRoot;

  WebToolchainPaths({
    required this.ddcOutlineDill,
    required this.librariesSpec,
    required this.dartSdkJs,
    required this.ddcModuleLoaderJs,
    required this.stackTraceMapperJs,
    required this.dartSdkRoot,
  });
}

/// Dev config parsed from `_dev_config.json` emitted by `flutter_web_bundle`
/// in debug mode.
///
/// Contains engine revision, version, host toolchain paths, and dart-sdk root.
class DevConfig {
  final String engineRevision;
  final String flutterVersion;
  final String dartSdkRoot;
  final String dartaotruntime;
  final String frontendServer;
  final String patchedSdkRoot;

  /// The app's entrypoint as a package: URI (e.g. `package:my_app/main.dart`)
  /// or exec-root-relative path if package_name was not set.
  final String appEntrypoint;

  /// Absolute path to the hot-reload package_config (distinct from the build
  /// one): for a source-assembled app its rootUri uses [filesystemScheme] so it
  /// resolves across the live source tree + generated bazel-out roots. Empty
  /// when the build did not emit one (e.g. web dev configs).
  final String devPackageConfig;

  /// Absolute `--filesystem-root` dirs the frontend_server searches for
  /// [filesystemScheme] URIs (live source roots, then generated bazel-out
  /// roots). Empty unless the app package is source-assembled.
  final List<String> filesystemRoots;

  /// The `--filesystem-scheme` paired with [filesystemRoots] (e.g.
  /// `org-dartlang-app`). Empty when [filesystemRoots] is empty.
  final String filesystemScheme;

  /// Absolute paths of the generated files in the app package; re-stat'd after
  /// a rebuild to add changed ones to the reload invalidation set. Parallel to
  /// [generatedSourceUris].
  final List<String> generatedSourcePaths;

  /// The `package:` URIs of the generated files, parallel to
  /// [generatedSourcePaths] (so the dev tool invalidates the right library
  /// without inferring a URI from a path).
  final List<String> generatedSourceUris;

  /// First-party source packages (app + local deps) as `{name, libRoot}`, where
  /// `libRoot` is workspace-relative. Drives the [PackageUriResolver] so a live
  /// edit in any of these packages maps to its `package:` URI. Empty for web
  /// dev configs only if the build emitted none.
  final List<({String name, String libRoot})> sourcePackages;

  DevConfig({
    required this.engineRevision,
    required this.flutterVersion,
    required this.dartSdkRoot,
    required this.dartaotruntime,
    required this.frontendServer,
    required this.patchedSdkRoot,
    required this.appEntrypoint,
    this.devPackageConfig = '',
    this.filesystemRoots = const [],
    this.filesystemScheme = '',
    this.generatedSourcePaths = const [],
    this.generatedSourceUris = const [],
    this.sourcePackages = const [],
  });

  /// Generated files as `{package: URI → absolute path}` for reload
  /// invalidation, zipped from the parallel [generatedSourceUris] /
  /// [generatedSourcePaths].
  Map<String, String> get generatedFileUris => {
        for (var i = 0;
            i < generatedSourceUris.length && i < generatedSourcePaths.length;
            i++)
          generatedSourceUris[i]: generatedSourcePaths[i],
      };

  /// Parse from the JSON content of a `_dev_config.json` file. The native
  /// (`flutter_application`) config carries the hot-reload multi-root fields;
  /// the web (`flutter_web_bundle`) config omits them, so they default empty.
  factory DevConfig.fromJson(Map<String, dynamic> json) {
    List<String> strList(String key) =>
        ((json[key] as List?) ?? const []).cast<String>();
    return DevConfig(
      engineRevision: json['engineRevision'] as String,
      flutterVersion: json['flutterVersion'] as String,
      dartSdkRoot: json['dartSdkRoot'] as String,
      dartaotruntime: json['dartaotruntime'] as String,
      frontendServer: json['frontendServer'] as String,
      patchedSdkRoot: json['patchedSdkRoot'] as String,
      appEntrypoint: json['appEntrypoint'] as String,
      devPackageConfig: (json['devPackageConfig'] as String?) ?? '',
      filesystemRoots: strList('filesystemRoots'),
      filesystemScheme: (json['filesystemScheme'] as String?) ?? '',
      generatedSourcePaths: strList('generatedSourcePaths'),
      generatedSourceUris: strList('generatedSourceUris'),
      sourcePackages: [
        for (final e in (json['sourcePackages'] as List?) ?? const [])
          (
            name: (e as Map)['name'] as String,
            libRoot: e['libRoot'] as String,
          ),
      ],
    );
  }
}

/// Find `_dev_config.json` in build output files.
///
/// `bazel cquery <label> --output=files` can list the dev config in MORE THAN
/// ONE configuration for a cross-platform app: the `flutter_application` is
/// reached through the platform app's apple/android transition, so it appears
/// both in the transitioned config (e.g. `ios_sim_arm64-dbg-…-ST-<hash>`) AND
/// in the default host config (`darwin_arm64-dbg`). The dev tool builds the
/// BARE `flutter_application` label, which materializes only the host-config
/// instance — the transitioned path is a dangling symlink. Prefer a candidate
/// that actually resolves on disk; fall back to the first when none do (so the
/// caller surfaces a clear downstream error rather than silently finding none).
String? findDevConfig(List<String> files) {
  final candidates = [
    for (final f in files)
      if (f.endsWith('_dev_config.json')) f,
  ];
  if (candidates.isEmpty) return null;
  for (final f in candidates) {
    try {
      File(f).resolveSymbolicLinksSync();
      return f;
    } catch (_) {
      // Dangling symlink / nonexistent (an unbuilt transitioned config) — skip.
    }
  }
  return candidates.first;
}

/// Parse dev config JSON from a file path, resolving symlinks.
///
/// Paths in the JSON are execution-root-relative (e.g. `external/repo/...`).
/// We derive the execution root from the dev_config.json file's resolved
/// location (`.../execroot/_main/bazel-out/.../dev_config.json` → strip
/// from `/bazel-out/` onward) and prepend it to make all paths absolute.
DevConfig parseDevConfig(String path) {
  final resolved = File(path).resolveSymbolicLinksSync();
  final json = jsonDecode(File(resolved).readAsStringSync()) as Map<String, dynamic>;

  // Derive execution root: resolved path contains .../execroot/_main/bazel-out/...
  // Split into path components (separator-agnostic, so it works on Windows
  // where File.resolveSymbolicLinksSync returns '\'-separated paths) and strip
  // from the 'bazel-out' segment onward.
  final parts = p.split(resolved);
  final bazelOutIdx = parts.indexOf('bazel-out');
  final execRoot = bazelOutIdx > 0 ? p.joinAll(parts.sublist(0, bazelOutIdx)) : null;

  if (execRoot != null) {
    String abs(String value) => p.isAbsolute(value) ? value : p.join(execRoot, value);

    // Make execution-root-relative path strings absolute.
    for (final key in [
      'dartSdkRoot',
      'dartaotruntime',
      'frontendServer',
      'patchedSdkRoot',
      'devPackageConfig',
    ]) {
      final value = json[key];
      if (value is String && value.isNotEmpty) json[key] = abs(value);
    }
    // Absolutize the exec-relative path LISTS (roots incl. "" → execroot, and
    // generated output paths). `generatedSourcesTarget` holds bazel labels, not
    // paths — leave it untouched.
    for (final key in ['filesystemRoots', 'generatedSourcePaths']) {
      final list = json[key] as List?;
      if (list != null) {
        json[key] = [for (final v in list.cast<String>()) abs(v)];
      }
    }
  }

  return DevConfig.fromJson(json);
}

/// Find DDC dev files in build outputs and construct [WebToolchainPaths].
///
/// Looks for files by suffix pattern in the output list.
WebToolchainPaths buildWebToolchainFromOutputs(
  List<String> outputFiles,
  DevConfig devConfig,
) {
  String? ddcOutlineDill;
  String? librariesSpec;
  String? dartSdkJs;
  String? ddcModuleLoaderJs;
  String? stackTraceMapperJs;

  for (final f in outputFiles) {
    if (f.endsWith('_ddc_outline.dill')) {
      ddcOutlineDill = _resolve(f);
    } else if (f.endsWith('_ddc_libraries.json')) {
      librariesSpec = _resolve(f);
    } else if (f.endsWith('_ddc_dart_sdk.js')) {
      dartSdkJs = _resolve(f);
    } else if (f.endsWith('_ddc_module_loader.js')) {
      ddcModuleLoaderJs = _resolve(f);
    } else if (f.endsWith('_ddc_stack_trace_mapper.js')) {
      stackTraceMapperJs = _resolve(f);
    }
  }

  final missing = <String>[];
  if (ddcOutlineDill == null) missing.add('_ddc_outline.dill');
  if (librariesSpec == null) missing.add('_ddc_libraries.json');
  if (dartSdkJs == null) missing.add('_ddc_dart_sdk.js');
  if (ddcModuleLoaderJs == null) missing.add('_ddc_module_loader.js');
  if (stackTraceMapperJs == null) missing.add('_ddc_stack_trace_mapper.js');
  if (missing.isNotEmpty) {
    throw StateError(
        'Missing DDC dev files in build outputs: ${missing.join(', ')}.\n'
        'Ensure the target is a flutter_web_bundle built with -c dbg.');
  }

  return WebToolchainPaths(
    ddcOutlineDill: ddcOutlineDill!,
    librariesSpec: librariesSpec!,
    dartSdkJs: dartSdkJs!,
    ddcModuleLoaderJs: ddcModuleLoaderJs!,
    stackTraceMapperJs: stackTraceMapperJs!,
    dartSdkRoot: devConfig.dartSdkRoot,
  );
}

/// Find the web output directory in build outputs.
///
/// The web output dir ends with `_web` and is a directory.
String findWebOutputDir(List<String> outputFiles) {
  for (final f in outputFiles) {
    if (f.endsWith('_web') && FileSystemEntity.isDirectorySync(f)) {
      return f;
    }
  }
  throw StateError(
      'No web output directory found in build outputs.\n'
      'Expected a directory ending with _web.');
}

String _resolve(String path) {
  try {
    return File(path).resolveSymbolicLinksSync();
  } catch (_) {
    return path;
  }
}
