/// Updates flutter/private/versions.bzl with data for a new Flutter version.
///
/// Usage:
///   bazel run //tools/update_flutter_version -- 3.42.0
///
/// Prerequisites:
///   - A clone of the Flutter repo beside this one, at ../flutter (or FLUTTER_REPO env var)
///
/// What it does:
///   1. Looks up the engine revision from the Flutter tag
///   2. Downloads each artifact and computes SHA-256 (archives already pinned
///      in versions.bzl for this version are reused, not downloaded again)
///   3. Prints the Starlark snippet to add to versions.bzl, with the exact
///      version pins of the SDK's own packages (`FLUTTER_SDK_EXACT_PINS`) and
///      the packages there are (`FLUTTER_SDK_PACKAGES`)
///
/// `--sdk-pins-only <version>` prints just those two entries.
library;

import 'dart:convert';
import 'dart:io';

import 'artifact_list.dart';
import 'pinned_checksums.dart';
import 'sdk_pins.dart';
import 'shader_flags.dart';

const gcsBase = 'https://storage.googleapis.com/flutter_infra_release/flutter';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'Usage: bazel run //tools/update_flutter_version -- <flutter-version>',
    );
    exit(1);
  }

  final pinsOnly = args[0] == '--sdk-pins-only';
  if (pinsOnly && args.length < 2) {
    stderr.writeln('Usage: --sdk-pins-only <flutter-version>');
    exit(1);
  }
  final version = pinsOnly ? args[1] : args[0];

  // Locate the Flutter repo. BUILD_WORKSPACE_DIRECTORY is set by `bazel run`.
  final workspaceDir =
      Platform.environment['BUILD_WORKSPACE_DIRECTORY'] ??
      Directory.current.path;
  final flutterRepo =
      Platform.environment['FLUTTER_REPO'] ??
      '${Directory(workspaceDir).parent.path}/flutter';

  print('Flutter version: $version');
  print('Flutter repo: $flutterRepo');
  if (!Directory(flutterRepo).existsSync()) {
    stderr.writeln('ERROR: No Flutter clone at $flutterRepo');
    stderr.writeln(
      'Clone https://github.com/flutter/flutter beside this repo, '
      'or set FLUTTER_REPO to an existing clone.',
    );
    exit(1);
  }

  if (pinsOnly) {
    print(_sdkPackageEntries(version, flutterRepo));
    return;
  }

  // Get engine revision from the Flutter tag.
  final gitResult = Process.runSync(
    'git',
    ['show', '$version:bin/internal/engine.version'],
    workingDirectory: flutterRepo,
  );
  if (gitResult.exitCode != 0) {
    stderr.writeln(
      'ERROR: Could not find engine.version for tag $version in $flutterRepo',
    );
    stderr.writeln('Make sure the tag exists: git fetch --tags');
    exit(1);
  }
  final engineRev = (gitResult.stdout as String).trim();
  print('Engine revision: $engineRev');

  // The release tag's commit: the framework revision `FlutterVersion` reports.
  final frameworkResult = Process.runSync(
    'git',
    ['rev-parse', '$version^{commit}'],
    workingDirectory: flutterRepo,
  );
  if (frameworkResult.exitCode != 0) {
    stderr.writeln('ERROR: Could not resolve tag $version in $flutterRepo');
    exit(1);
  }
  final frameworkRev = (frameworkResult.stdout as String).trim();
  print('Framework revision: $frameworkRev');

  // The Dart SDK the release bundles, which Flutter publishes with each
  // stable release and which `FlutterVersion.dartVersion` reports.
  final dartVersion = await _releasedDartVersion(version, frameworkRev);
  print('Dart version: $dartVersion');

  // Get material fonts URL from the Flutter repo.
  final materialFontsResult = Process.runSync(
    'git',
    ['show', '$version:bin/internal/material_fonts.version'],
    workingDirectory: flutterRepo,
  );
  if (materialFontsResult.exitCode != 0) {
    stderr.writeln(
      'ERROR: Could not find material_fonts.version for tag $version',
    );
    exit(1);
  }
  final materialFontsUrl = (materialFontsResult.stdout as String).trim();
  print('Material fonts URL: $materialFontsUrl');

  // Download artifacts and compute checksums.
  print('');
  print('Downloading artifacts and computing checksums...');
  print('(this may take a few minutes)');
  print('');

  // Archives already pinned for this version are not downloaded again.
  final versionsBzl = File(
    '$workspaceDir/flutter/private/versions.bzl',
  ).readAsStringSync();
  final pinned = pinnedArtifactChecksums(versionsBzl, version);
  final checksums = <String, String>{};
  final client = HttpClient();

  for (final artifact in artifacts) {
    final known = pinned[artifact];
    if (known != null) {
      checksums[artifact] = known;
      print('  $artifact ... $known (pinned)');
      continue;
    }
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

  // The Flutter source tarball. Not an engine artifact — it comes from GitHub,
  // keyed by release tag rather than engine revision. Every rule that needs
  // Flutter's own Dart source pins this one checksum: the per-package SDK
  // spokes, the vendored gen-l10n generator, and the FLUTTER_ROOT tree behind
  // `flutter/pub`. A version entry without it cannot be built.
  final pinnedSource = pinnedSourceSha256(versionsBzl, version);
  if (pinnedSource != null) {
    checksums['__source__'] = pinnedSource;
    print('  flutter-$version.tar.gz (source) ... $pinnedSource (pinned)');
  } else {
    final url =
        'https://github.com/flutter/flutter/archive/refs/tags/$version.tar.gz';
    stdout.write('  flutter-$version.tar.gz (source) ... ');
    try {
      final sha = await _downloadAndHash(client, url);
      checksums['__source__'] = sha;
      print(sha);
    } catch (e) {
      print('FAILED ($e)');
    }
  }

  // The Dart SDK source tarball of the engine's Dart, which rules_dart's
  // `dart_kernel_source` builds the outline stripper from. rules_dart pins
  // only the Dart releases it serves, so the checksum is kept here.
  final pinnedDartSource = pinnedDartSourceSha256(versionsBzl, version);
  if (pinnedDartSource != null) {
    checksums['__dart_source__'] = pinnedDartSource;
    print(
      '  dart-sdk-$dartVersion.tar.gz (source) ... $pinnedDartSource (pinned)',
    );
  } else {
    final url =
        'https://github.com/dart-lang/sdk/archive/refs/tags/$dartVersion.tar.gz';
    stdout.write('  dart-sdk-$dartVersion.tar.gz (source) ... ');
    try {
      final sha = await _downloadAndHash(client, url);
      checksums['__dart_source__'] = sha;
      print(sha);
    } catch (e) {
      print('FAILED ($e)');
    }
  }

  // Download material fonts and compute checksum.
  final pinnedFonts = pinned['material_fonts.zip'];
  if (pinnedFonts != null) {
    checksums['material_fonts.zip'] = pinnedFonts;
    print('  material_fonts.zip ... $pinnedFonts (pinned)');
  } else {
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
  final sysrootsRef =
      '$version:engine/src/build/linux/sysroot_scripts/sysroots.json';
  final sysrootsResult = Process.runSync(
    'git',
    ['show', sysrootsRef],
    workingDirectory: flutterRepo,
  );
  if (sysrootsResult.exitCode == 0) {
    // Read current checksums from versions.bzl so we compare against the
    // actual committed values, not hardcoded copies. Deliberately outside the
    // try below, which reports whatever it catches as a sysroots.json parse
    // failure: a versions.bzl that can't be read is a different fact.
    final currentChecksums = _readCurrentSysrootChecksums(workspaceDir);

    // The try covers the decode alone, which is the only step its message
    // describes. Reading the entries outside it is what lets them throw:
    // jsonDecode raises FormatException too, so a catch spanning both could
    // not tell a malformed file from one that simply lacks what we pin.
    Map<String, dynamic>? sysroots;
    try {
      sysroots =
          jsonDecode(sysrootsResult.stdout as String) as Map<String, dynamic>;
    } catch (e) {
      print('  WARNING: Failed to parse sysroots.json: $e');
    }

    if (sysroots != null) {
      final newChecksums = _readEngineSysrootChecksums(sysroots, sysrootsRef);
      final changed =
          newChecksums['amd64'] != currentChecksums['amd64'] ||
          newChecksums['arm64'] != currentChecksums['arm64'];
      if (changed) {
        print('  WARNING: Sysroot checksums have changed!');
        print(
          '  Update LINUX_SYSROOT_CHECKSUMS in flutter/private/versions.bzl:',
        );
        print('');
        print('LINUX_SYSROOT_CHECKSUMS = {');
        print('    "amd64": "${newChecksums['amd64']}",');
        print('    "arm64": "${newChecksums['arm64']}",');
        print('}');
      } else {
        print('  Sysroot checksums unchanged.');
      }
    }
  } else {
    print(
      '  Could not read sysroots.json for tag $version (path may differ in older Flutter versions).',
    );
  }

  _checkShaderFlags(version, flutterRepo, workspaceDir);

  // Print Starlark snippet.
  print('');
  print('=== Add to FLUTTER_VERSIONS in flutter/private/versions.bzl ===');
  print('');
  print('    "$version": struct(');
  print('        engine_revision = "$engineRev",');
  print('        framework_revision = "$frameworkRev",');
  print('        dart_version = "$dartVersion",');
  print(
    '        dart_source_sha256 = "${checksums['__dart_source__'] ?? 'FIXME'}",',
  );
  print('        material_fonts_url = "$materialFontsUrl",');
  print('        # sha256 of the GitHub source tarball. Required: every');
  print('        # fetch of the framework source is pinned against it.');
  print('        source_sha256 = "${checksums['__source__'] ?? 'FIXME'}",');
  print('    ),');
  print('');
  print(_sdkPackageEntries(version, flutterRepo));
  print('=== Add to ARTIFACT_CHECKSUMS in flutter/private/versions.bzl ===');
  print('');
  print('    "$version": {');
  for (final section in artifactSections) {
    print('        # ${section.comment}');
    for (final path in section.paths) {
      _printChecksum(checksums, path);
    }
  }
  print(
    '        # Material design fonts (MaterialIcons-Regular.otf, Roboto family)',
  );
  _printChecksum(checksums, 'material_fonts.zip');
  print('    },');
}

/// The Dart SDK version Flutter published for the stable release [version],
/// from its release listing, checked against the release's commit.
Future<String> _releasedDartVersion(String version, String frameworkRev) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(
      Uri.parse(
        'https://storage.googleapis.com/flutter_infra_release/releases/releases_macos.json',
      ),
    );
    final response = await request.close();
    if (response.statusCode != 200) {
      await response.drain<void>();
      stderr.writeln('ERROR: releases_macos.json: HTTP ${response.statusCode}');
      exit(1);
    }
    final listing =
        jsonDecode(await utf8.decodeStream(response)) as Map<String, dynamic>;
    for (final release in listing['releases'] as List<dynamic>) {
      release as Map<String, dynamic>;
      if (release['version'] == version && release['channel'] == 'stable') {
        if (release['hash'] != frameworkRev) {
          stderr.writeln(
            'ERROR: the release listing has $version at ${release['hash']}, '
            'and the local tag is at $frameworkRev.',
          );
          exit(1);
        }
        return release['dart_sdk_version'] as String;
      }
    }
    stderr.writeln('ERROR: $version is not a stable release in the listing.');
    exit(1);
  } finally {
    client.close();
  }
}

