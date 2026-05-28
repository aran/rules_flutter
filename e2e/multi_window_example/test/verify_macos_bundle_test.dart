/// Verifies the macOS .app bundle produced by the multi-window example has the
/// expected structure: two-window runner with FlutterEngineGroup, App.framework,
/// FlutterMacOS.framework, and correct ObjC class symbols.
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

  final zipPath = '$testSrcDir/$testWorkspace/app_macos.zip';
  if (!File(zipPath).existsSync()) {
    stderr.writeln('Bundle zip not found at $zipPath');
    exit(1);
  }

  final tmpDir = Directory.systemTemp.createTempSync('multi_window_bundle_test');
  try {
    final result =
        Process.runSync('unzip', ['-q', zipPath, '-d', tmpDir.path]);
    if (result.exitCode != 0) {
      stderr.writeln('Failed to extract zip: ${result.stderr}');
      exit(1);
    }

    final bundlePath = '${tmpDir.path}/Planner.app';
    final runnerBinary = '$bundlePath/Contents/MacOS/Planner';
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

    // --- Structural checks ---

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
      '$bundlePath/Contents/Resources/MainMenu.nib',
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
      'Info.plist CFBundleName is Planner',
      'plutil',
      ['-extract', 'CFBundleName', 'raw', '$bundlePath/Contents/Info.plist'],
      (stdout) => stdout == 'Planner',
    );

    // --- ObjC class symbols in runner binary (single nm invocation) ---

    {
      final nmResult = Process.runSync('nm', ['-gU', runnerBinary]);
      if (nmResult.exitCode != 0) {
        stderr.writeln('FAIL: nm -gU failed: ${nmResult.stderr}');
        failed = true;
      } else {
        final symbols = nmResult.stdout.toString();
        for (final sym in ['AppDelegate', 'TasksWindow', 'CalendarWindow']) {
          if (!symbols.contains(sym)) {
            stderr.writeln('FAIL: Runner binary missing ObjC class $sym');
            failed = true;
          } else {
            print('OK: Runner binary exports $sym ObjC class');
          }
        }
      }
    }

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

    print('All multi-window macOS bundle verification checks passed.');
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
