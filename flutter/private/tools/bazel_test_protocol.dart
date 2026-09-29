/// Bazel's test protocol, for a suite `flutter_test_runner.dart` runs by
/// walking `package:test`'s tree itself.
///
/// `dart_test` gets the same behaviour by running `package:test`'s own runner
/// (`--name`, `--total-shards`/`--shard-index`, a JSON reporter converted to
/// JUnit). `flutter_test` speaks the `RemoteListener` protocol directly, so it
/// applies those rules here, the way that runner applies them:
///
/// - `TESTBRIDGE_TEST_ONLY` (`--test_filter`) is a regular expression matched
///   against each test's full name, as `--name` is.
/// - `TEST_TOTAL_SHARDS`/`TEST_SHARD_INDEX` give each shard a contiguous share
///   of the tests the filter left, as `--total-shards`/`--shard-index` do.
/// - A group left with no test is dropped, and its `setUpAll`/`tearDownAll`
///   with it.
/// - Each case goes to `XML_OUTPUT_FILE` as JUnit XML, in the shape
///   `dart_test` writes.
library;

/// Which of a suite's tests this run executes.
class TestSelection {
  TestSelection({this.filter, this.totalShards = 1, this.shardIndex = 0}) {
    if (totalShards < 1 || shardIndex < 0 || shardIndex >= totalShards) {
      throw FormatException(
        'shard $shardIndex of $totalShards is not a shard Bazel would ask for',
      );
    }
  }

  /// Reads Bazel's variables out of [env].
  ///
  /// Throws [FormatException] for a filter that is not a regular expression or
  /// shard numbers that are not numbers: a run that guessed would report a
  /// selection that never happened.
  factory TestSelection.fromEnvironment(Map<String, String> env) {
    final pattern = env['TESTBRIDGE_TEST_ONLY'];
    RegExp? filter;
    if (pattern != null && pattern.isNotEmpty) {
      try {
        filter = RegExp(pattern);
      } on FormatException catch (e) {
        throw FormatException(
          '--test_filter "$pattern" is not a regular expression: ${e.message}',
        );
      }
    }
    final total = env['TEST_TOTAL_SHARDS'];
    if (total == null) return TestSelection(filter: filter);
    final totalShards = int.tryParse(total);
    final shardIndex = int.tryParse(env['TEST_SHARD_INDEX'] ?? '');
    if (totalShards == null || shardIndex == null) {
      throw FormatException(
        'TEST_TOTAL_SHARDS "$total" and TEST_SHARD_INDEX '
        '"${env['TEST_SHARD_INDEX']}" must both be numbers',
      );
    }
    return TestSelection(
      filter: filter,
      totalShards: totalShards,
      shardIndex: shardIndex,
    );
  }

  final RegExp? filter;
  final int totalShards;
  final int shardIndex;

  /// Whether this run asked for less than the whole suite. A selection that
  /// matches nothing is then a pass, not a failure: `bazel test //...
  /// --test_filter=x` has to pass every target the filter does not touch, and
  /// a shard can draw no case at all.
  bool get narrows => filter != null || totalShards > 1;

  /// [root], a `RemoteListener` group tree, cut down to the tests this run
  /// executes. Null when none is left.
  Map<String, dynamic>? select(Map<String, dynamic> root) {
    final all = <Map<Object?, Object?>>[];
    _collect(root, all);
    final matching = [
      for (final test in all)
        if (filter?.hasMatch(test['name'] as String? ?? '') ?? true) test,
    ];
    final share = matching.length / totalShards;
    final start = (share * shardIndex).round();
    final end = (share * (shardIndex + 1)).round();
    // By identity, and over the entries as decoded: a `cast` view is a new
    // object each time, so two walks would never find each other's.
    final chosen = Set<Map<Object?, Object?>>.identity()
      ..addAll(matching.sublist(start, end));
    return _prune(root, chosen);
  }

  static void _collect(
    Map<Object?, Object?> group,
    List<Map<Object?, Object?>> into,
  ) {
    for (final entry in group['entries'] as List? ?? const []) {
      final m = entry as Map<Object?, Object?>;
      if (m['type'] == 'group') {
        _collect(m, into);
      } else {
        into.add(m);
      }
    }
  }

  static Map<String, dynamic>? _prune(
    Map<Object?, Object?> group,
    Set<Map<Object?, Object?>> chosen,
  ) {
    final kept = <Object?>[];
    for (final entry in group['entries'] as List? ?? const []) {
      final m = entry as Map<Object?, Object?>;
      if (m['type'] == 'group') {
        final child = _prune(m, chosen);
        if (child != null) kept.add(child);
      } else if (chosen.contains(m)) {
        kept.add(m);
      }
    }
    if (kept.isEmpty) return null;
    return {...group.cast<String, dynamic>(), 'entries': kept};
  }
}

/// One case's outcome, for the JUnit report.
class TestCaseResult {
  TestCaseResult.passed(this.name, this.elapsed, this.output)
    : skipped = false,
      failureType = null,
      message = null,
      detail = null;

  TestCaseResult.skipped(this.name)
    : skipped = true,
      elapsed = Duration.zero,
      output = '',
      failureType = null,
      message = null,
      detail = null;

  TestCaseResult.failed(
    this.name,
    this.elapsed,
    this.output, {
    required String this.failureType,
    required String this.message,
    required String this.detail,
  }) : skipped = false;

  final String name;
  final Duration elapsed;
  final String output;
  final bool skipped;

  /// `TestFailure` for a failed expectation, anything else for an error;
  /// JUnit keeps the two apart, as `package:test`'s reporters do.
  final String? failureType;
  final String? message;
  final String? detail;
}

/// [cases] as JUnit XML, one `testsuite` named [suiteName] — the shape
/// `dart_test` writes, so one parser reads both.
String junitXml(List<TestCaseResult> cases, {required String suiteName}) {
  String seconds(Duration d) =>
      (d.inMicroseconds / Duration.microsecondsPerSecond).toStringAsFixed(3);
  bool isFailure(TestCaseResult c) => c.failureType == 'TestFailure';
  final failures = cases.where((c) => c.failureType != null && isFailure(c));
  final errors = cases.where((c) => c.failureType != null && !isFailure(c));
  final skipped = cases.where((c) => c.skipped);
  final total = cases.fold(Duration.zero, (sum, c) => sum + c.elapsed);

  final out = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<testsuites>')
    ..writeln(
      '  <testsuite name="${_attr(suiteName)}" tests="${cases.length}" '
      'failures="${failures.length}" errors="${errors.length}" '
      'skipped="${skipped.length}" time="${seconds(total)}">',
    );
  for (final c in cases) {
    out.write(
      '    <testcase name="${_attr(c.name)}" '
      'classname="${_attr(suiteName)}" time="${seconds(c.elapsed)}">',
    );
    if (c.skipped) {
      out.write('<skipped/>');
    } else if (c.failureType != null) {
      final tag = isFailure(c) ? 'failure' : 'error';
      out.write(
        '<$tag message="${_attr(c.message!.split('\n').first)}">'
        '${_text(c.detail!)}</$tag>',
      );
    }
    if (c.output.isNotEmpty) {
      out.write('<system-out>${_text(c.output)}</system-out>');
    }
    out.writeln('</testcase>');
  }
  out
    ..writeln('  </testsuite>')
    ..writeln('</testsuites>');
  return out.toString();
}

String _text(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

String _attr(String s) => _text(s).replaceAll('"', '&quot;');
