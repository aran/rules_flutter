/// Reads the checksums already pinned for a version in versions.bzl.
///
/// The updater reuses them instead of downloading an archive it has already
/// hashed, so re-running it for a version only fetches what was added since.
library;

/// The `"path": "sha256"` entries of [version]'s block in `ARTIFACT_CHECKSUMS`,
/// or an empty map when versions.bzl has no such block.
Map<String, String> pinnedArtifactChecksums(
  String versionsBzl,
  String version,
) {
  final start = RegExp(
    r'^ARTIFACT_CHECKSUMS\s*=\s*\{',
    multiLine: true,
  ).firstMatch(versionsBzl);
  if (start == null) return {};
  final block = RegExp(
    '^    "${RegExp.escape(version)}": \\{\n(.*?)^    \\},',
    multiLine: true,
    dotAll: true,
  ).firstMatch(versionsBzl.substring(start.end));
  if (block == null) return {};
  return {
    for (final m in RegExp(
      r'^\s*"([^"]+)":\s*"([0-9a-f]{64})",',
      multiLine: true,
    ).allMatches(block.group(1)!))
      m.group(1)!: m.group(2)!,
  };
}

/// The `source_sha256` pinned for [version] in `FLUTTER_VERSIONS`, or null.
String? pinnedSourceSha256(String versionsBzl, String version) {
  final block = RegExp(
    '^    "${RegExp.escape(version)}": struct\\((.*?)^    \\),',
    multiLine: true,
    dotAll: true,
  ).firstMatch(versionsBzl);
  if (block == null) return null;
  return RegExp(
    r'(?<![a-z_])source_sha256\s*=\s*"([0-9a-f]{64})"',
  ).firstMatch(block.group(1)!)?.group(1);
}

/// The `dart_source_sha256` recorded for [version] in versions.bzl, or null:
/// the checksum of the Dart SDK source tarball the outline stripper is built
/// from, so a re-run reuses it instead of downloading the tarball again.
String? pinnedDartSourceSha256(String versionsBzl, String version) {
  final block = RegExp(
    '^    "${RegExp.escape(version)}": struct\\((.*?)^    \\),',
    multiLine: true,
    dotAll: true,
  ).firstMatch(versionsBzl);
  if (block == null) return null;
  return RegExp(
    r'dart_source_sha256\s*=\s*"([0-9a-f]{64})"',
  ).firstMatch(block.group(1)!)?.group(1);
}

/// The pins of `IOS_USB_DEPENDENCIES` in versions.bzl: each archive's name to
/// its `version` and `sha256`. A re-run reuses the digest of an archive whose
/// revision the new release has not moved.
Map<String, ({String version, String sha256})> pinnedIosUsbDependencies(
  String versionsBzl,
) {
  final block = RegExp(
    r'^IOS_USB_DEPENDENCIES\s*=\s*\{\n(.*?)^\}',
    multiLine: true,
    dotAll: true,
  ).firstMatch(versionsBzl);
  if (block == null) return {};
  return {
    for (final m in RegExp(
      r'"([^"]+)":\s*struct\(\s*version\s*=\s*"([^"]+)",\s*'
      r'sha256\s*=\s*"([0-9a-f]{64})",\s*\)',
    ).allMatches(block.group(1)!))
      m.group(1)!: (version: m.group(2)!, sha256: m.group(3)!),
  };
}

/// The URL of one iOS USB dependency archive, from the template
/// `ios_usb_dependency_url` in artifact_urls.bzl formats, so the two cannot
/// drift. Throws when the file no longer has the template.
String iosUsbDependencyUrl(
  String artifactUrlsBzl,
  String name,
  String version,
) {
  final template = RegExp(
    r'^_IOS_USB_DEPENDENCY_TEMPLATE\s*=\s*"([^"]+)"',
    multiLine: true,
  ).firstMatch(artifactUrlsBzl);
  if (template == null) {
    throw StateError(
      'flutter/private/artifact_urls.bzl has no _IOS_USB_DEPENDENCY_TEMPLATE',
    );
  }
  return template
      .group(1)!
      .replaceAll('{name}', name)
      .replaceAll('{version}', version);
}
