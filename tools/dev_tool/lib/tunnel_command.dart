/// The `ios-tunnel` command — starts the pymobiledevice3 tunnel daemon.
///
/// This must run as root (sudo) because creating a TUN interface requires
/// elevated privileges. The tunnel daemon exposes an HTTP API on
/// 127.0.0.1:49151 that the screenshot tool uses to reach iOS devices.
import 'dart:io';

import 'runfiles_helper.dart';

/// Execute the ios-tunnel command.
///
/// Resolves the tunneld binary from runfiles (Bazel).
/// Requires `sudo bazel-bin/tools/dev_tool/flutter_bazel ios-tunnel`.
Future<Never> executeTunnelCommand() async {
  // Check for root privileges.
  final uidResult = Process.runSync('id', ['-u']);
  final uid = (uidResult.stdout as String).trim();
  if (uid != '0') {
    stderr.writeln('This command requires root privileges.');
    stderr.writeln('Run: sudo flutter_bazel ios-tunnel');
    exit(1);
  }

  final resolved =
      resolveRunfileWithManifest('rules_flutter/tools/ios_screenshot/tunneld');
  if (resolved == null) {
    stderr.writeln('Could not find bundled tunneld binary.');
    stderr.writeln(
        'Build first: bazel build //tools/dev_tool:flutter_bazel');
    exit(1);
  }

  // Start the long-running daemon, forwarding all I/O.
  // The py_binary needs RUNFILES_MANIFEST_FILE to find its venv.
  final process = await Process.start(
    resolved.path,
    [],
    mode: ProcessStartMode.inheritStdio,
    environment: {
      if (resolved.manifestPath != null)
        'RUNFILES_MANIFEST_FILE': resolved.manifestPath!,
    },
  );

  // Forward the daemon's exit code.
  exit(await process.exitCode);
}
