/// Verifies that the `.ipa` built from `:app` ships the app icon
/// `flutter create` left in the tree.
///
/// Nothing in this workspace's BUILD file asks for one:
/// `flutter create --platforms=ios .` writes
/// `ios/Runner/Assets.xcassets/AppIcon.appiconset`, and `flutter_ios_app`
/// discovers it the same way it discovers `Runner.entitlements` and the launch
/// storyboard — so an app that has never thought about its icon ships the one
/// it already has, as `flutter build ios` does from the same tree.
library;

// This script's diagnostics are its product: it reports what it found in the
// built artifact to the bazel test log, so `print` is its output channel
// rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:io';

void main() {
  final testSrcDir = Platform.environment['TEST_SRCDIR'];
  final testWorkspace = Platform.environment['TEST_WORKSPACE'];
  if (testSrcDir == null || testWorkspace == null) {
    stderr.writeln('Missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }

  final ipaPath = '$testSrcDir/$testWorkspace/app.ipa';
  if (!File(ipaPath).existsSync()) {
    stderr.writeln('IPA not found at $ipaPath');
    exit(1);
  }

  final tmpDir = Directory.systemTemp.createTempSync('ios_app_icon_');
  try {
    final unzip = Process.runSync('unzip', ['-q', ipaPath, '-d', tmpDir.path]);
    if (unzip.exitCode != 0) {
      stderr.writeln('Failed to extract IPA: ${unzip.stderr}');
      exit(1);
    }

    final app = Directory('${tmpDir.path}/Payload/app.app');
    if (!app.existsSync()) {
      stderr.writeln('FAIL: .app not found at ${app.path}');
      exit(1);
    }

    var failed = false;

    // The compiled catalog, which is what a build that forwarded the icons as
    // plain resources would also produce.
    final car = File('${app.path}/Assets.car');
    if (car.existsSync()) {
      print('OK: Assets.car (${car.lengthSync()} bytes)');
    } else {
      stderr.writeln('FAIL: ${car.path} is missing');
      failed = true;
    }

    // And the loose `AppIcon*.png` variants actool writes only when it has
    // been told which set is the *app icon* — a distinction `resources` alone
    // cannot make.
    final icons =
        app
            .listSync()
            .whereType<File>()
            .map((f) => f.uri.pathSegments.last)
            .where((n) => n.startsWith('AppIcon') && n.endsWith('.png'))
            .toList()
          ..sort();
    if (icons.isNotEmpty) {
      print('OK: ${icons.join(', ')}');
    } else {
      stderr.writeln(
        'FAIL: no AppIcon*.png in the bundle. actool compiled the catalog '
        'without being told which set is the app icon.',
      );
      failed = true;
    }

    if (failed) exit(1);
    print('PASS: the iOS bundle ships the app icon from the tree');
  } finally {
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  }
}
