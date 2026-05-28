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

  DevConfig({
    required this.engineRevision,
    required this.flutterVersion,
    required this.dartSdkRoot,
    required this.dartaotruntime,
    required this.frontendServer,
    required this.patchedSdkRoot,
    required this.appEntrypoint,
  });

  /// Parse from the JSON content of a `_dev_config.json` file.
  factory DevConfig.fromJson(Map<String, dynamic> json) {
    return DevConfig(
      engineRevision: json['engineRevision'] as String,
      flutterVersion: json['flutterVersion'] as String,
      dartSdkRoot: json['dartSdkRoot'] as String,
      dartaotruntime: json['dartaotruntime'] as String,
      frontendServer: json['frontendServer'] as String,
      patchedSdkRoot: json['patchedSdkRoot'] as String,
      appEntrypoint: json['appEntrypoint'] as String,
    );
  }
}

/// Find `_dev_config.json` in build output files.
String? findDevConfig(List<String> files) {
  for (final f in files) {
    if (f.endsWith('_dev_config.json')) return f;
  }
  return null;
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
    // Make execution-root-relative paths absolute.
    for (final key in ['dartSdkRoot', 'dartaotruntime', 'frontendServer', 'patchedSdkRoot']) {
      final value = json[key] as String;
      if (!p.isAbsolute(value)) {
        json[key] = p.join(execRoot, value);
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
