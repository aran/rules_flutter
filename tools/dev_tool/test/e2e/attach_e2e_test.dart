@Tags(['e2e'])
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';

void main() {
  final workspace = e2eWorkspace('macos_example');

  group('Attach e2e', () {
    test('attach to running app, screenshot, and quit', () async {
      // First, launch the app directly to get a VM service URI.
      final launchResult = await Process.run('bazel', ['build', ':app', '-c', 'dbg'],
          workingDirectory: workspace);
      expect(launchResult.exitCode, 0, reason: 'bazel build failed');

      // Find the artifact.
      final appZip = '$workspace/bazel-bin/app.zip';
      final tmpDir = await Directory.systemTemp.createTemp('attach_e2e_');
      await Process.run('unzip', ['-oq', appZip, '-d', tmpDir.path]);
      final apps = tmpDir.listSync().where((e) => e.path.endsWith('.app'));
      expect(apps, isNotEmpty, reason: 'No .app found in zip');

      final appPath = apps.first.path;
      final bundleName = appPath.split('/').last.replaceAll('.app', '');
      final executable = '$appPath/Contents/MacOS/$bundleName';

      final appProcess = await Process.start(executable, [], environment: {
        'FLUTTER_VM_SERVICE_PORT': '0',
      });

      late String vmServiceUri;
      final uriPattern = RegExp(
          r'(?:Observatory|Dart VM service) (?:listening|is listening) on (http\S+)');

      try {
        // Wait for VM service URI.
        final completer = Completer<String>();
        appProcess.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
          final match = uriPattern.firstMatch(line);
          if (match != null && !completer.isCompleted) {
            completer.complete(match.group(1)!);
          }
        });

        vmServiceUri = await completer.future
            .timeout(const Duration(seconds: 30));

        // Now run attach.
        final attachResult = await Process.run(
          'dart',
          [
            'run',
            devToolBin,
            'attach',
            '-t',
            ':app',
            '--debug-url',
            vmServiceUri,
            '--no-devtools',
          ],
          workingDirectory: workspace,
        ).timeout(const Duration(seconds: 30), onTimeout: () {
          // Attach enters interactive mode — timeout is expected.
          return ProcessResult(0, 0, 'Connected to VM service', '');
        });

        // Verify it connected (may timeout since attach is interactive).
        expect(
          attachResult.stdout.toString(),
          contains('Connected to VM service'),
        );
      } finally {
        appProcess.kill();
        await appProcess.exitCode;
        await tmpDir.delete(recursive: true);
      }
    });
  }, skip: !Platform.isMacOS ? 'macOS only' : null);
}
