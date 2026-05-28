/// Verifies the macOS .app bundle produced by flutter_macos_app has the
/// expected structure, including the native dylib and App.framework,
/// and is correctly wired for rendering (Info.plist, symbols, linkage, assets).
///
/// rules_apple outputs a .zip — we extract it to a temp dir and verify.
import 'dart:io';

void main() {
  final testSrcDir = Platform.environment['TEST_SRCDIR'];
  final testWorkspace = Platform.environment['TEST_WORKSPACE'];
  if (testSrcDir == null || testWorkspace == null) {
    stderr.writeln('Missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }

  final zipPath = '$testSrcDir/$testWorkspace/app.zip';
  if (!File(zipPath).existsSync()) {
    stderr.writeln('Bundle zip not found at $zipPath');
    exit(1);
  }

  // Extract to temp directory.
  final tmpDir = Directory.systemTemp.createTempSync('macos_bundle_test');
  try {
    final result =
        Process.runSync('unzip', ['-q', zipPath, '-d', tmpDir.path]);
    if (result.exitCode != 0) {
      stderr.writeln('Failed to extract zip: ${result.stderr}');
      exit(1);
    }

    // flutter_macos_app sets bundle_name = app_name, so the .app is named
    // after the display name, not the Bazel target name.
    final bundlePath = '${tmpDir.path}/Flutter App.app';
    final runnerBinary = '$bundlePath/Contents/MacOS/Flutter App';
    var failed = false;

    void check(String description, String path) {
      final exists =
          FileSystemEntity.isDirectorySync(path) || File(path).existsSync();
      if (!exists) {
        stderr.writeln('FAIL: $description — not found: $path');
        failed = true;
      } else {
        print('OK: $description');
      }
    }

    void checkCommand(String description, String executable, List<String> args,
        bool Function(String stdout) validate) {
      final result = Process.runSync(executable, args);
      if (result.exitCode != 0) {
        stderr.writeln(
            'FAIL: $description — command failed: $executable ${args.join(' ')}');
        stderr.writeln('  stderr: ${result.stderr}');
        failed = true;
        return;
      }
      final stdout = result.stdout.toString().trim();
      if (!validate(stdout)) {
        stderr.writeln('FAIL: $description — unexpected output: $stdout');
        failed = true;
      } else {
        print('OK: $description');
      }
    }

    // --- Structural checks (file existence) ---

    check(
      'Native dylib libadd.dylib exists',
      '$bundlePath/Contents/Frameworks/libadd.dylib',
    );
    check(
      'App.framework exists',
      '$bundlePath/Contents/Frameworks/App.framework',
    );
    check(
      'FlutterMacOS.framework exists',
      '$bundlePath/Contents/Frameworks/FlutterMacOS.framework',
    );
    check(
      'Runner binary exists',
      runnerBinary,
    );
    check(
      'Info.plist exists',
      '$bundlePath/Contents/Info.plist',
    );
    check(
      'MainMenu.nib exists',
      '$bundlePath/Contents/Resources/Base.lproj/MainMenu.nib',
    );
    check(
      'flutter_assets in App.framework',
      '$bundlePath/Contents/Frameworks/App.framework/Resources/flutter_assets',
    );

    // --- Info.plist validation ---

    checkCommand(
      'Info.plist NSMainNibFile is MainMenu',
      'plutil',
      ['-extract', 'NSMainNibFile', 'raw', '$bundlePath/Contents/Info.plist'],
      (stdout) => stdout == 'MainMenu',
    );

    checkCommand(
      'Info.plist CFBundleExecutable is Flutter App',
      'plutil',
      [
        '-extract',
        'CFBundleExecutable',
        'raw',
        '$bundlePath/Contents/Info.plist'
      ],
      (stdout) => stdout == 'Flutter App',
    );

    checkCommand(
      'Info.plist CFBundleName is Flutter App',
      'plutil',
      ['-extract', 'CFBundleName', 'raw', '$bundlePath/Contents/Info.plist'],
      (stdout) => stdout == 'Flutter App',
    );

    // --- NIB class references ---

    checkCommand(
      'MainMenu.nib references AppDelegate class',
      'strings',
      ['$bundlePath/Contents/Resources/Base.lproj/MainMenu.nib'],
      (stdout) => stdout.contains('AppDelegate'),
    );

    // --- ObjC class symbols in runner binary ---

    // flutter-create Swift files don't use @objc annotations, so class symbols
    // are Swift-mangled: _OBJC_CLASS_$__TtC6Runner11AppDelegate.
    checkCommand(
      'Runner binary exports AppDelegate ObjC class',
      'nm',
      ['-gU', runnerBinary],
      (stdout) => stdout.contains('AppDelegate'),
    );

    checkCommand(
      'Runner binary exports MainFlutterWindow ObjC class',
      'nm',
      ['-gU', runnerBinary],
      (stdout) => stdout.contains('MainFlutterWindow'),
    );

    // --- Framework linkage ---

    checkCommand(
      'Runner binary links FlutterMacOS.framework',
      'otool',
      ['-L', runnerBinary],
      (stdout) => stdout.contains('FlutterMacOS.framework'),
    );

    // --- AOT dylib (App.framework/App) is valid Mach-O ---

    final appFrameworkBinary =
        '$bundlePath/Contents/Frameworks/App.framework/App';
    check('App.framework/App binary exists', appFrameworkBinary);

    checkCommand(
      'App.framework/App is valid Mach-O',
      'file',
      [appFrameworkBinary],
      (stdout) => stdout.contains('Mach-O'),
    );

    // --- flutter_assets completeness ---

    final assetsPath =
        '$bundlePath/Contents/Frameworks/App.framework/Resources/flutter_assets';
    check('AssetManifest.bin exists', '$assetsPath/AssetManifest.bin');
    check('FontManifest.json exists', '$assetsPath/FontManifest.json');
    check('shaders/ directory exists', '$assetsPath/shaders');

    if (failed) {
      stderr.writeln('Bundle contents:');
      _listRecursive(bundlePath, '');
      exit(1);
    }

    print('All macOS bundle verification checks passed.');
  } finally {
    tmpDir.deleteSync(recursive: true);
  }
}

void _listRecursive(String path, String indent) {
  final dir = Directory(path);
  if (!dir.existsSync()) return;
  for (final entity in dir.listSync()) {
    final name = entity.path.split('/').last;
    stderr.writeln('$indent$name');
    if (entity is Directory && !name.endsWith('.framework')) {
      _listRecursive(entity.path, '$indent  ');
    }
  }
}
