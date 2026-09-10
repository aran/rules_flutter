/// The Dart version this repo's own toolchain resolves to.
///
/// A VM that runs any of this repo's Dart — the dev tool's e2e suite most of
/// all — needs an SDK matching what the build uses. Pinning that as a literal
/// here means two homes for one version, and a VM whose SDK has drifted below
/// the suite's floor fails only when someone tries to run it there.
///
/// Asking Bazel removes the second home. `@rules_dart//dart` is the *resolved*
/// toolchain's SDK — the same binary the build compiles with — so bumping
/// `dart/private/versions.bzl` in rules_dart moves the VMs with it and there is
/// nothing here to forget.
library;

import 'dart:io';

/// The version string of the SDK `@rules_dart//dart` resolves to, e.g. `3.13.2`.
Future<String> hermeticDartVersion() async {
  final workspace = await _workspace();
  final result = await Process.run('bazel', [
    'run',
    '--ui_event_filters=-info,-stdout',
    '--noshow_progress',
    '@rules_dart//dart',
    '--',
    '--version',
  ], workingDirectory: workspace);
  if (result.exitCode != 0) {
    throw Exception(
      'could not ask @rules_dart//dart for its version (exit '
      '${result.exitCode}). Run it by hand to see why:\n'
      '  bazel run @rules_dart//dart -- --version\n'
      '${result.stderr}',
    );
  }
  // `dart --version` has written to stdout on some SDKs and stderr on others,
  // and which one is not worth depending on.
  final output = '${result.stdout}\n${result.stderr}';
  final match = RegExp(
    r'Dart SDK version:\s*(\d+\.\d+\.\d+)',
  ).firstMatch(output);
  if (match == null) {
    throw Exception(
      '@rules_dart//dart answered without a version this understands:\n$output',
    );
  }
  return match.group(1)!;
}

/// The Bazel workspace root.
///
/// `BUILD_WORKSPACE_DIRECTORY` when Bazel set it, and otherwise whatever
/// `bazel info workspace` says from the current directory — never a walk up
/// from `Directory.current`, which finds the wrong root inside a nested
/// workspace and silently uses it.
Future<String> _workspace() async {
  final fromBazel = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (fromBazel != null && fromBazel.isNotEmpty) return fromBazel;
  final result = await Process.run('bazel', ['info', 'workspace']);
  if (result.exitCode != 0) {
    throw Exception(
      'not inside a Bazel workspace: `bazel info workspace` exited '
      '${result.exitCode}. Run this script from the repo root.\n'
      '${result.stderr}',
    );
  }
  return result.stdout.toString().trim();
}
