/// Verifies that the macOS bundle produced by `:hello_world_macos` ships the
/// app icon `flutter create` left in the tree.
///
/// Nothing in this workspace's BUILD file asks for one:
/// `flutter create --platforms=macos .` writes
/// `macos/Runner/Assets.xcassets/AppIcon.appiconset`, and `flutter_macos_app`
/// discovers it the same way it discovers the entitlements pair and the
/// Info.plist — so an app that has never thought about its icon ships the one
/// it already has, as `flutter build macos` does from the same tree.
///
/// Forwarding the catalog alone is not enough: `flutter create`'s
/// `Info.plist` declares `CFBundleIconFile` as an empty string for Xcode to
/// fill in, `macos_application` generates its own value from the catalog, and
/// Apple's plisttool refuses two different values for one key. The macro drops
/// the empty placeholder, which is why the value asserted below exists at all.
library;

// This script's diagnostics are its product: it reports what it found in the
// built artifact to the bazel test log, so `print` is its output channel
// rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

void main() {
  final testSrcDir = Platform.environment['TEST_SRCDIR'];
  final testWorkspace = Platform.environment['TEST_WORKSPACE'];
  if (testSrcDir == null || testWorkspace == null) {
    stderr.writeln('Missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }

  final zipPath = '$testSrcDir/$testWorkspace/hello_world_macos.zip';
  if (!File(zipPath).existsSync()) {
    stderr.writeln('Bundle zip not found at $zipPath');
    exit(1);
  }

  final tmpDir = Directory.systemTemp.createTempSync('hello_world_macos_icon_');
  try {
    final unzip = Process.runSync('unzip', ['-q', zipPath, '-d', tmpDir.path]);
    if (unzip.exitCode != 0) {
      stderr.writeln('Failed to extract zip: ${unzip.stderr}');
      exit(1);
    }

    final resources = '${tmpDir.path}/Hello World.app/Contents/Resources';
    var failed = false;

    // actool's two outputs. The `.icns` is what the Finder and the Dock read;
    // `Assets.car` is the compiled catalog the app reads at runtime. A build
    // that forwarded the catalog but never told actool which set was the app
    // icon would produce the second and not the first.
    for (final name in const ['AppIcon.icns', 'Assets.car']) {
      final file = File('$resources/$name');
      if (file.existsSync()) {
        print('OK: $name (${file.lengthSync()} bytes)');
      } else {
        stderr.writeln('FAIL: $resources/$name is missing');
        failed = true;
      }
    }

    // The key the scaffold left empty, carrying actool's value.
    final plist = Process.runSync('plutil', [
      '-convert',
      'json',
      '-o',
      '-',
      '${tmpDir.path}/Hello World.app/Contents/Info.plist',
    ], stdoutEncoding: utf8);
    if (plist.exitCode != 0) {
      stderr.writeln('FAIL: could not read Info.plist: ${plist.stderr}');
      exit(1);
    }
    final info = json.decode(plist.stdout as String) as Map<String, dynamic>;
    final iconFile = info['CFBundleIconFile'];
    if (iconFile == 'AppIcon') {
      print('OK: CFBundleIconFile = $iconFile');
    } else {
      stderr.writeln(
        'FAIL: CFBundleIconFile is ${jsonEncode(iconFile)}, expected '
        '"AppIcon". An empty string means the scaffold placeholder survived '
        'and actool never named the icon.',
      );
      failed = true;
    }

    if (failed) exit(1);
    print('PASS: the macOS bundle ships the app icon from the tree');
  } finally {
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  }
}
