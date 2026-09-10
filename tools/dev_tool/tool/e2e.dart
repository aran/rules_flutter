/// Runs the dev_tool e2e suite and refuses to call a run that did not happen a
/// pass.
///
/// ```sh
/// dart run tools/dev_tool/tool/e2e.dart                      # the whole suite
/// dart run tools/dev_tool/tool/e2e.dart --plain-name="macOS" # scoped
/// dart run tools/dev_tool/tool/e2e.dart test/e2e/agent_e2e_test.dart
/// ```
///
/// Arguments are forwarded to `dart test`; any positional one replaces the
/// default `test/e2e/` path.
///
/// ## Why this exists rather than a bare `dart test`
///
/// `dart test` has three ways to finish without running the suite, and only two
/// of them are loud:
///
/// | condition                                     | exit | verdict    |
/// |---|---|---|
/// | version solving fails (runner too old)        | 65   | loud       |
/// | nothing selected (`--tags`/`-n` match none)   | 79   | loud       |
/// | **every selected test skipped**               | **0**| **silent** |
///
/// The third is the hole. `dart test` prints `All tests skipped.` and exits 0,
/// so a suite that ran nothing is indistinguishable — to CI, to a sweep script,
/// to an agent — from one that passed. It is reachable rather than theoretical:
/// most of the e2e files are `skip:`-gated on `Platform.isMacOS`, so the whole
/// of each one "passes" having executed nothing on any other host.
///
/// This runner closes the hole by reading the machine-readable result stream
/// rather than the exit code: it counts the tests that actually *ran* and fails
/// when that count is zero, when any test failed, or when the runner never
/// reached its own verdict.
///
/// It also removes the reason the exit code gets lost in the first place. The
/// documented recipes are long pipelines (`caffeinate -d dart test … | tee`),
/// and a shell reports the *tail* of a pipeline: `dart test … | head -3` after
/// a version-solving failure leaves `$?` at 0 with `PIPESTATUS` at `65 0`. A
/// reader who judges by what scrolled past sees no failing test names and calls
/// it green. Here the verdict is the last thing printed, in words.
///
/// ## Why it also asserts its own version
///
/// The suite is executed by whatever `dart` invoked this script, and that is
/// not a property of this repo. `tools/dev_tool` depends on `dwds`, which needs
/// SDK >= 3.12, so an older `dart` cannot run the suite at all. Checking
/// [Platform.version] up front turns that into one sentence naming the wrong
/// `dart` and the fix, instead of `package:test`'s version-solving wall.
///
/// The suite then runs on [Platform.resolvedExecutable] — this very VM — so the
/// version that was checked is necessarily the version that runs. `PATH` is
/// never consulted, so it cannot disagree.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The floor `dwds` imposes on the whole package. Read off `pubspec.lock`'s
/// `dart: ">=3.12.0-307.0.dev <4.0.0"`, which is where the real constraint
/// lives — `pubspec.yaml` only says `^3.0.0`.
const _minRunnerVersion = (major: 3, minor: 12);

/// The path used when the caller names none.
const _defaultPath = 'test/e2e/';

/// Flags the suite always needs. `--concurrency=1` because every test drives
/// real builds, devices and windows; `--tags=e2e` because those are the only
/// tagged files and the unit tests already have Bazel targets.
const _alwaysArgs = ['--tags=e2e', '--concurrency=1'];

