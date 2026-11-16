/// The golden service as a process of the host.
///
/// The service is a `flutter_test` (`flutter/private/goldens/service.dart`), so
/// it is started as one is started by Bazel: as its rule's executable, with
/// the environment its rule says. What the integration test itself was given
/// by Bazel is not its to read: the test's filter, shard and report belong to
/// the test.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../process_group.dart';
import 'golden_comparator.dart';

/// What Bazel hands a test about its own run, which the golden service is not:
/// its selection of cases (`--test_filter`, and the `DART_TEST_TAGS` and
/// `DART_TEST_EXCLUDE_TAGS` a run narrows by tag with), its shard, and where it
/// reports. A service that took them would select none of its own one case, or
/// write over the report.
const _belongsToTheTest = [
  'TESTBRIDGE_TEST_ONLY',
  'DART_TEST_TAGS',
  'DART_TEST_EXCLUDE_TAGS',
  'TEST_TOTAL_SHARDS',
  'TEST_SHARD_INDEX',
  'TEST_SHARD_STATUS_FILE',
  'XML_OUTPUT_FILE',
  'COVERAGE_OUTPUT_FILE',
];

/// The variable that tells the service to write goldens, not compare them.
const goldenServiceUpdateVariable = 'FLUTTER_TEST_UPDATE_GOLDENS';

/// The environment to start the golden service with: the host's, so that it
/// finds the runfiles and the test's undeclared outputs directory and, under
/// `bazel run`, the source tree, without what is the test's own; with what its
/// rule says ([service]); and [update] when goldens are to be written.
Map<String, String> goldenServiceEnvironment(
  Map<String, String> host,
  Map<String, String> service, {
  required bool update,
}) => {
  for (final entry in host.entries)
    if (!_belongsToTheTest.contains(entry.key)) entry.key: entry.value,
  ...service,
  if (update) goldenServiceUpdateVariable: '1',
};

/// Starts [executable] with exactly [environment]; its output is its stdout's
/// and its stderr's lines, as each comes.
///
/// Off Windows it leads a process group of its own, which
/// [RunningGoldenService.kill] kills whole. The service is a `flutter_test`
/// runner, and the `flutter_tester` it starts writes straight into the runner's
/// stdout and stderr: killed alone, the runner would leave the tester running
/// and holding the pipes, and the service's output would never end. [binary] is
/// the label of the program starting it, whose runfiles hold the helper that
/// makes the group (see `process_group.dart`).
Future<RunningGoldenService> startGoldenServiceProcess(
  String executable,
  Map<String, String> environment, {
  required String binary,
}) async {
  if (Platform.isWindows) {
    return _ProcessService(
      await Process.start(
        executable,
        const [],
        environment: environment,
        includeParentEnvironment: false,
      ),
      inGroup: false,
    );
  }
  return _ProcessService(
    await startInProcessGroup(
      executable,
      const [],
      binary: binary,
      environment: environment,
      includeParentEnvironment: false,
    ),
    inGroup: true,
  );
}

class _ProcessService implements RunningGoldenService {
  _ProcessService(this._process, {required bool inGroup}) : _inGroup = inGroup {
    var open = 2;
    for (final stream in [_process.stdout, _process.stderr]) {
      stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            _output.add,
            onDone: () {
              if (--open == 0) _output.close();
            },
          );
    }
  }

  final Process _process;

  /// Whether [_process] leads a process group of its own.
  final bool _inGroup;
  final _output = StreamController<String>();

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  Stream<String> get output => _output.stream;

  @override
  void kill() => _inGroup
      ? signalProcessGroup(_process, ProcessSignal.sigkill)
      : _process.kill(ProcessSignal.sigkill);
}
