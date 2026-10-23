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
/// - `FLUTTER_TEST_EXCLUDE_TAGS` drops every test matching any of its
///   selectors, as `flutter test --exclude-tags` does. `FLUTTER_TEST_TAGS`
///   keeps only tests matching all of its selectors, as `--tags` does: several
///   entries (or comma-separated values) name the intersection, and each entry
///   is a `package:test` boolean selector (`a && b`, `a || b`, `!a`,
///   parentheses). Tags are each entry's `metadata` tags as `package:test`
///   sends them, inherited down the tree, so library-level `@Tags` on the root
///   group reach every test. Exclusion wins over inclusion.
///
///   A `--test_env` value for either key overrides the rule's `include_tags` /
///   `exclude_tags` attribute, which the rule forwards under the `_ATTR` names
///   below: Bazel lets a rule-set variable win over `--test_env` for the same
///   key, so sharing one key would make the attribute shadow the flag.
///   Presence decides — even an empty `--test_env=FLUTTER_TEST_TAGS=` clears
///   the attribute — because only presence survives the merge.
///
///   An `include_tags` attribute selection that matches no test in the suite
///   fails the run: across one target a tag name nobody carries is a typo, and
///   a suite that silently runs nothing hides it. A selection that comes only
///   from `--test_env` — one flag value applied across many targets — still
///   passes with a note when it matches nothing, as does a `--test_filter`
///   that matches nothing: most of those targets were never meant to match.
/// - `TEST_TOTAL_SHARDS`/`TEST_SHARD_INDEX` give each shard a contiguous share
///   of the tests the filter left, as `--total-shards`/`--shard-index` do.
/// - A group left with no test is dropped, and its `setUpAll`/`tearDownAll`
///   with it.
/// - Each case goes to `XML_OUTPUT_FILE` as JUnit XML, in the shape
///   `dart_test` writes.
library;

import 'dart:convert';
import 'dart:io';

import 'package:boolean_selector/boolean_selector.dart';

/// Which of a suite's tests this run executes.
class TestSelection {
  TestSelection({
    this.filter,
    this.totalShards = 1,
    this.shardIndex = 0,
    this.includeSelectors = const [],
    this.excludeSelectors = const [],
    this.includeFromAttribute = false,
  }) {
    if (totalShards < 1 || shardIndex < 0 || shardIndex >= totalShards) {
      throw FormatException(
        'shard $shardIndex of $totalShards is not a shard Bazel would ask for',
      );
    }
  }