Future<void> main(List<String> args) async {
  final runner = _RunnerVersion.current();
  if (!runner.meetsFloor) {
    _fail(
      'this suite needs Dart ${_minRunnerVersion.major}.'
      '${_minRunnerVersion.minor} or newer, and you are on $runner.\n'
      '  the dart that would have run it: ${Platform.resolvedExecutable}\n'
      '\n'
      'tools/dev_tool depends on dwds, which requires SDK >= 3.12, so the '
      'suite cannot run on this VM at all — `dart test` would have failed '
      'version solving before loading a single file. Put the pinned Flutter '
      "toolchain's dart first:\n"
      '\n'
      '  export PATH="\$(ls -d "\$(bazel info output_base)"'
      '/external/*flutter+flutter_*/dart-sdk/bin | head -1):\$PATH"',
    );
  }

  final packageDir = _packageDir();
  // Forwarded verbatim and in order — splitting flags from positionals would
  // tear `--plain-name occluded` in half, since the value carries no leading
  // dash. The default path is supplied only when the caller named nothing that
  // could be one; when they did, `dart test` resolves it, and when they passed
  // a flag value that merely looks positional it falls back to `test/`, where
  // `--tags=e2e` still selects these files and nothing else.
  final testArgs = [
    'test',
    if (!args.any((a) => !a.startsWith('-'))) _defaultPath,
    ..._alwaysArgs,
    ...args,
  ];

  stderr.writeln('e2e: ${Platform.resolvedExecutable} ($runner)');
  stderr.writeln('e2e: ${packageDir.path}\$ dart ${testArgs.join(' ')}');

  final outcome = await _runSuite(packageDir, testArgs);
  outcome.report();
  exit(outcome.ok ? 0 : 1);
}

/// The directory holding `pubspec.yaml`, derived from this script's own
/// location so the runner works from any cwd.
Directory _packageDir() {
  final dir = File(Platform.script.toFilePath()).parent.parent;
  final pubspec = File('${dir.path}/pubspec.yaml');
  if (!pubspec.existsSync()) {
    _fail(
      'expected ${pubspec.path} to exist — this script has to stay in '
      'tools/dev_tool/tool/.',
    );
  }
  return dir;
}

Future<Outcome> _runSuite(Directory packageDir, List<String> testArgs) async {
  final process = await Process.start(
    Platform.resolvedExecutable,
    [...testArgs, '--reporter', 'json'],
    workingDirectory: packageDir.path,
  );
  // The runner's own diagnostics — version solving, load errors, a test's own
  // prints — arrive here, and when the JSON stream stops early this is the only
  // place that says why. Relayed line by line rather than with `addStream`,
  // which would bind `stderr` and make this runner's own writes throw
  // `StreamSink is bound to a stream` the moment a test reported anything.
  final outcome = Outcome();
  await Future.wait([
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach(stderr.writeln),
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach(outcome.consume),
  ]);
  outcome.runnerExitCode = await process.exitCode;
  return outcome;
}

/// Accumulates the `package:test` JSON event stream into a verdict.
///
/// The contract used here, from `package:test`'s json reporter: every test
/// emits `testStart` then `testDone`; `testDone` carries
/// `result` (`success` / `failure` / `error`), `skipped` (true for both a
/// declaration-time `skip:` and a runtime `markTestSkipped`), and `hidden`
/// (true for the synthetic "loading <file>" entries, which are not tests). A
/// `done` event closes a run that reached its own end — note it reports
/// `success: true` for both of the run-nothing cases, which is exactly why the
/// counts below, and not `done`, decide the verdict.
class Outcome {
  final _names = <int, String>{};
  final _errors = <String, List<String>>{};

  /// Why each test skipped, keyed by test id while the run is in flight and
  /// re-keyed by name once it finishes.
  ///
  /// The reporter says this twice and in two shapes, so both are read: a
  /// declaration-time `skip: '<reason>'` arrives on `testStart` as
  /// `test.metadata.skipReason`, and both that and a runtime
  /// `markTestSkipped` arrive as a `print` event carrying
  /// `messageType: "skip"`. Metadata wins where there is one, because the
  /// print prefixes it with `Skip: `.
  final _skipReasons = <int, String>{};
  final _skipReasonByName = <String, String>{};

  /// Tests that executed and reported success. **Not** "tests that ran" — a
  /// test that ran and failed is in [failed], and the two together are
  /// [executed]. The distinction is not cosmetic: reading this list as
  /// "everything that ran" makes a run whose only test failed report itself as
  /// a selection mistake.
  final passed = <String>[];
  final skipped = <String>[];
  final failed = <String>[];

