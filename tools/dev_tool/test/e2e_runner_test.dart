/// Tests for the e2e suite runner's verdict — `tool/e2e.dart`.
///
/// The runner exists to make "this run did not happen" impossible to mistake
/// for "this run passed", so the thing worth testing is not that it counts,
/// but that the sentence it prints matches what actually occurred. Driven
/// through [Outcome.consume] with synthetic `package:test` JSON-reporter
/// lines rather than by setting fields, so these cases also pin the reporter
/// contract the class documents: `skipped` wins over `result`, a skipped test
/// reports `result: "success"`, and `hidden` entries are not tests.
library;

import 'dart:convert';

import 'package:test/test.dart';

import '../tool/e2e.dart';

/// Feeds one run's worth of events into a fresh [Outcome].
///
/// [tests] is name → outcome, where the outcome is one of `pass`, `fail` or
/// `skip`. [verdict] is what `dart test` itself declared; null means the
/// runner died before saying — no `done` event at all.
Outcome runOf(
  Map<String, String> tests, {
  bool? verdict = true,
  int exitCode = 0,
}) {
  final outcome = Outcome();
  var id = 0;
  tests.forEach((name, result) {
    id++;
    outcome.consume(
      json.encode({
        'type': 'testStart',
        'test': {'id': id, 'name': name},
      }),
    );
    outcome.consume(
      json.encode({
        'type': 'testDone',
        'testID': id,
        // A skipped test reports success in this stream, for backwards
        // compatibility. Encoding that here matters: a reader that trusts
        // `result` alone counts every skip as a pass.
        'result': result == 'fail' ? 'failure' : 'success',
        'skipped': result == 'skip',
        'hidden': false,
      }),
    );
  });
  if (verdict != null) {
    outcome.consume(json.encode({'type': 'done', 'success': verdict}));
  }
  outcome.runnerExitCode = exitCode;
  return outcome;
}

/// Feeds a run of cases in files into a fresh [Outcome] that was given
/// [selection].
///
/// [cases] is file → name → `pass`, `fail` or `skip`; a skipped case carries
/// the reason `host` in the stream, as a `skip:` on `Platform.isMacOS` does.
Outcome runIn(
  Selection selection,
  Map<String, Map<String, String>> cases, {
  Set<String>? declaredTags,
  int exitCode = 0,
}) {
  final outcome = Outcome(selection: selection, declaredTags: declaredTags);
  var suite = 0;
  var id = 0;
  cases.forEach((file, tests) {
    outcome.consume(
      json.encode({
        'type': 'suite',
        'suite': {'id': ++suite, 'platform': 'vm', 'path': file},
      }),
    );
    tests.forEach((name, result) {
      id++;
      outcome.consume(
        json.encode({
          'type': 'testStart',
          'test': {
            'id': id,
            'suiteID': suite,
            'name': name,
            'metadata': {
              'skip': result == 'skip',
              'skipReason': result == 'skip' ? 'not on this host' : null,
            },
          },
        }),
      );
      outcome.consume(
        json.encode({
          'type': 'testDone',
          'testID': id,
          'result': result == 'fail' ? 'failure' : 'success',
          'skipped': result == 'skip',
          'hidden': false,
        }),
      );
    });
  });
  outcome.consume(json.encode({'type': 'done', 'success': true}));
  outcome.runnerExitCode = exitCode;
  return outcome;
}

/// The selection `dart test`'s [args] make in the package at `/pkg/`, whose
/// `test/e2e/` is the one directory.
Selection selecting(List<String> args) => Selection.parse(
  args,
  Uri.directory('/pkg'),
  isDirectory: (path) => path.endsWith('/'),
);

