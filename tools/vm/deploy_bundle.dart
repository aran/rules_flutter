/// Deploys a Flutter bundle to a GCP VM and runs visual verification.
///
/// Usage:
///   dart run tools/vm/deploy_bundle.dart <vm-name> <bundle_path> [--windows]
///
/// Linux (default):
///   1. SCPs the bundle directory to the VM
///   2. SCPs the verification scripts
///   3. Runs verify_linux_app.dart under Xvfb
///   4. Downloads the screenshot
///
/// Windows (--windows):
///   1. SCPs the bundle directory to the VM
///   2. SCPs the DXGI screenshot script
///   3. Discovers the interactive session and Python path
///   4. Runs dxgi_screenshot.py via PsExec in the interactive session
///   5. Downloads the screenshot
library;

import 'dart:io';

import 'gcloud.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln(
        'Usage: dart run tools/vm/deploy_bundle.dart <vm-name> <bundle_path> [--windows]');
    exit(1);
  }

  final vmName = args[0];
  final bundlePath = args[1];
  final isWindows = args.contains('--windows');

  if (!Directory(bundlePath).existsSync()) {
    stderr.writeln('Bundle directory not found: $bundlePath');
    exit(1);
  }

  final appName = Uri.parse(bundlePath).pathSegments.last;

  print('Deploying $appName to $vmName ...');

  if (isWindows) {
    await _deployWindows(vmName, bundlePath, appName);
  } else {
    await _deployLinux(vmName, bundlePath, appName);
  }
}

Future<void> _deployLinux(String vmName, String bundlePath, String appName) async {
  // Determine project root (for verification scripts).
  final scriptDir = Platform.script.resolve('.').toFilePath();
  final projectRoot =
      Directory(scriptDir).parent.parent.path; // tools/vm/ -> project root

  // Copy bundle to a temp dir (Bazel tree artifacts are read-only).
  print('Preparing bundle for upload ...');
  final tmpDir = Directory.systemTemp.createTempSync('deploy_');
  final tmpBundle = '${tmpDir.path}/$appName';
  await Process.run('cp', ['-RL', bundlePath, tmpBundle]);
  await Process.run('chmod', ['-R', 'u+rwX', tmpBundle]);

  // Upload bundle.
  print('Uploading bundle ...');
  await sshRun(vmName, 'chmod -R u+w ~/$appName 2>/dev/null; rm -rf ~/$appName || true');
  await scpToVm(vmName, tmpBundle, '~/$appName');
  tmpDir.deleteSync(recursive: true);

  // Upload verification scripts.
  print('Uploading verification scripts ...');
  await sshRun(vmName, 'rm -rf ~/verify_scripts; mkdir -p ~/verify_scripts');
  // SCP individual files to avoid nested directory issues.
  for (final file in Directory('$projectRoot/e2e/_linux_test').listSync()) {
    if (file is File) {
      await scpToVm(vmName, file.path, '~/verify_scripts/');
    }
  }

  // Run verification.
  print('');
  print('Running visual verification ...');
  try {
    final output = await sshRun(vmName,
        'bash -c \'export PATH="/opt/dart-sdk/bin:/usr/local/bin:\$PATH" && dart run ~/verify_scripts/verify_linux_app.dart ~/$appName "Flutter"\'');
    print(output);

    // Download screenshot if available.
    final screenshotMatch = RegExp(r'Screenshot: (/\S+)').firstMatch(output);
    if (screenshotMatch != null) {
      final remotePath = screenshotMatch.group(1)!;
      final localPath = '/tmp/${appName}_screenshot.png';
      try {
        await scpFromVm(vmName, remotePath, localPath);
        print('');
        print('Screenshot downloaded to: $localPath');
      } catch (e) {
        print('Could not download screenshot: $e');
      }
    }
  } catch (e) {
    stderr.writeln('Verification failed: $e');
    exit(1);
  }
}