  /// Null when the runner never emitted its terminal `done` event — it died,
  /// or never started, partway through. That is a failure whatever the counts
  /// say, because the counts are then a prefix of an unknown whole.
  bool? runnerVerdict;
  int runnerExitCode = -1;

  void consume(String line) {
    if (!line.startsWith('{')) {
      // Not JSON: the runner is talking to a human — a version-solving wall, a
      // load error. Relay it; the stream is usually about to stop and this text
      // is the only reason given.
      if (line.trim().isNotEmpty) stderr.writeln(line);
      return;
    }
    final Object? decoded;
    try {
      decoded = json.decode(line);
    } on FormatException {
      stderr.writeln(line);
      return;
    }
    if (decoded is! Map<String, dynamic>) return;

    switch (decoded['type']) {
      case 'testStart':
        final test = decoded['test'] as Map<String, dynamic>;
        final id = test['id'] as int;
        _names[id] = test['name'] as String;
        final metadata = test['metadata'];
        if (metadata is Map<String, dynamic>) {
          final reason = metadata['skipReason'];
          if (reason is String) _skipReasons[id] = reason;
        }
      case 'testDone':
        if (decoded['hidden'] == true) return;
        final id = decoded['testID'] as int;
        final name = _names[id] ?? '<unnamed>';
        if (decoded['skipped'] == true) {
          skipped.add(name);
          final reason = _skipReasons[id];
          if (reason != null) _skipReasonByName[name] = reason;
          stderr.writeln('  ~ $name');
        } else if (decoded['result'] == 'success') {
          passed.add(name);
          stderr.writeln('  + $name');
        } else {
          failed.add(name);
          stderr.writeln('  ! $name (${decoded['result']})');
        }
      case 'print':
        // A test's own `print` is zone-captured by the runner and delivered
        // here, not on the child's stderr, so it is invisible unless relayed.
        // These are the lines that explain a long silent stretch between two
        // `+`s, which on a suite whose tests take minutes each is most of what
        // there is to watch.
        //
        // A `markTestSkipped` reason arrives only here — there is no metadata
        // for it, because the test was not declared skipped — so it is picked
        // up on the way past.
        final printedFor = decoded['testID'];
        if (decoded['messageType'] == 'skip' && printedFor is int) {
          final said = decoded['message'];
          if (said is String) _skipReasons.putIfAbsent(printedFor, () => said);
        }
        stderr.writeln('    ${decoded['message']}');
      case 'error':
        // What a failure actually *said*. The `testDone` event carries only a
        // verdict, so without this a failing test reduces to its name — less
        // than the default reporter gives.
        final name = _names[decoded['testID'] as int] ?? '<unnamed>';
        _errors
            .putIfAbsent(name, () => [])
            .add(
              '${decoded['error']}\n${decoded['stackTrace']}'.trimRight(),
            );
      case 'done':
        runnerVerdict = decoded['success'] as bool?;
    }
  }

  /// How many tests actually executed, whatever they then reported.
  ///
  /// This — not [passed] — is what says whether the suite *ran*. A failing
  /// test executed just as much as a passing one; only a skip did not.
  int get executed => passed.length + failed.length;

  /// A run counts only when the runner reached its own verdict, nothing failed,
  /// and at least one test passed.
  ///
  /// That last clause matters: `dart test` exits 0 when every
  /// selected test skipped, so "no failures" alone cannot tell a pass from a
  /// suite that never ran.
  bool get ok => runnerVerdict == true && failed.isEmpty && passed.isNotEmpty;

  /// Each name followed by whatever it reported, indented under it.
  String _indented(Iterable<String> names) => names
      .map(
        (n) =>
            '  $n\n'
            '${(_errors[n] ?? const <String>[]).map((e) => '${e.split('\n').map((l) => '    $l').join('\n')}\n').join()}',
      )
      .join();

  /// The one count line, always printed.
  String get summary =>
      'e2e: ${passed.length} passed, ${skipped.length} '
      'skipped, ${failed.length} failed (dart test exited $runnerExitCode)';

