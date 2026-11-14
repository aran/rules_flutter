/// The host side of `flutter_*_integration_test`: runs the app an integration
/// test rule built and reports the suite it runs.
///
/// Started by Bazel as the test's executable, with
/// `FLUTTER_INTEGRATION_TEST_CONFIG` naming, in the runfiles, the JSON the rule
/// wrote (see `IntegrationRunnerConfig`).
import 'dart:async';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/integration/integration_runner_config.dart';
import 'package:flutter_bazel_dev_tool/integration/integration_test_run.dart';
import 'package:flutter_rule_tools/remote_suite.dart' show parseUpdateGoldens;
import 'package:runfiles/runfiles.dart';

/// Canonical name of the repository this binary is built in, which runfiles
/// paths are resolved from; set by the BUILD target.
const _runfilesSourceRepo = String.fromEnvironment('RUNFILES_SOURCE_REPO');

Future<void> main(List<String> args) async {
  final configPath = Platform.environment['FLUTTER_INTEGRATION_TEST_CONFIG'];
  if (configPath == null || configPath.isEmpty) {
    stderr.writeln(
      'integration_test: FLUTTER_INTEGRATION_TEST_CONFIG is not set. This '
      'program is the executable of a flutter_*_integration_test rule and is '
      'started by `bazel test`.',
    );
    exit(64);
  }

  final bool updateGoldens;
  try {
    updateGoldens = parseUpdateGoldens(
      args,
      Platform.environment['BUILD_WORKSPACE_DIRECTORY'],
      program: 'integration_test',
    );
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    exit(64);
  }

  final Runfiles runfiles;
  final IntegrationRunnerConfig config;
  try {
    runfiles = Runfiles.create(sourceRepository: _runfilesSourceRepo);
    final file = runfiles.rlocation(configPath);
    config = IntegrationRunnerConfig.parse(
      File(file).readAsStringSync(),
      origin: file,
    );
  } on Object catch (e) {
    stderr.writeln(
      'integration_test: cannot read the config at $configPath: '
      '${e is FormatException ? e.message : e}',
    );
    exit(64);
  }

  final DeviceChoice choice;
  try {
    choice = await chooseDevice(
      config,
      os: Platform.operatingSystem,
      resolve: runfiles.rlocation,
      environment: Platform.environment,
      log: stderr.writeln,
    );
  } on StateError catch (e) {
    stderr.writeln('integration_test: ${e.message}');
    exit(1);
  } on FormatException catch (e) {
    stderr.writeln('integration_test: ${e.message}');
    exit(64);
  }

  exitCode = await runIntegrationTest(
    config,
    resolve: runfiles.rlocation,
    choice: choice,
    environment: Platform.environment,
    updateGoldens: updateGoldens,
  );
  // The app's VM service and its log pumps are stopped by now, but a live
  // handle in a dependency would keep the process; the result is final.
  await stdout.flush();
  await stderr.flush();
  exit(exitCode);
}
