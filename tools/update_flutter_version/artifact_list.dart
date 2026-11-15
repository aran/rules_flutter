/// The engine artifacts rules_flutter downloads, grouped as they are printed
/// into `ARTIFACT_CHECKSUMS` in flutter/private/versions.bzl.
///
/// Paths are relative to
/// `https://storage.googleapis.com/flutter_infra_release/flutter/<engine_revision>/`.
/// `flutter/tests/versions_test.bzl` fails when a path the repository rules
/// download is missing from versions.bzl, so a new download is added here too.
library;

class ArtifactSection {
  /// The comment printed above the section's entries.
  final String comment;
  final List<String> paths;

  const ArtifactSection(this.comment, this.paths);
}

const artifactSections = [
  ArtifactSection('Patched Dart SDK for Flutter (debug + product)', [
    'flutter_patched_sdk.zip',
    'flutter_patched_sdk_product.zip',
  ]),
  // The patched SDKs serve the compiler, which reads kernel dills; the
  // analyzer reads sources, and finds them through lib/_embedder.yaml.
  ArtifactSection(
    'Dart SDK sources for the analyzer (dart:ui and friends, via lib/_embedder.yaml)',
    ['sky_engine.zip'],
  ),
  ArtifactSection(
    'Host Dart SDK (the Flutter-bundled Dart SDK per host platform)',
    [
      'dart-sdk-darwin-arm64.zip',
      'dart-sdk-darwin-x64.zip',
      'dart-sdk-linux-x64.zip',
      'dart-sdk-linux-arm64.zip',
      'dart-sdk-windows-x64.zip',
    ],
  ),
  ArtifactSection('Host tools (frontend_server, gen_snapshot, icudtl.dat)', [
    'darwin-arm64/artifacts.zip',
    'darwin-x64/artifacts.zip',
    'linux-x64/artifacts.zip',
    'linux-arm64/artifacts.zip',
    'windows-x64/artifacts.zip',
  ]),
  // Only macOS publishes separate release host tools archives. On Linux and
  // Windows the release gen_snapshot is bundled in the desktop engine archive.
  ArtifactSection(
    'Release host tools (macOS only — product-mode gen_snapshot for AOT builds)',
    ['darwin-arm64-release/artifacts.zip', 'darwin-x64-release/artifacts.zip'],
  ),
  ArtifactSection(
    'Profile host tools (macOS only — profile-mode gen_snapshot for AOT builds)',
    ['darwin-arm64-profile/artifacts.zip', 'darwin-x64-profile/artifacts.zip'],
  ),
  ArtifactSection(
    'Font-subset tool (the font-subset binary for icon tree shaking)',
    [
      'darwin-arm64/font-subset.zip',
      'darwin-x64/font-subset.zip',
      'linux-x64/font-subset.zip',
      'linux-arm64/font-subset.zip',
      'windows-x64/font-subset.zip',
    ],
  ),
  ArtifactSection('Flutter web SDK', ['flutter-web-sdk.zip']),
  ArtifactSection('Desktop engine runtime libraries (release mode)', [
    'darwin-x64-release/FlutterMacOS.framework.zip',
    'linux-x64-release/linux-x64-flutter-gtk.zip',
    'linux-arm64-release/linux-arm64-flutter-gtk.zip',
    'windows-x64-release/windows-x64-flutter.zip',
  ]),
  ArtifactSection('Desktop engine runtime libraries (profile mode)', [
    'darwin-x64-profile/FlutterMacOS.framework.zip',
    'linux-x64-profile/linux-x64-flutter-gtk.zip',
    'linux-arm64-profile/linux-arm64-flutter-gtk.zip',
    'windows-x64-profile/windows-x64-flutter.zip',
  ]),
  ArtifactSection(
    'Desktop engine runtime libraries (debug mode — JIT, needed for -c dbg)',
    [
      'darwin-x64/FlutterMacOS.framework.zip',
      'linux-x64-debug/linux-x64-flutter-gtk.zip',
      'linux-arm64-debug/linux-arm64-flutter-gtk.zip',
      'windows-x64-debug/windows-x64-flutter.zip',
    ],
  ),
  ArtifactSection(
    "macOS add-to-app (Flutter's signed FlutterMacOS.xcframework per mode)",
    [
      'darwin-x64/framework.zip',
      'darwin-x64-profile/framework.zip',
      'darwin-x64-release/framework.zip',
    ],
  ),
  ArtifactSection(
    'iOS engine (Flutter.xcframework — release and profile for device, debug for simulator)',
    [
      'ios-release/artifacts.zip',
      'ios-profile/artifacts.zip',
      'ios/artifacts.zip',
    ],
  ),
  ArtifactSection(
    'Android engine (flutter.jar — release and profile for AOT, debug for JIT)',
    [
      'android-arm-release/artifacts.zip',
      'android-arm64-release/artifacts.zip',
      'android-x64-release/artifacts.zip',
      'android-arm-profile/artifacts.zip',
      'android-arm64-profile/artifacts.zip',
      'android-x64-profile/artifacts.zip',
      'android-arm/artifacts.zip',
      'android-arm64/artifacts.zip',
      'android-x64/artifacts.zip',
    ],
  ),
  // The gen_snapshot that runs on the build host and targets Android. Flutter
  // publishes x64 hosts only; arm64 hosts run the x64 binary.
  ArtifactSection('Android cross-compile gen_snapshot (release)', [
    'android-arm-release/darwin-x64.zip',
    'android-arm-release/linux-x64.zip',
    'android-arm-release/windows-x64.zip',
    'android-arm64-release/darwin-x64.zip',
    'android-arm64-release/linux-x64.zip',
    'android-arm64-release/windows-x64.zip',
    'android-x64-release/darwin-x64.zip',
    'android-x64-release/linux-x64.zip',
    'android-x64-release/windows-x64.zip',
  ]),
  ArtifactSection('Android cross-compile gen_snapshot (profile)', [
    'android-arm-profile/darwin-x64.zip',
    'android-arm-profile/linux-x64.zip',
    'android-arm-profile/windows-x64.zip',
    'android-arm64-profile/darwin-x64.zip',
    'android-arm64-profile/linux-x64.zip',
    'android-arm64-profile/windows-x64.zip',
    'android-x64-profile/darwin-x64.zip',
    'android-x64-profile/linux-x64.zip',
    'android-x64-profile/windows-x64.zip',
  ]),
  ArtifactSection('C++ client wrapper (Windows — flutter/plugin_registry.h)', [
    'windows-x64/flutter-cpp-client-wrapper.zip',
  ]),
];

/// Every artifact path, in print order.
final artifacts = [for (final section in artifactSections) ...section.paths];