  /// Why this run is not a pass, or null when it is one — exactly the negation
  /// of [ok], so the two can never disagree.
  ///
  /// Separate from [report] so the verdict can be asserted on: a branch ending
  /// in `exit(1)` would kill the process asserting it.
  ///
  /// The branch order is load-bearing. The two "did anything happen" questions
  /// are asked against [executed] rather than [passed], because a run whose
  /// only test failed has `passed.isEmpty` — and asking those questions of
  /// [passed] answers "nothing was selected to run … Check the paths, --tags
  /// and -n you passed", with the failure it has just printed sitting directly
  /// above. `1 failed + 2 skipped` reaches the same defect by the other branch,
  /// reporting "all 2 of them skipped".
  String? get diagnosis {
    if (ok) return null;

    if (runnerVerdict == null) {
      return 'the test runner never reported a verdict; it exited '
          '$runnerExitCode partway through. Read its output above — the '
          '$executed test(s) that did run are a prefix of an unknown '
          'whole, and none of this is a pass.';
    }
    if (executed == 0 && skipped.isEmpty) {
      return 'nothing was selected to run (dart test exited '
          '$runnerExitCode). Check the paths, --tags and -n you passed.';
    }
    if (executed == 0) {
      return 'not one test actually ran — all ${skipped.length} of them '
          'skipped. `dart test` exits 0 for this, which is why it needs '
          'saying: this is not a pass, it is a suite that never executed. '
          'The skip reasons are above; on macOS the usual cause is a missing '
          'Screen Recording or Accessibility permission, and off macOS it is '
          'that most of this suite is macOS-only.';
    }
    if (failed.isEmpty) {
      // The runner declared failure without any test carrying it. A test that
      // throws *after* its own `testDone` — a stray async error, a late
      // teardown — arrives exactly this way: an error event and a failing
      // `done`, with nothing to attribute it to.
      return 'the run failed without a failing test — something threw outside '
          'a test\'s own lifetime:\n${_indented(_errors.keys)}';
    }
    return '${failed.length} test(s) failed:\n${_indented(failed)}';
  }

  /// One line per skipped test, each carrying why it skipped.
  ///
  /// The reason is the whole content of a skip. Without it the summary says a
  /// platform's tests did not run and nothing about whether that was a bench
  /// with nothing plugged into it or a detector that had stopped working. The
  /// reasons do appear in the live stream as `Skip:` lines, but on a suite
  /// whose tests take minutes each those are thousands of lines above the
  /// summary, which is the part anyone reads.
  ///
  /// A getter rather than writes inside [report] so it can be asserted on,
  /// for the same reason [diagnosis] is one.
  Iterable<String> get skipReport => skipped.map((name) {
    final why = _skipReasonByName[name];
    return 'e2e: skipped — $name${why == null ? '' : ' — $why'}';
  });

  void report() {
    stderr.writeln('');
    for (final line in skipReport) {
      stderr.writeln(line);
    }
    stderr.writeln(summary);
    final why = diagnosis;
    if (why != null) _fail(why);
  }
}

/// The version of the VM executing this script.
class _RunnerVersion {
  final int major;
  final int minor;
  final String raw;

  _RunnerVersion(this.major, this.minor, this.raw);

  /// [Platform.version] is `<semver> (<channel>) (<date>) on "<os>"`.
  factory _RunnerVersion.current() {
    final raw = Platform.version;
    final match = RegExp(r'^(\d+)\.(\d+)').firstMatch(raw);
    if (match == null) {
      _fail('could not read a version out of Platform.version: "$raw".');
    }
    return _RunnerVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      raw,
    );
  }

  bool get meetsFloor =>
      major > _minRunnerVersion.major ||
      (major == _minRunnerVersion.major && minor >= _minRunnerVersion.minor);

  @override
  String toString() => raw.split(' ').first;
}

Never _fail(String message) {
  stderr.writeln('');
  stderr.writeln('e2e: $message');
  exit(1);
}
