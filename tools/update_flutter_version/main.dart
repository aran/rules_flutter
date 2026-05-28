/// Updates flutter/private/versions.bzl with data for a new Flutter version.
///
/// Usage:
///   bazel run //tools/update_flutter_version -- 3.42.0
///
/// Prerequisites:
///   - A clone of the Flutter repo at references/flutter (or FLUTTER_REPO env var)
///
/// What it does:
///   1. Looks up the engine revision from the Flutter tag
///   2. Downloads each artifact and computes SHA-256
///   3. Prints the Starlark snippet to add to versions.bzl
library;

import 'dart:convert';
import 'dart:io';

const gcsBase = 'https://storage.googleapis.com/flutter_infra_release/flutter';

const artifacts = [
  // Patched Dart SDK for Flutter (debug + product).
  'flutter_patched_sdk.zip',
  'flutter_patched_sdk_product.zip',
  // Host Dart SDK (the Flutter-bundled Dart SDK per host platform).
  'dart-sdk-darwin-arm64.zip',
  'dart-sdk-darwin-x64.zip',
  'dart-sdk-linux-x64.zip',
  'dart-sdk-linux-arm64.zip',
  'dart-sdk-windows-x64.zip',
  // Host tools (frontend_server, gen_snapshot, icudtl.dat).
  'darwin-arm64/artifacts.zip',
  'darwin-x64/artifacts.zip',
  'linux-x64/artifacts.zip',
  'linux-arm64/artifacts.zip',
  'windows-x64/artifacts.zip',
  // Release host tools (product-mode gen_snapshot for AOT builds).
  // Only macOS publishes separate release host tools archives. On Linux and
  // Windows the release gen_snapshot is bundled in the desktop engine archive.
  'darwin-arm64-release/artifacts.zip',
  'darwin-x64-release/artifacts.zip',
  // Font-subset tools (const_finder + font-subset binary for icon tree shaking).
  'darwin-arm64/font-subset.zip',
  'darwin-x64/font-subset.zip',
  'linux-x64/font-subset.zip',
  'linux-arm64/font-subset.zip',
  'windows-x64/font-subset.zip',
  // Flutter web SDK.
  'flutter-web-sdk.zip',
  // Desktop engine runtime libraries (release mode).
  'darwin-x64-release/FlutterMacOS.framework.zip',
  'linux-x64-release/linux-x64-flutter-gtk.zip',
  'windows-x64-release/windows-x64-flutter.zip',
  // Desktop engine runtime libraries (debug mode — JIT, needed for -c dbg).
  'darwin-x64/FlutterMacOS.framework.zip',
  'linux-x64-debug/linux-x64-flutter-gtk.zip',
  'windows-x64-debug/windows-x64-flutter.zip',
  // iOS engine (Flutter.xcframework — release for device, debug for simulator).
  'ios-release/artifacts.zip',
  'ios/artifacts.zip',
  // C++ client wrapper (Windows only — provides flutter/plugin_registry.h).
  'windows-x64/flutter-cpp-client-wrapper.zip',
];

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('Usage: bazel run //tools/update_flutter_version -- <flutter-version>');
    exit(1);
  }

  final version = args[0];

  // Locate the Flutter repo. BUILD_WORKSPACE_DIRECTORY is set by `bazel run`.
  final workspaceDir =
      Platform.environment['BUILD_WORKSPACE_DIRECTORY'] ?? Directory.current.path;
  final flutterRepo =
      Platform.environment['FLUTTER_REPO'] ?? '$workspaceDir/references/flutter';

  print('Flutter version: $version');
  print('Flutter repo: $flutterRepo');

  // Get engine revision from the Flutter tag.
  final gitResult = Process.runSync(
    'git',
    ['show', '$version:bin/internal/engine.version'],
    workingDirectory: flutterRepo,
  );
  if (gitResult.exitCode != 0) {
    stderr.writeln(
        'ERROR: Could not find engine.version for tag $version in $flutterRepo');
    stderr.writeln('Make sure the tag exists: git fetch --tags');
    exit(1);
  }
  final engineRev = (gitResult.stdout as String).trim();
  print('Engine revision: $engineRev');

  // Get material fonts URL from the Flutter repo.
  final materialFontsResult = Process.runSync(
    'git',
    ['show', '$version:bin/internal/material_fonts.version'],
    workingDirectory: flutterRepo,
  );
  if (materialFontsResult.exitCode != 0) {
    stderr.writeln('ERROR: Could not find material_fonts.version for tag $version');
    exit(1);
  }
  final materialFontsUrl = (materialFontsResult.stdout as String).trim();
  print('Material fonts URL: $materialFontsUrl');

  // Download artifacts and compute checksums.
  print('');
  print('Downloading artifacts and computing checksums...');
  print('(this may take a few minutes)');
  print('');

  final checksums = <String, String>{};
  final client = HttpClient();

  for (final artifact in artifacts) {
    final url = '$gcsBase/$engineRev/$artifact';
    stdout.write('  $artifact ... ');

    try {
      final sha = await _downloadAndHash(client, url);
      checksums[artifact] = sha;
      print(sha);
    } catch (e) {
      print('FAILED ($e)');
    }
  }

  // Download material fonts and compute checksum.
  {
    final url = 'https://storage.googleapis.com/$materialFontsUrl';
    stdout.write('  material_fonts.zip ... ');
    try {
      final sha = await _downloadAndHash(client, url);
      checksums['material_fonts.zip'] = sha;
      print(sha);
    } catch (e) {
      print('FAILED ($e)');
    }
  }

  client.close();

  // Check Linux sysroot checksums from the engine's sysroots.json.
  // The file lives in the Flutter monorepo at the version tag, under
  // engine/src/build/linux/sysroot_scripts/sysroots.json.
  print('');
  print('Checking Linux sysroot checksums...');
  final sysrootsResult = Process.runSync(
    'git',
    ['show', '$version:engine/src/build/linux/sysroot_scripts/sysroots.json'],
    workingDirectory: flutterRepo,
  );
  if (sysrootsResult.exitCode == 0) {
    try {
      final sysroots = jsonDecode(sysrootsResult.stdout as String) as Map<String, dynamic>;

      // Read current checksums from versions.bzl so we compare against the
      // actual committed values, not hardcoded copies.
      final currentChecksums = _readCurrentSysrootChecksums(workspaceDir);

      final newAmd64 = (sysroots['bullseye_amd64'] as Map<String, dynamic>?)?['Sha256Sum'] as String?;
      final newArm64 = (sysroots['bullseye_arm64'] as Map<String, dynamic>?)?['Sha256Sum'] as String?;
      final changed = newAmd64 != currentChecksums['amd64'] || newArm64 != currentChecksums['arm64'];
      if (changed) {
        print('  WARNING: Sysroot checksums have changed!');
        print('  Update LINUX_SYSROOT_CHECKSUMS in flutter/private/versions.bzl:');
        print('');
        print('LINUX_SYSROOT_CHECKSUMS = {');
        if (newAmd64 != null) print('    "amd64": "$newAmd64",');
        if (newArm64 != null) print('    "arm64": "$newArm64",');
        print('}');
      } else {
        print('  Sysroot checksums unchanged.');
      }
    } catch (e) {
      print('  WARNING: Failed to parse sysroots.json: $e');
    }
  } else {
    print('  Could not read sysroots.json for tag $version (path may differ in older Flutter versions).');
  }

  // Print Starlark snippet.
  print('');
  print('=== Add to FLUTTER_VERSIONS in flutter/private/versions.bzl ===');
  print('');
  print('    "$version": struct(');
  print('        engine_revision = "$engineRev",');
  print('        material_fonts_url = "$materialFontsUrl",');
  print('    ),');
  print('');
  print('=== Add to ARTIFACT_CHECKSUMS in flutter/private/versions.bzl ===');
  print('');
  print('    "$version": {');
  print('        # Patched Dart SDK for Flutter (debug + product)');
  _printChecksum(checksums, 'flutter_patched_sdk.zip');
  _printChecksum(checksums, 'flutter_patched_sdk_product.zip');
  print('        # Host Dart SDK (the Flutter-bundled Dart SDK per host platform)');
  _printChecksum(checksums, 'dart-sdk-darwin-arm64.zip');
  _printChecksum(checksums, 'dart-sdk-darwin-x64.zip');
  _printChecksum(checksums, 'dart-sdk-linux-x64.zip');
  _printChecksum(checksums, 'dart-sdk-linux-arm64.zip');
  _printChecksum(checksums, 'dart-sdk-windows-x64.zip');
  print('        # Host tools (frontend_server, gen_snapshot, icudtl.dat)');
  _printChecksum(checksums, 'darwin-arm64/artifacts.zip');
  _printChecksum(checksums, 'darwin-x64/artifacts.zip');
  _printChecksum(checksums, 'linux-x64/artifacts.zip');
  _printChecksum(checksums, 'linux-arm64/artifacts.zip');
  _printChecksum(checksums, 'windows-x64/artifacts.zip');
  print('        # Release host tools (macOS only — product-mode gen_snapshot for AOT builds)');
  _printChecksum(checksums, 'darwin-arm64-release/artifacts.zip');
  _printChecksum(checksums, 'darwin-x64-release/artifacts.zip');
  print('        # Font-subset tools (const_finder + font-subset binary for icon tree shaking)');
  _printChecksum(checksums, 'darwin-arm64/font-subset.zip');
  _printChecksum(checksums, 'darwin-x64/font-subset.zip');
  _printChecksum(checksums, 'linux-x64/font-subset.zip');
  _printChecksum(checksums, 'linux-arm64/font-subset.zip');
  _printChecksum(checksums, 'windows-x64/font-subset.zip');
  print('        # Flutter web SDK');
  _printChecksum(checksums, 'flutter-web-sdk.zip');
  print('        # Desktop engine runtime libraries (release mode)');
  _printChecksum(checksums, 'darwin-x64-release/FlutterMacOS.framework.zip');
  _printChecksum(checksums, 'linux-x64-release/linux-x64-flutter-gtk.zip');
  _printChecksum(checksums, 'windows-x64-release/windows-x64-flutter.zip');
  print('        # Desktop engine runtime libraries (debug mode — JIT, needed for -c dbg)');
  _printChecksum(checksums, 'darwin-x64/FlutterMacOS.framework.zip');
  _printChecksum(checksums, 'linux-x64-debug/linux-x64-flutter-gtk.zip');
  _printChecksum(checksums, 'windows-x64-debug/windows-x64-flutter.zip');
  print('        # iOS engine (Flutter.xcframework — release for device, debug for simulator)');
  _printChecksum(checksums, 'ios-release/artifacts.zip');
  _printChecksum(checksums, 'ios/artifacts.zip');
  print('        # C++ client wrapper (Windows — flutter/plugin_registry.h)');
  _printChecksum(checksums, 'windows-x64/flutter-cpp-client-wrapper.zip');
  print('        # Material design fonts (MaterialIcons-Regular.otf, Roboto family)');
  _printChecksum(checksums, 'material_fonts.zip');
  print('    },');
}