  /// Reads Bazel's variables out of [env].
  ///
  /// `FLUTTER_TEST_TAGS` / `FLUTTER_TEST_EXCLUDE_TAGS` come from `--test_env`
  /// and override the rule's attributes, which arrive under
  /// `FLUTTER_TEST_TAGS_ATTR` / `FLUTTER_TEST_EXCLUDE_TAGS_ATTR` (see the
  /// class doc): presence decides, so an empty `--test_env` value clears the
  /// attribute rather than falling back to it.
  ///
  /// Throws [FormatException] for a filter that is not a regular expression, a
  /// tag entry that is not a boolean selector, or shard numbers that are not
  /// numbers: a run that guessed would report a selection that never happened.
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
    final include = _tagSelection(env, 'FLUTTER_TEST_TAGS');
    final exclude = _tagSelection(env, 'FLUTTER_TEST_EXCLUDE_TAGS');
    final total = env['TEST_TOTAL_SHARDS'];
    if (total == null) {
      return TestSelection(
        filter: filter,
        includeSelectors: include.selectors,
        excludeSelectors: exclude.selectors,
        includeFromAttribute: include.fromAttribute,
      );
    }
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
      includeSelectors: include.selectors,
      excludeSelectors: exclude.selectors,
      includeFromAttribute: include.fromAttribute,
    );
  }

  final RegExp? filter;
  final int totalShards;
  final int shardIndex;

  /// Only tests matching all of these `package:test` boolean selectors run,
  /// as `flutter test --tags` keeps them. Empty means tags keep everything.
  final List<BooleanSelector> includeSelectors;

  /// Tests matching any of these `package:test` boolean selectors never run,
  /// as `flutter test --exclude-tags` drops them. Wins over
  /// [includeSelectors].
  final List<BooleanSelector> excludeSelectors;

  /// Whether the include selection came from the rule's `include_tags`
  /// attribute rather than `--test_env`: the attribute names one target's
  /// tags, so a selection matching nothing is a typo and [select] fails
  /// instead of passing an empty suite. A `--test_env` value names tags
  /// across many targets, so matching nothing there still passes.
  final bool includeFromAttribute;

  /// Whether this run asked for less than the whole suite. A selection that
  /// matches nothing is then a pass, not a failure — unless it is an
  /// attribute include selection (see [includeFromAttribute]):
  /// `bazel test //... --test_filter=x` has to pass every target the filter
  /// does not touch, and a shard can draw no case at all.
  bool get narrows =>
      filter != null ||
      totalShards > 1 ||
      includeSelectors.isNotEmpty ||
      excludeSelectors.isNotEmpty;

  /// [root], a `RemoteListener` group tree, cut down to the tests this run
  /// executes. Null when none is left.
  ///
  /// Throws [FormatException] when the include selection came from the rule's
  /// attribute and no test in the suite matches it: a tag name nobody carries
  /// is a typo, and passing an empty suite would hide it. The check runs
  /// before sharding, so a shard that draws no share of a matching selection
  /// still passes.
  Map<String, dynamic>? select(Map<String, dynamic> root) {
    final found = <_Candidate>[];
    _collect(root, const {}, found);
    final matching = [
      for (final candidate in found)
        if (_keptByTags(candidate.tags) &&
            (filter?.hasMatch(candidate.test['name'] as String? ?? '') ?? true))
          candidate.test,
    ];
    if (matching.isEmpty &&
        includeFromAttribute &&
        !found.any((candidate) => _keptByInclude(candidate.tags))) {
      throw FormatException(
        'include_tags ${includeSelectors.map((s) => '"$s"').join(', ')} '
        'matches no test in this suite; check the tag spelling',
      );
    }
    final share = matching.length / totalShards;
    final start = (share * shardIndex).round();
    final end = (share * (shardIndex + 1)).round();
    // By identity, and over the entries as decoded: a `cast` view is a new
    // object each time, so two walks would never find each other's.
    final chosen = Set<Map<Object?, Object?>>.identity()
      ..addAll(matching.sublist(start, end));
    return _prune(root, chosen);
  }

  /// Whether a test carrying [tags] survives this run's include selection:
  /// every include selector must match, as `flutter test --tags` intersects
  /// them.
  bool _keptByInclude(Set<String> tags) =>
      includeSelectors.every((s) => s.evaluate(tags.contains));

  /// Whether a test carrying [tags] survives this run's tag selection:
  /// dropped when any exclude selector matches, kept only when every include
  /// selector matches. Exclusion wins, as `flutter test` resolves it.
  bool _keptByTags(Set<String> tags) {
    if (excludeSelectors.any((s) => s.evaluate(tags.contains))) return false;
    if (!_keptByInclude(tags)) return false;
    return true;
  }

  /// One comma-separated tag selection as `package:test` boolean selectors:
  /// entries split on commas, whitespace trimmed, empty entries dropped, so
  /// `golden, slow` and `golden,,slow,` select the same intersection.
  /// Several entries mean ALL of them, each a boolean selector (`a && b`,
  /// `a || b`, `!a`, parentheses), as `flutter test --tags` intersects them.
  ///
  /// Throws [FormatException] naming [key] and the offending entry when one
  /// is not a boolean selector.
  static List<BooleanSelector> _parseTagSelectors(String? raw, String key) {
    if (raw == null || raw.isEmpty) return const [];
    final selectors = <BooleanSelector>[];
    for (final part in raw.split(',')) {
      final expression = part.trim();
      if (expression.isEmpty) continue;
      try {
        selectors.add(BooleanSelector.parse(expression));
      } on FormatException catch (e) {
        throw FormatException(
          '$key "$expression" is not a boolean tag selector: ${e.message}',
        );
      }
    }
    return selectors;
  }

  /// The tag selection for [key] (`FLUTTER_TEST_TAGS` or
  /// `FLUTTER_TEST_EXCLUDE_TAGS`): the `--test_env` value when present, else
  /// the rule's attribute under `<key>_ATTR`. Presence decides, so an empty
  /// `--test_env` value clears the attribute.
  static ({List<BooleanSelector> selectors, bool fromAttribute}) _tagSelection(
    Map<String, String> env,
    String key,
  ) {
    if (env.containsKey(key)) {
      return (
        selectors: _parseTagSelectors(env[key], key),
        fromAttribute: false,
      );
    }
    final selectors = _parseTagSelectors(env['${key}_ATTR'], key);
    return (selectors: selectors, fromAttribute: selectors.isNotEmpty);
  }

  /// The `tags` `package:test` reports in [entry]'s `metadata`, or none when
  /// the entry carries none. Groups and tests alike carry them; the caller
  /// unions them down the tree.
  static Set<String> _tagsOf(Map<Object?, Object?> entry) {
    final metadata = entry['metadata'];
    if (metadata is! Map) return const {};
    final tags = metadata['tags'];
    if (tags is! List) return const {};
    return {
      for (final tag in tags)
        if (tag is String) tag,
    };
  }

  static void _collect(
    Map<Object?, Object?> group,
    Set<String> inherited,
    List<_Candidate> into,
  ) {
    final own = {...inherited, ..._tagsOf(group)};
    for (final entry in group['entries'] as List? ?? const []) {
      final m = entry as Map<Object?, Object?>;
      if (m['type'] == 'group') {
        _collect(m, own, into);
      } else {
        into.add(_Candidate(m, {...own, ..._tagsOf(m)}));
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

/// One test in a `RemoteListener` tree with the tags it inherits: its own
/// `metadata` tags plus every enclosing group's, root included.
class _Candidate {
  _Candidate(this.test, this.tags);

  final Map<Object?, Object?> test;
  final Set<String> tags;
}

/// The suite's library-level `@Tags`, extracted at build time over the test's
/// `main` (`extract_library_tags.dart`) and named by `FLUTTER_TEST_LIBRARY_TAGS`.
///
/// The runner sends these in the `RemoteListener` initial message, where they
/// become the root group's metadata and every test inherits them — the way
/// `test_core` hands `parseMetadata`'s result to the test isolate. Empty when
/// the rule sets no file, so a hand-run runner still works.
///
/// Throws [FormatException] when the file is missing or malformed: a run that
/// guessed at the suite's tags would report a selection that never happened.
Set<String> readLibraryTags(
  Map<String, String> env,
  String Function(String) rlocation,
) {
  final key = env['FLUTTER_TEST_LIBRARY_TAGS'];
  if (key == null || key.isEmpty) return const {};
  final file = File(rlocation(key));
  if (!file.existsSync()) {
    throw FormatException(
      'FLUTTER_TEST_LIBRARY_TAGS names "$key", which is not in runfiles',
    );
  }
  final decoded = json.decode(file.readAsStringSync());
  if (decoded is! Map || decoded['tags'] is! List) {
    throw FormatException(
      'FLUTTER_TEST_LIBRARY_TAGS names "$key", which does not hold '
      '{"tags": [...]}',
    );
  }
  return {
    for (final tag in decoded['tags'] as List)
      if (tag is String) tag,
  };
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
