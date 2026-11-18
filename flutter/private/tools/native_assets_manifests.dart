/// One native-assets manifest from those of several ABIs' builds.
///
/// An Android app's build for each ABI writes
/// `flutter_assets/NativeAssetsManifest.json` naming its own target alone
/// (`android_arm64`, say), and an APK or AAR has one `flutter_assets` for
/// every ABI. flutter_tools installs the code assets of every ABI of a build
/// at once and writes one manifest naming each ABI's target, which
/// [mergeNativeAssetsManifests] makes from the per-ABI ones.
///
/// The tool has no package dependencies and runs with the bare Dart SDK.
library;

import 'dart:convert';

/// The name of the manifest in `flutter_assets`.
const nativeAssetsManifestName = 'NativeAssetsManifest.json';

/// Why manifests cannot be merged.
final class ManifestMergeException implements Exception {
  ManifestMergeException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The manifest naming every target of [manifests], each a build's name (its
/// ABI) and its manifest's text, with the targets sorted.
///
/// Throws [ManifestMergeException] when two builds disagree on the format or
/// name one target.
String mergeNativeAssetsManifests(List<(String, String)> manifests) {
  List<Object?>? format;
  String? formatFrom;
  final targets = <String, Object?>{};
  final from = <String, String>{};
  for (final (build, text) in manifests) {
    final manifest = json.decode(text) as Map<String, Object?>;
    final version = manifest['format-version'] as List<Object?>;
    if (format != null && json.encode(format) != json.encode(version)) {
      throw ManifestMergeException(
        '$nativeAssetsManifestName has format $version in the $build build '
        'and $format in the $formatFrom build',
      );
    }
    format = version;
    formatFrom = build;
    final sections = manifest['native-assets'] as Map<String, Object?>;
    for (final MapEntry(key: target, :value) in sections.entries) {
      final other = from[target];
      if (other != null) {
        throw ManifestMergeException(
          '$nativeAssetsManifestName of both the $other and $build builds '
          'has code assets for $target',
        );
      }
      from[target] = build;
      targets[target] = value;
    }
  }
  final sorted = targets.keys.toList()..sort();
  return const JsonEncoder.withIndent('  ').convert({
    'format-version': format ?? [1, 0, 0],
    'native-assets': {for (final t in sorted) t: targets[t]},
  });
}
