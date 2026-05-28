/// Shared gcloud helpers for VM management.
///
/// Uses `gcloud` CLI — project and zone come from `gcloud config` defaults.
library;

import 'dart:io';

/// Credentials for the auto-logon test user on Windows VMs.
///
/// These are ephemeral SPOT VMs behind GCP IAM, auto-deleted in 24h.
const windowsTestUser = 'testuser';
const windowsTestPassword = 'FlutterTest2024';

/// Run a gcloud command and return stdout. Throws on failure.
Future<String> gcloud(List<String> args, {bool quiet = false}) async {
  if (!quiet) {
    stderr.writeln('+ gcloud ${args.join(' ')}');
  }
  final result = await Process.run('gcloud', args);
  if (result.exitCode != 0) {
    throw Exception(
      'gcloud ${args.join(' ')} failed (exit ${result.exitCode}):\n'
      '${result.stderr}',
    );
  }
  return result.stdout.toString().trim();
}

/// Get the active gcloud project.
Future<String> getProject() async {
  return gcloud(['config', 'get-value', 'project'], quiet: true);
}

/// Get the active gcloud zone.
Future<String> getZone() async {
  final zone =
      await gcloud(['config', 'get-value', 'compute/zone'], quiet: true);
  if (zone.isEmpty || zone == '(unset)') {
    throw Exception(
      'No default compute zone set. Run: gcloud config set compute/zone <zone>',
    );
  }
  return zone;
}

/// Wait for a VM to be ready (SSH-able for Linux, RDP-able for Windows).
Future<void> waitForSsh(String vmName, {Duration timeout = const Duration(minutes: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  stderr.writeln('Waiting for $vmName to accept SSH ...');
  while (DateTime.now().isBefore(deadline)) {
    try {
      await gcloud([
        'compute',
        'ssh',
        vmName,
        '--command',
        'echo ready',
        '--ssh-flag=-o',
        '--ssh-flag=ConnectTimeout=5',
        '--ssh-flag=-o',
        '--ssh-flag=StrictHostKeyChecking=no',
      ], quiet: true);
      stderr.writeln('$vmName is ready.');
      return;
    } catch (_) {
      await Future<void>.delayed(const Duration(seconds: 10));
    }
  }
  throw Exception('Timeout waiting for $vmName SSH');
}

/// SCP a local file/directory to the VM.
///
/// For large files to Windows VMs, use `--compress` to speed up transfer
/// and avoid SSH connection drops. The `--scp-flag=-O` forces the legacy
/// SCP protocol which is required for Windows OpenSSH compatibility.
Future<void> scpToVm(String vmName, String localPath, String remotePath,
    {bool compress = false}) async {
  await gcloud([
    'compute',
    'scp',
    '--recurse',
    '--scp-flag=-O',
    if (compress) '--compress',
    localPath,
    '$vmName:$remotePath',
  ]);
}

/// SCP a remote file/directory from the VM to a local path.
Future<void> scpFromVm(String vmName, String remotePath, String localPath,
    {bool compress = false}) async {
  await gcloud([
    'compute',
    'scp',
    '--recurse',
    '--scp-flag=-O',
    if (compress) '--compress',
    '$vmName:$remotePath',
    localPath,
  ]);
}

/// Runs [command] on the VM via SSH, returning trimmed stdout. Throws on a
/// non-zero exit. Use [sshExec] when the non-zero exit is meaningful.
Future<String> sshRun(String vmName, String command) async {
  return gcloud([
    'compute',
    'ssh',
    vmName,
    '--command',
    command,
  ]);
}

/// Runs [command] on the VM via SSH and returns the full [ProcessResult]
/// (stdout, stderr, exitCode) without throwing — for commands whose non-zero
/// exit is meaningful (e.g. a failing test run).
Future<ProcessResult> sshExec(String vmName, String command) {
  stderr.writeln('+ ssh $vmName: $command');
  return Process.run('gcloud', [
    'compute',
    'ssh',
    vmName,
    '--command',
    command,
  ]);
}

/// Delete a VM.
Future<void> deleteVm(String vmName) async {
  await gcloud([
    'compute',
    'instances',
    'delete',
    vmName,
    '--quiet',
  ]);
}