void _printChecksum(Map<String, String> checksums, String artifact) {
  final sha = checksums[artifact] ?? 'MISSING';
  print('        "$artifact": "$sha",');
}

Future<String> _downloadAndHash(HttpClient client, String url) async {
  final uri = Uri.parse(url);
  final request = await client.getUrl(uri);
  final response = await request.close();

  // Follow redirects manually if needed.
  if (response.statusCode == 302 || response.statusCode == 301) {
    final location = response.headers['location']?.first;
    if (location != null) {
      await response.drain<void>();
      return _downloadAndHash(client, location);
    }
  }

  if (response.statusCode != 200) {
    await response.drain<void>();
    throw 'HTTP ${response.statusCode}';
  }

  // Download to a temp file, then compute SHA-256 using a platform-appropriate tool.
  final tempDir = await Directory.systemTemp.createTemp('flutter_hash_');
  final tempFile = File('${tempDir.path}/artifact');
  final sink = tempFile.openWrite();
  await response.pipe(sink);

  try {
    final hash = await _sha256OfFile(tempFile.path);
    return hash;
  } finally {
    await tempDir.delete(recursive: true);
  }
}

/// Reads LINUX_SYSROOT_CHECKSUMS from versions.bzl.
///
/// Returns a map like `{'amd64': '<sha256>', 'arm64': '<sha256>'}`.
/// Falls back to empty strings if the file can't be parsed.
Map<String, String> _readCurrentSysrootChecksums(String workspaceDir) {
  final result = <String, String>{'amd64': '', 'arm64': ''};
  try {
    final content = File('$workspaceDir/flutter/private/versions.bzl').readAsStringSync();
    // Match lines like:   "amd64": "abc123...",
    final pattern = RegExp(r'"(amd64|arm64)":\s*"([a-f0-9]+)"');
    // Only look at lines after LINUX_SYSROOT_CHECKSUMS.
    final idx = content.indexOf('LINUX_SYSROOT_CHECKSUMS');
    if (idx < 0) return result;
    final section = content.substring(idx);
    for (final match in pattern.allMatches(section)) {
      result[match.group(1)!] = match.group(2)!;
    }
  } catch (_) {
    // If we can't read versions.bzl, comparison will always show "changed".
  }
  return result;
}

Future<String> _sha256OfFile(String path) async {
  if (Platform.isWindows) {
    // certutil outputs multiple lines; the hash is on the second line.
    final result = await Process.run('certutil', ['-hashfile', path, 'SHA256']);
    if (result.exitCode != 0) throw 'certutil failed: ${result.stderr}';
    final lines = (result.stdout as String).trim().split('\n');
    if (lines.length < 2) throw 'Unexpected certutil output';
    return lines[1].trim().replaceAll(' ', '');
  } else {
    // macOS and Linux: use sha256sum (Linux) or shasum -a 256 (macOS).
    ProcessResult result;
    if (Platform.isMacOS) {
      result = await Process.run('shasum', ['-a', '256', path]);
    } else {
      result = await Process.run('sha256sum', [path]);
    }
    if (result.exitCode != 0) throw 'sha256 hash failed: ${result.stderr}';
    return (result.stdout as String).split(' ').first;
  }
}
