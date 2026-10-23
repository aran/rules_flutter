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
  //
  // The driver reads no runfiles (its program is embedded, its Python is the
  // host's), so unlike the old py_binary it needs no RUNFILES_MANIFEST_FILE.
  //
  // PYTHONDONTWRITEBYTECODE stays: running as root, Python would otherwise
  // write `__pycache__` next to the user's installed pymobiledevice3, owned by
  // root. Nothing of ours lives in the runfiles tree any more, so the old
  // root-owned-output-base failure is gone either way.
  final process = await Process.start(
    resolved.path,
    [],
    mode: ProcessStartMode.inheritStdio,
    environment: {
      'PYTHONDONTWRITEBYTECODE': '1',
    },
  );

  // Forward the daemon's exit code.
  exit(await process.exitCode);
}
