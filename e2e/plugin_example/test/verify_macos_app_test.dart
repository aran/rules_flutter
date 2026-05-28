/// Runtime verification: launches the macOS .app produced by :plugin_macos
/// and asserts the four plugin-result strings appear in its stdout.
///
/// The four strings come from `lib/main.dart`'s FutureBuilder:
///   * `appName` from `PackageInfo.fromPlatform()`
///   * `documentsPath` from `getApplicationDocumentsDirectory()`
///   * `tempPath` from `getTemporaryDirectory()`
///   * `launchOk` from `canLaunchUrl(...)`
///
/// Empty/null/error content fails this test loudly.
///
/// Tagged "manual" + "exclusive" so it doesn't run in default `bazel test`
/// invocations — it requires a GUI session and accessibility-style behaviors
/// (the app launches a window and writes to its own stdout).
/// Run explicitly:
///   bazel test :verify_macos_app_test --test_tag_filters= \
///     --strategy=TestRunner=standalone
import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _summaryMarker = 'plugin_example_results';

Future<void> main() async {
  final testSrcDir = Platform.environment['TEST_SRCDIR'];
  final testWorkspace = Platform.environment['TEST_WORKSPACE'];
  if (testSrcDir == null || testWorkspace == null) {
    stderr.writeln('Missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }

  final zipPath = '$testSrcDir/$testWorkspace/plugin_macos.zip';
  if (!File(zipPath).existsSync()) {
    stderr.writeln('Bundle zip not found at $zipPath');
    exit(1);
  }

  final tmpDir = Directory.systemTemp.createTempSync('plugin_macos_test');
  try {
    final unzip = Process.runSync('unzip', ['-q', zipPath, '-d', tmpDir.path]);
    if (unzip.exitCode != 0) {
      stderr.writeln('Failed to extract zip: ${unzip.stderr}');
      exit(1);
    }

    final appPath = '${tmpDir.path}/plugin_macos.app';
    final binaryPath = '$appPath/Contents/MacOS/plugin_macos';

    if (!File(binaryPath).existsSync()) {
      stderr.writeln('FAIL: runner binary not found at $binaryPath');
      exit(1);
    }

    print('Launching $binaryPath ...');
    final process = await Process.start(binaryPath, const []);

    final summaryCompleter = Completer<String>();
    final captured = StringBuffer();

    void watch(Stream<List<int>> stream, IOSink mirror) {
      stream.transform(utf8.decoder).transform(const LineSplitter()).listen(
        (line) {
          captured.writeln(line);
          mirror.writeln(line);
          if (!summaryCompleter.isCompleted && line.contains(_summaryMarker)) {
            summaryCompleter.complete(line);
          }
        },
        onError: (Object e) {
          if (!summaryCompleter.isCompleted) {
            summaryCompleter.completeError(e);
          }
        },
      );
    }

    watch(process.stdout, stdout);
    watch(process.stderr, stderr);

    final summary = await summaryCompleter.future
        .timeout(const Duration(seconds: 30), onTimeout: () {
      return '';
    });

    process.kill();
    await process.exitCode;

    if (summary.isEmpty) {
      stderr.writeln('FAIL: $_summaryMarker line not seen within 30s');
      stderr.writeln('--- captured output ---');
      stderr.writeln(captured.toString());
      exit(1);
    }

    print('Got summary: $summary');

    final fails = <String>[];
    if (!summary.contains('appName=Plugin Example')) {
      fails.add('appName is not "Plugin Example"');
    }
    if (!RegExp(r'documentsPath=/Users/').hasMatch(summary)) {
      fails.add('documentsPath does not start with /Users/');
    }
    if (!RegExp(r'tempPath=/').hasMatch(summary)) {
      fails.add('tempPath is not an absolute path');
    }
    if (!summary.contains('launchOk=launch ok')) {
      fails.add('launchOk is not "launch ok"');
    }
    if (!summary.contains('greeting=Hello from GreetingPlugin!')) {
      fails.add('greeting (regression case) did not register');
    }
    // audio_session uses the SwiftPM-canonical
    // Sources/<pkg>/include/<pkg>/Foo.h public-header layout — exercises
    // the include-path wiring in flutter_apple_plugin_library / the
    // SwiftPM include auto-detection in flutter_pub_package.
    if (!summary.contains('audioSession=audio ok')) {
      fails.add('audioSession is not "audio ok"');
    }

    if (fails.isNotEmpty) {
      stderr.writeln('FAIL:');
      for (final f in fails) {
        stderr.writeln('  - $f');
      }
      stderr.writeln('summary line was: $summary');
      exit(1);
    }

    print('PASS');
  } finally {
    tmpDir.deleteSync(recursive: true);
  }
}