Future<void> _deployWindows(String vmName, String bundlePath, String appName) async {
  final scriptDir = Platform.script.resolve('.').toFilePath();
  final projectRoot = Directory(scriptDir).parent.parent.path;

  // Check that the startup script has finished installing tools.
  print('Checking VM readiness ...');
  try {
    final status = await sshRun(vmName, 'type C:\\startup_complete.txt');
    if (!status.contains('STARTUP_COMPLETE')) {
      throw Exception('unexpected content');
    }
  } catch (_) {
    stderr.writeln('ERROR: VM startup script has not completed yet.');
    stderr.writeln('Tools (Python, PsExec, dxcam) are still installing.');
    stderr.writeln(
        'Check progress: gcloud compute ssh $vmName --command "type C:\\startup_complete.txt"');
    exit(1);
  }

  // Verify the auto-logon interactive session and get the session ID.
  // query user returns exit code 1 even on success — force exit 0.
  final sessions = await sshRun(vmName, 'query user & exit /b 0');
  final sessionMatch =
      RegExp(r'testuser\s+\S*\s+(\d+)\s+Active').firstMatch(sessions);
  if (sessionMatch == null) {
    stderr.writeln('ERROR: No active interactive session for testuser.');
    stderr.writeln('Session output:\n$sessions');
    stderr.writeln('The auto-logon may not have completed. Try rebooting the VM.');
    exit(1);
  }
  final sessionId = sessionMatch.group(1)!;
  print('VM ready. Interactive session $sessionId confirmed.');

  // Copy bundle to a temp dir (Bazel tree artifacts are symlinks / read-only).
  print('Preparing bundle for upload ...');
  final tmpDir = Directory.systemTemp.createTempSync('deploy_');
  final tmpBundle = '${tmpDir.path}/$appName';
  await Process.run('cp', ['-RL', bundlePath, tmpBundle]);

  try {
    // Upload bundle to a shared location accessible to all users.
    print('Uploading bundle ...');
    await sshRun(vmName, 'if exist C:\\temp\\$appName rmdir /s /q C:\\temp\\$appName');
    await sshRun(vmName, 'if not exist C:\\temp mkdir C:\\temp');
    await scpToVm(vmName, tmpBundle, 'C:/temp/$appName', compress: true);

    // Upload the DXGI screenshot script.
    print('Uploading verification scripts ...');
    await sshRun(vmName,
        'if exist C:\\temp\\verify_scripts rmdir /s /q C:\\temp\\verify_scripts');
    await sshRun(vmName, 'mkdir C:\\temp\\verify_scripts');
    await scpToVm(vmName, '$projectRoot/e2e/_windows_test/dxgi_screenshot.py',
        'C:/temp/verify_scripts/dxgi_screenshot.py');
  } finally {
    tmpDir.deleteSync(recursive: true);
  }

  // Discover Python path.
  final pythonPath = (await sshRun(vmName,
          'powershell -Command "(Get-ChildItem C:\\Python* -Directory | Select-Object -First 1).FullName"'))
      .trim();
  if (pythonPath.isEmpty) {
    stderr.writeln('ERROR: Python not found on VM.');
    exit(1);
  }
  print('Python: $pythonPath');

  // Find the app executable inside the bundle.
  final exeList = await sshRun(vmName,
      'powershell -Command "Get-ChildItem C:\\temp\\$appName\\*.exe | Select-Object -ExpandProperty Name"');
  final exeName = exeList.trim().split('\n').first.trim();
  if (exeName.isEmpty || !exeName.endsWith('.exe')) {
    stderr.writeln('ERROR: No .exe found in C:\\temp\\$appName\\');
    exit(1);
  }
  print('App executable: $exeName');

  // PsExec -i runs the process in the interactive session, but stdout goes
  // to that session's console, not back to SSH. Use a batch file that
  // redirects output to a file, then read the file.
  print('');
  print('Running DXGI screenshot capture ...');
  final screenshotRemotePath = 'C:\\temp\\screenshot.png';
  final outputRemotePath = 'C:\\temp\\screenshot_out.txt';

  // Write the wrapper batch file via PowerShell (avoids cmd.exe escaping).
  await sshRun(vmName,
      "powershell -Command \"Set-Content -Path C:\\temp\\run_verify.bat "
      "-Value '$pythonPath\\python.exe C:\\temp\\verify_scripts\\dxgi_screenshot.py "
      "C:\\temp\\$appName\\$exeName $screenshotRemotePath 15 "
      "> $outputRemotePath 2>&1' -Force\"");

  // Run via PsExec in the interactive session. PsExec propagates the child
  // exit code — force exit 0 so sshRun doesn't throw on screenshot failure.
  try {
    await sshRun(vmName,
        'C:\\ProgramData\\chocolatey\\bin\\PsExec64.exe -accepteula '
        '-i $sessionId -u $windowsTestUser -p $windowsTestPassword '
        'C:\\temp\\run_verify.bat & exit /b 0');
  } catch (e) {
    stderr.writeln('PsExec command failed: $e');
  }

  // Read the captured output.
  try {
    final output = await sshRun(vmName, 'type $outputRemotePath');
    print(output);

    if (output.contains('PASS')) {
      print('');
      print('Visual verification PASSED.');
    } else if (output.contains('FAIL')) {
      stderr.writeln('');
      stderr.writeln('Visual verification FAILED.');
    }
  } catch (e) {
    stderr.writeln('Could not read verification output: $e');
  }

  // Download screenshot.
  final localPath = '/tmp/${appName}_screenshot.png';
  try {
    await scpFromVm(vmName, screenshotRemotePath, localPath);
    print('');
    print('Screenshot downloaded to: $localPath');
  } catch (e) {
    print('Could not download screenshot: $e');
  }
}