void main() {
  group('Selection.parse', () {
    test('tells paths from the values of options', () {
      final selection = selecting([
        'test/e2e/a_e2e_test.dart',
        '--plain-name',
        'macOS',
        '-n',
        'reload|restart',
        '-Nattach',
        '--tags=web',
        '-t',
        'macos && web',
        '-x',
        'android',
        '--exclude-tags',
        'ios_sim',
        '--timeout',
        '10m',
        '--no-retry',
        'test/e2e/',
      ]);

      expect(selection.paths.map((p) => p.path), [
        '/pkg/test/e2e/a_e2e_test.dart',
        '/pkg/test/e2e/',
      ]);
      expect(selection.paths.map((p) => p.directory), [false, true]);
      expect(selection.plainNames, ['macOS', 'attach']);
      expect(selection.names, ['reload|restart']);
      expect(selection.tags, ['web', 'macos && web']);
    });

    test('names the file of a file with a query', () {
      final selection = selecting(['test/e2e/a_e2e_test.dart?name=reload']);

      expect(selection.paths.single.path, '/pkg/test/e2e/a_e2e_test.dart');
    });

    test('selects nothing when it is given only options', () {
      final selection = selecting(['--plain-name=occluded', '--concurrency=2']);

      expect(selection.paths, isEmpty);
      expect(selection.plainNames, ['occluded']);
    });
  });

  group('selectors that ran no case', () {
    const a = 'test/e2e/a_e2e_test.dart';
    const b = 'test/e2e/b_e2e_test.dart';

    test('a file that ran nothing fails the run, naming it', () {
      final outcome = runIn(selecting([a, b]), {
        a: {'a runs': 'pass'},
      });

      expect(outcome.ok, isFalse);
      expect(outcome.diagnosis, contains(b));
      expect(outcome.diagnosis, contains('no case of it matched'));
      expect(outcome.diagnosis, isNot(contains('$a —')));
    });

    test('a file whose cases were all skipped fails the run, saying so', () {
      final outcome = runIn(selecting([a, b]), {
        a: {'a runs': 'pass'},
        b: {'b on macOS': 'skip', 'b also on macOS': 'skip'},
      });

      expect(outcome.ok, isFalse);
      expect(outcome.diagnosis, contains('$b — all 2 skipped'));
      expect(outcome.diagnosis, contains('not on this host'));
      expect(outcome.diagnosis, contains('this host cannot run'));
    });

    test('a directory is satisfied by any case under it', () {
      final outcome = runIn(selecting(['test/e2e/', 'test/other/']), {
        a: {'a runs': 'pass'},
      });

      expect(outcome.diagnosis, contains('test/other/'));
      expect(outcome.diagnosis, isNot(contains('test/e2e/ —')));
    });

    // Named without its trailing slash, `test/e2e` is a prefix of
    // `test/e2e_more/`, whose cases are not under it.
    test('a directory is not satisfied by a sibling its name prefixes', () {
      final selection = Selection.parse(
        ['test/e2e'],
        Uri.directory('/pkg'),
        isDirectory: (path) => path == '/pkg/test/e2e',
      );
      final outcome = runIn(selection, {
        'test/e2e_more/x_e2e_test.dart': {'x runs': 'pass'},
      });

      expect(outcome.ok, isFalse);
      expect(outcome.diagnosis, contains('test/e2e'));
    });

    test('a plain name whose cases were all skipped fails the run', () {
      // `--plain-name macOS` on Linux, next to a name that did find a case to
      // run: the one is not excused by the other.
      final outcome = runIn(selecting(['--plain-name=Chrome', '-N', 'macOS']), {
        a: {'Chrome renders': 'pass', 'macOS renders': 'skip'},
      });

      expect(outcome.ok, isFalse);
      expect(outcome.diagnosis, contains('--plain-name=macOS — all 1 skipped'));
      expect(outcome.diagnosis, isNot(contains('--plain-name=Chrome —')));
    });

    test('a name that matches no case is named', () {
      final outcome = runIn(selecting(['--name=reload.*twice']), {
        a: {'reload once': 'pass'},
      });

      expect(outcome.ok, isFalse);
      expect(outcome.diagnosis, contains('--name=reload.*twice'));
      expect(outcome.diagnosis, contains('no case name matches it'));
    });

    test('a name that is not a regular expression is named', () {
      final outcome = runIn(selecting(['--name=(reload']), {
        a: {'reload': 'pass'},
      });

      expect(outcome.diagnosis, contains('--name=(reload — not a regular'));
    });

    test('every selector having run a case is a pass', () {
      final outcome = runIn(selecting([a, b, '-N', 'runs', '--name', 'b']), {
        a: {'a runs': 'pass', 'a skipped': 'skip'},
        b: {'b runs': 'pass'},
      });

      expect(outcome.ok, isTrue);
      expect(outcome.diagnosis, isNull);
    });

    test('a failure is reported as the failure, not as a selector', () {
      final outcome = runIn(selecting([a, b]), {
        a: {'a fails': 'fail'},
      });

      expect(outcome.diagnosis, contains('1 test(s) failed'));
    });

    test('a run that selected nothing names the tags no one declares', () {
      final outcome = runIn(
        selecting([a, '--tags=androd', '-t', 'web && macos']),
        const {},
        declaredTags: {'e2e', 'android', 'web', 'macos'},
        exitCode: 79,
      );

      expect(outcome.diagnosis, contains('nothing was selected to run'));
      expect(outcome.diagnosis, contains('$a, --tags=androd'));
      expect(outcome.diagnosis, contains('--tags=androd — `androd` is not'));
      expect(outcome.diagnosis, isNot(contains('`web`')));
    });

    test('an all-skipped run lists the selectors that ran nothing', () {
      final outcome = runIn(selecting([a, '-N', 'macOS']), {
        a: {'macOS only': 'skip'},
      });

      expect(outcome.diagnosis, contains('not one test actually ran'));
      expect(outcome.diagnosis, contains('$a — all 1 skipped'));
      expect(outcome.diagnosis, contains('--plain-name=macOS — all 1 skipped'));
    });

    test('ok and diagnosis still agree with selectors in play', () {
      final selection = () => selecting([a, b]);
      final runs = <Outcome>[
        runIn(selection(), {
          a: {'x': 'pass'},
          b: {'y': 'pass'},
        }),
        runIn(selection(), {
          a: {'x': 'pass'},
        }),
        runIn(selection(), {
          a: {'x': 'pass'},
          b: {'y': 'skip'},
        }),
        runIn(selection(), {
          a: {'x': 'skip'},
          b: {'y': 'skip'},
        }),
        runIn(selection(), const {}),
      ];

      for (final outcome in runs) {
        expect(
          outcome.diagnosis == null,
          outcome.ok,
          reason: 'ok=${outcome.ok} but diagnosis=${outcome.diagnosis}',
        );
      }
    });
  });

  group('declaredTagsOf', () {
    test('reads the plain names under tags and nothing else', () {
      expect(
        declaredTagsOf([
          'concurrency: 1',
          '',
          'tags:',
          '  e2e:',
          '    timeout: 5m',
          '  # a comment:',
          '  app_builds:',
          '  "e2e && app_builds":',
          '    timeout: 30m',
          '  ios_sim:',
          'presets:',
          '  other:',
        ]),
        {'e2e', 'app_builds', 'ios_sim'},
      );
    });
  });
  group('Outcome.diagnosis', () {
    test(
      'a run whose only test failed names the failure, not the selection',
      () {
        // `passed` is empty here — every test that executed failed — and
        // reading that as "nothing ran" sends the reader off to check paths
        // and tags that are correct.
        final outcome = runOf({'the one test': 'fail'}, verdict: false);

        expect(outcome.executed, 1, reason: 'a failing test executed');
        expect(outcome.diagnosis, isNotNull);
        expect(outcome.diagnosis, contains('1 test(s) failed'));
        expect(outcome.diagnosis, contains('the one test'));
        expect(outcome.diagnosis, isNot(contains('nothing was selected')));
        expect(outcome.diagnosis, isNot(contains('--tags')));
      },
    );

    test('failures alongside skips are not reported as an all-skipped run', () {
      // The other branch: with `passed` empty and skips present, an all-skipped
      // message would claim nothing executed while a failure sits in the same
      // report.
      final outcome = runOf({
        'failing': 'fail',
        'skipped one': 'skip',
        'skipped two': 'skip',
      }, verdict: false);

      expect(outcome.executed, 1);
      expect(outcome.diagnosis, contains('1 test(s) failed'));
      expect(outcome.diagnosis, contains('failing'));
      expect(outcome.diagnosis, isNot(contains('not one test actually ran')));
    });

    test('nothing selected is still reported as nothing selected', () {
      // No events at all between the runner starting and its verdict.
      final outcome = runOf(const {}, exitCode: 79);

      expect(outcome.executed, 0);
      expect(outcome.diagnosis, contains('nothing was selected to run'));
      expect(outcome.diagnosis, contains('79'));
    });

    test('an all-skipped run is refused despite dart test exiting 0', () {
      // The hole this runner exists for: `dart test` calls this a pass.
      final outcome = runOf({'macOS only': 'skip', 'also macOS only': 'skip'});

      expect(outcome.executed, 0);
      expect(outcome.diagnosis, contains('not one test actually ran'));
      expect(outcome.diagnosis, contains('all 2 of them skipped'));
    });

    test('a truncated run is refused and counts failures as having run', () {
      // No `done` event: the runner died partway. The count quoted back must
      // be everything that executed, since the prefix is what the reader is
      // being told not to trust.
      final outcome = runOf(
        {'passing': 'pass', 'failing': 'fail'},
        verdict: null,
        exitCode: 255,
      );

      expect(outcome.diagnosis, contains('never reported a verdict'));
      expect(outcome.diagnosis, contains('2 test(s) that did run'));
    });

    test(
      'a failing verdict with no failing test is attributed to the runner',
      () {
        // A stray async error or a late teardown throws after the test's own
        // `testDone`, so the run fails with every test green.
        final outcome = runOf({'passing': 'pass'}, verdict: false);

        expect(outcome.diagnosis, contains('without a failing test'));
      },
    );

    test('a real pass has no diagnosis', () {
      final outcome = runOf({'passing': 'pass', 'skipped': 'skip'});

      expect(outcome.ok, isTrue);
      expect(outcome.diagnosis, isNull);
    });

    test('diagnosis is exactly the negation of ok', () {
      // The two are read by different callers — `report` prints the diagnosis,
      // `main` takes the exit status from `ok` — so a run that printed a
      // complaint and exited 0, or passed silently and exited 1, is reachable
      // the moment they drift apart.
      final cases = <Outcome>[
        runOf(const {}),
        runOf({'a': 'skip'}),
        runOf({'a': 'fail'}, verdict: false),
        runOf({'a': 'pass', 'b': 'fail'}, verdict: false),
        runOf({'a': 'pass'}, verdict: false),
        runOf({'a': 'pass'}, verdict: null),
        runOf({'a': 'pass'}),
        runOf({'a': 'pass', 'b': 'skip'}),
      ];

      for (final outcome in cases) {
        expect(
          (outcome.diagnosis == null),
          outcome.ok,
          reason: 'ok=${outcome.ok} but diagnosis=${outcome.diagnosis}',
        );
      }
    });
  });

  group('Outcome.summary', () {
    test('counts passed separately from failed', () {
      final outcome = runOf(
        {
          'passing': 'pass',
          'failing': 'fail',
          'skipped': 'skip',
        },
        verdict: false,
        exitCode: 1,
      );

      expect(
        outcome.summary,
        'e2e: 1 passed, 1 skipped, 1 failed (dart test exited 1)',
      );
    });
  });

  group('Outcome.consume', () {
    test('ignores hidden entries, which are file loads rather than tests', () {
      final outcome = Outcome();
      outcome.consume(
        json.encode({
          'type': 'testStart',
          'test': {'id': 1, 'name': 'loading test/e2e/agent_e2e_test.dart'},
        }),
      );
      outcome.consume(
        json.encode({
          'type': 'testDone',
          'testID': 1,
          'result': 'success',
          'hidden': true,
        }),
      );
      outcome.consume(json.encode({'type': 'done', 'success': true}));

      expect(outcome.executed, 0);
      expect(outcome.passed, isEmpty);
      expect(outcome.diagnosis, contains('nothing was selected to run'));
    });

    test('attaches a test\'s error events to its name', () {
      final outcome = Outcome();
      outcome.consume(
        json.encode({
          'type': 'testStart',
          'test': {'id': 1, 'name': 'the failing test'},
        }),
      );
      outcome.consume(
        json.encode({
          'type': 'error',
          'testID': 1,
          'error': 'Expected: <2>\n  Actual: <1>',
          'stackTrace': 'test/e2e/some_e2e_test.dart 12:5',
        }),
      );
      outcome.consume(
        json.encode({
          'type': 'testDone',
          'testID': 1,
          'result': 'failure',
          'hidden': false,
        }),
      );
      outcome.consume(json.encode({'type': 'done', 'success': false}));

      // Without this the failure reduces to a name — less than the default
      // reporter gives, at the one moment it matters most.
      expect(outcome.diagnosis, contains('Expected: <2>'));
      expect(outcome.diagnosis, contains('some_e2e_test.dart'));
    });

    test('tolerates non-JSON and malformed lines without counting them', () {
      // The runner's stdout carries human text on a version-solving wall, and
      // the stream is usually about to stop; swallowing it as an event would
      // turn a diagnosable failure into a silent one.
      final outcome = Outcome();
      outcome.consume('Because flutter_bazel_dev_tool depends on dwds …');
      outcome.consume('{not json at all');
      outcome.consume(json.encode({'type': 'done', 'success': true}));

      expect(outcome.executed, 0);
      expect(outcome.diagnosis, contains('nothing was selected to run'));
    });
  });

  /// A skip listed by name alone says a platform did not run and nothing about
  /// why — and "why" is the entire content of a skip. Both shapes the reporter
  /// uses to carry a reason are covered.
  group('Outcome.skipReport', () {
    /// A run of one test skipped at declaration time, the way a `skip:` on a
    /// group arrives: a reason in `testStart` metadata, then a `print` event
    /// repeating it with a `Skip: ` prefix.
    Outcome declarationSkip(String reason) {
      final outcome = Outcome();
      outcome.consume(
        json.encode({
          'type': 'testStart',
          'test': {
            'id': 1,
            'name': 'Android e2e renders',
            'metadata': {'skip': true, 'skipReason': reason},
          },
        }),
      );
      outcome.consume(
        json.encode({
          'type': 'print',
          'testID': 1,
          'messageType': 'skip',
          'message': 'Skip: $reason',
        }),
      );
      outcome.consume(
        json.encode({
          'type': 'testDone',
          'testID': 1,
          'result': 'success',
          'skipped': true,
          'hidden': false,
        }),
      );
      return outcome;
    }

    test('a declared skip is listed with the reason it declared', () {
      final outcome = declarationSkip('no Android device attached');
      expect(outcome.skipReport, [
        'e2e: skipped — Android e2e renders — no Android device attached',
      ]);
    });

    // `markTestSkipped` has no metadata to carry a reason — the test was not
    // declared skipped — so the print event is the only place it exists.
    test('a runtime skip is listed with the reason it printed', () {
      final outcome = Outcome();
      outcome.consume(
        json.encode({
          'type': 'testStart',
          'test': {'id': 1, 'name': 'web renders'},
        }),
      );
      outcome.consume(
        json.encode({
          'type': 'print',
          'testID': 1,
          'messageType': 'skip',
          'message': 'Chrome is not installed',
        }),
      );
      outcome.consume(
        json.encode({
          'type': 'testDone',
          'testID': 1,
          'result': 'success',
          'skipped': true,
          'hidden': false,
        }),
      );
      expect(outcome.skipReport, [
        'e2e: skipped — web renders — Chrome is not installed',
      ]);
    });

    test('a skip that gave no reason is still listed', () {
      // `skip: true` with no string. Nothing to add, and dropping the line
      // would hide the skip entirely.
      expect(runOf({'a test': 'skip'}).skipReport, ['e2e: skipped — a test']);
    });

    test('a test that merely printed is not treated as skipped', () {
      final outcome = Outcome();
      outcome.consume(
        json.encode({
          'type': 'testStart',
          'test': {'id': 1, 'name': 'macOS renders'},
        }),
      );
      outcome.consume(
        json.encode({
          'type': 'print',
          'testID': 1,
          'messageType': 'print',
          'message': 'building…',
        }),
      );
      outcome.consume(
        json.encode({
          'type': 'testDone',
          'testID': 1,
          'result': 'success',
          'skipped': false,
          'hidden': false,
        }),
      );
      expect(outcome.skipReport, isEmpty);
      expect(outcome.passed, ['macOS renders']);
    });
  });
}