void _printChecksum(Map<String, String> checksums, String artifact) {
  final sha = checksums[artifact] ?? 'MISSING';
  print('        "$artifact": "$sha",');
}

/// A failure to produce an artifact's SHA-256, in either the download or the
/// hashing step.
///
/// A named type rather than a thrown `String`, because a raw string is neither
/// an `Exception` nor an `Error`: `on Exception` never matches one, so a caller
/// that ever catches selectively would miss these entirely. `toString` returns
/// the bare message, so the reports below print it unadorned.
class ArtifactChecksumException implements Exception {
  final String message;

  ArtifactChecksumException(this.message);

  @override
  String toString() => message;
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
    throw ArtifactChecksumException('HTTP ${response.statusCode}');
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
/// Returns a map like `{'amd64': '<sha256>', 'arm64': '<sha256>'}`, always with
/// both keys.
///
/// Throws [FileSystemException] if versions.bzl cannot be read, and
/// [FormatException] if it carries no `LINUX_SYSROOT_CHECKSUMS` block or that
/// block is missing an architecture. None of those states has a defensible
/// stand-in value: the caller compares what it gets here against the engine's
/// current checksums, so any placeholder reports "changed" — making a file this
/// tool failed to read indistinguishable from a checksum that genuinely moved,
/// at the moment that distinction matters most.
Map<String, String> _readCurrentSysrootChecksums(String workspaceDir) {
  final path = '$workspaceDir/flutter/private/versions.bzl';
  final content = File(path).readAsStringSync();

  // Bound the scan to this block's own braces, anchored at the top-level
  // assignment. Scanning from the marker to end of file instead would let any
  // later block carrying these keys overwrite the real values and win silently;
  // anchoring at line start keeps a differently-named block that merely ends in
  // this name (`OLD_LINUX_SYSROOT_CHECKSUMS`) from claiming the match.
  final block = RegExp(
    r'^LINUX_SYSROOT_CHECKSUMS\s*=\s*\{([^}]*)\}',
    multiLine: true,
  ).firstMatch(content);
  if (block == null) {
    throw FormatException('No LINUX_SYSROOT_CHECKSUMS block in $path');
  }

  // Match lines like:   "amd64": "abc123...",
  final pattern = RegExp(r'"(amd64|arm64)":\s*"([a-f0-9]+)"');
  final result = <String, String>{
    for (final match in pattern.allMatches(block.group(1)!))
      match.group(1)!: match.group(2)!,
  };

  for (final arch in const ['amd64', 'arm64']) {
    if (!result.containsKey(arch)) {
      throw FormatException(
        'No "$arch" checksum in LINUX_SYSROOT_CHECKSUMS in $path',
      );
    }
  }
  return result;
}

/// Reads the sysroot checksums we pin out of the engine's decoded sysroots.json.
///
/// Returns a map like `{'amd64': '<sha256>', 'arm64': '<sha256>'}`, always with
/// both keys — the mirror of [_readCurrentSysrootChecksums], so the caller
/// compares two complete maps and can print both lines of its suggested
/// replacement block unconditionally.
///
/// Throws [FormatException] naming [source] if either bullseye entry is absent
/// or carries no string `Sha256Sum`. An absent entry is a state upstream really
/// ships: Flutter through 3.35.x keyed this file `sid_*`, 3.38 onward
/// `bullseye_*`, and today's file already carries a `trixie_riscv64` from the
/// next such migration. So a missing entry means the sysroot generation we pin
/// moved, not that the file is corrupt — and no replacement checksum exists to
/// suggest, because the entry it would come from is gone. The keys that were
/// found go in the message, since those are the new names.
Map<String, String> _readEngineSysrootChecksums(
  Map<String, dynamic> sysroots,
  String source,
) {
  final result = <String, String>{};
  for (final arch in const ['amd64', 'arm64']) {
    final entry = sysroots['bullseye_$arch'];
    if (entry == null) {
      throw FormatException(
        'No "bullseye_$arch" entry in $source '
        '(found: ${sysroots.keys.join(', ')})',
      );
    }
    final sha = entry is Map ? entry['Sha256Sum'] : null;
    if (sha is! String) {
      throw FormatException(
        'No string "Sha256Sum" for "bullseye_$arch" in $source',
      );
    }
    result[arch] = sha;
  }
  return result;
}

Future<String> _sha256OfFile(String path) async {
  if (Platform.isWindows) {
    // certutil outputs multiple lines; the hash is on the second line.
    final result = await Process.run('certutil', ['-hashfile', path, 'SHA256']);
    if (result.exitCode != 0) {
      throw ArtifactChecksumException('certutil failed: ${result.stderr}');
    }
    final lines = (result.stdout as String).trim().split('\n');
    if (lines.length < 2) {
      throw ArtifactChecksumException('Unexpected certutil output');
    }
    return lines[1].trim().replaceAll(' ', '');
  } else {
    // macOS and Linux: use sha256sum (Linux) or shasum -a 256 (macOS).
    ProcessResult result;
    if (Platform.isMacOS) {
      result = await Process.run('shasum', ['-a', '256', path]);
    } else {
      result = await Process.run('sha256sum', [path]);
    }
    if (result.exitCode != 0) {
      throw ArtifactChecksumException('sha256 hash failed: ${result.stderr}');
    }
    return (result.stdout as String).split(' ').first;
  }
}

/// Compares `SHADER_PLATFORM_FLAGS` with the runtime stages flutter_tools at
/// [version] compiles shaders for, and says which platforms moved.
void _checkShaderFlags(String version, String flutterRepo, String workspace) {
  print('');
  print('Checking shader compile flags...');
  const toolsPath =
      'packages/flutter_tools/lib/src/build_system/tools/shader_compiler.dart';
  final shown = Process.runSync('git', [
    'show',
    '$version:$toolsPath',
  ], workingDirectory: flutterRepo);
  if (shown.exitCode != 0) {
    print('  Could not read $toolsPath at $version: ${shown.stderr}');
    return;
  }
  const bzlPath = 'flutter/private/flutter_shader_compile.bzl';
  final mismatches = shaderFlagMismatches(
    flutterToolsShaderFlags(shown.stdout as String),
    rulesShaderFlags(File('$workspace/$bzlPath').readAsStringSync()),
  );
  if (mismatches.isEmpty) {
    print('  SHADER_PLATFORM_FLAGS matches flutter_tools.');
    return;
  }
  print('  WARNING: SHADER_PLATFORM_FLAGS in $bzlPath differs from');
  print('  flutter_tools at $version. Update it to match:');
  for (final line in mismatches) {
    print('    $line');
  }
}

/// The `pubspec.yaml` of each package of `packages/` at the Flutter tag
/// [version], by package name, read from the clone at [flutterRepo].
Map<String, String> _sdkPubspecs(String version, String flutterRepo) {
  String git(List<String> args) {
    final result = Process.runSync(
      'git',
      args,
      workingDirectory: flutterRepo,
    );
    if (result.exitCode != 0) {
      stderr.writeln('ERROR: git ${args.join(' ')}: ${result.stderr}');
      exit(1);
    }
    return result.stdout as String;
  }

  final pubspecs = <String, String>{};
  for (final line in git([
    'ls-tree',
    '--name-only',
    '$version:packages',
  ]).split('\n')) {
    final package = line.trim();
    if (package.isEmpty) continue;
    final show = Process.runSync(
      'git',
      ['show', '$version:packages/$package/pubspec.yaml'],
      workingDirectory: flutterRepo,
    );
    // A directory of packages/ with no pubspec is not a package.
    if (show.exitCode == 0) pubspecs[package] = show.stdout as String;
  }
  return pubspecs;
}

/// What versions.bzl records of the SDK packages at the Flutter tag
/// [version]: their exact pins, then the packages there are.
String _sdkPackageEntries(String version, String flutterRepo) {
  final pubspecs = _sdkPubspecs(version, flutterRepo);
  return '=== Add to FLUTTER_SDK_EXACT_PINS in flutter/private/versions.bzl ===\n'
      '\n'
      '${renderPins(version, exactPins(pubspecs))}'
      '\n'
      '=== Add to FLUTTER_SDK_PACKAGES in flutter/private/versions.bzl ===\n'
      '\n'
      '${renderPackages(version, pubspecs.keys)}';
}
