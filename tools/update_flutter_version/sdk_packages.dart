/// The packages of the Flutter SDK's source.
///
/// A Flutter SDK package of a lock is extracted from `packages/<name>` of the
/// release's source alone, so `flutter/private/versions.bzl` records, per
/// Flutter version, which packages there are (`FLUTTER_SDK_PACKAGES`).
library;

/// The entry of `FLUTTER_SDK_PACKAGES` for [version], as Starlark: the
/// [packages] of the release's `packages/`, sorted.
String renderPackages(String version, Iterable<String> packages) {
  final out = StringBuffer('    "$version": [\n');
  for (final package in packages.toList()..sort()) {
    out.writeln('        "$package",');
  }
  out.writeln('    ],');
  return out.toString();
}
