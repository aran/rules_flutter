/// The `ios-tunnel` command — starts the pymobiledevice3 tunnel daemon.
///
/// This must run as root (sudo) because creating a TUN interface requires
/// elevated privileges. The tunnel daemon exposes an HTTP API on
/// 127.0.0.1:49151 that the screenshot tool uses to reach iOS devices.
import 'dart:io';

import 'runfiles_helper.dart';

/// Execute the ios-tunnel command.
///
/// Resolves the tunneld binary from runfiles (Bazel). Run the built binary
/// itself under sudo — `sudo bazel run` runs bazel as root and leaves
/// root-owned files in the output base.
Future<Never> executeTunnelCommand() async {
  // Check for root privileges.
  final uidResult = Process.runSync('id', ['-u']);
  final uid = (uidResult.stdout as String).trim();
  if (uid != '0') {
    // The path this process was started from, rather than a `bazel run` line.
    // `sudo bazel run` is the reading people take from "sudo flutter_bazel",
    // and it runs bazel itself as root: the output base fills with root-owned
    // files, and every later build by the user fails on them. Only the daemon
    // needs the privilege, so only the daemon is what sudo should reach.
    stderr.writeln(
      'This command requires root privileges — it creates a TUN interface.',
    );
    stderr.writeln('Run: sudo ${Platform.resolvedExecutable} ios-tunnel');
    stderr.writeln(
      'Not `sudo bazel run`: that runs bazel as root and leaves root-owned '
      'files in the output base, which break the builds that follow.',
    );
    exit(1);
  }

  final resolved = resolveRunfileWithManifest(
    'rules_flutter/tools/ios_screenshot/tunneld',
  );
  if (resolved == null) {
    stderr.writeln('Could not find bundled tunneld binary.');
    stderr.writeln('Build first: bazel build //tools/dev_tool:flutter_bazel');
    exit(1);
  }

  // Start the long-running daemon, forwarding all I/O.
  // The py_binary needs RUNFILES_MANIFEST_FILE to find its venv.
  //
  // PYTHONDONTWRITEBYTECODE for the same reason as the `sudo bazel run`
  // warning above: running as root, Python would write its `__pycache__`
  // directories into the runfiles tree, inside the output base, owned by
  // root. Bazel then cannot rearrange that tree, and a later build that moves
  // a Python package fails with "Error creating runfiles ... Operation not
  // permitted" until someone deletes them with sudo.
  final process = await Process.start(
    resolved.path,
    [],
    mode: ProcessStartMode.inheritStdio,
    environment: {
      if (resolved.manifestPath != null)
        'RUNFILES_MANIFEST_FILE': resolved.manifestPath!,
      'PYTHONDONTWRITEBYTECODE': '1',
    },
  );

  // Forward the daemon's exit code.
  exit(await process.exitCode);
}
