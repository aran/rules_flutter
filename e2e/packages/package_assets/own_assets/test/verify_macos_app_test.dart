/// Runtime verification: launches the macOS .app and checks that the running
/// program called its code asset and read its data asset with `rootBundle`.
///
/// Needs a GUI session (an unlocked screen), so it is tagged `manual`. Run it
/// with `bazel test //package_assets/own_assets:verify_macos_app_test --test_tag_filters=
/// --strategy=TestRunner=standalone`.
///
/// The app is launched by its `Contents/MacOS/<exe>` and followed by the PID
/// this test started, as `e2e/macos_example`'s runtime test explains.
///
/// Pass criteria: the app prints `native_assets_synthetic
/// canary=0x42424242 blob=native-assets-synthetic-data-blob-v1`, which `main()`
/// prints after loading both, before `runApp`.
library;

// This script's diagnostics are its product: it reports what it found in
// the built artifact to the bazel test log, so `print` is its output
// channel rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:rules_flutter_e2e_testing/app_process.dart';
import 'package:rules_flutter_e2e_testing/macos_bundle.dart';
import 'package:rules_flutter_e2e_testing/macos_gui_session.dart';

const _marker = 'native_assets_synthetic canary=';
const _expected =
    '${_marker}0x42424242 blob=native-assets-synthetic-data-blob-v1';

Future<void> main() async {
  final bundle = MacosBundle.fromRunfiles(
    'package_assets/own_assets/macos_app.zip',
    appName: 'Native Assets Synthetic',
    prefix: 'synthetic_app_test',
  );
  AppProcess? app;
  final gui = await GuiSession.hold();
  try {
    final launched = app = await AppProcess.start(bundle.runner);
    // Bounded because an app whose asset failed to resolve may never print.
    final line =
        await launched.waitForLine(
          _marker,
          timeout: const Duration(seconds: 30),
        ) ??
        '';
    print('The app printed: ${line.isEmpty ? "nothing" : line}');
    if (!line.contains(_expected)) {
      stderr.writeln(
        'FAIL: expected the app to print "$_expected": a code asset did not '
        'load, or the data asset is not in the bundle under its key',
      );
      launched.dumpOutput();
      exit(1);
    }
    print('PASS');
  } finally {
    await app?.stop();
    bundle.dispose();
    await gui.release();
  }
}
