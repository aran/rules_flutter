// How `flutter_test` applies Bazel's test protocol to a `RemoteListener` tree.
import 'package:test/test.dart';

import '../bazel_test_protocol.dart';

/// A test entry, named in full as `package:test` names it.
Map<String, dynamic> _test(String name) => {'type': 'test', 'name': name};

Map<String, dynamic> _group(
  String name,
  List<Map<String, dynamic>> entries, {
  bool fixtures = false,
}) => {
  'type': 'group',
  'name': name,
  'entries': entries,
  if (fixtures) 'setUpAll': _test('$name (setUpAll)'),
  if (fixtures) 'tearDownAll': _test('$name (tearDownAll)'),
};

/// A suite shaped like `bazel_protocol_test.dart` in e2e/hello_world, with a
/// fourth test so three shards split it unevenly.
Map<String, dynamic> _suite() => _group('', [
  _group('outer', [
    _test('outer runs its setUpAll once'),
    _test('outer ignores a per-test timeout'),
    _group('outer inner', [
      _test('outer inner is reached through both groups'),
    ]),
  ], fixtures: true),
  _test('a widget test is a case like any other'),
]);

List<String> _names(Map<String, dynamic>? group) => [
  for (final entry in group?['entries'] as List? ?? const [])
    if ((entry as Map)['type'] == 'group')
      ..._names(entry.cast<String, dynamic>())
    else
      entry['name'] as String,
];

void main() {
  group('TestSelection', () {
    test('keeps the whole tree when nothing narrows it', () {
      final selection = TestSelection.fromEnvironment(const {});
      expect(selection.narrows, isFalse);
      expect(_names(selection.select(_suite())), hasLength(4));
    });

    test('--test_filter is a regular expression over the full name', () {
      final selection = TestSelection.fromEnvironment(const {
        'TESTBRIDGE_TEST_ONLY': r'inner|widget\b',
      });
      expect(_names(selection.select(_suite())), [
        'outer inner is reached through both groups',
        'a widget test is a case like any other',
      ]);
    });

    test('a group the filter empties goes, fixtures and all', () {
      final selection = TestSelection.fromEnvironment(const {
        'TESTBRIDGE_TEST_ONLY': 'widget',
      });
      final selected = selection.select(_suite())!;
      expect(selected['entries'], hasLength(1));
      expect(_names(selected), ['a widget test is a case like any other']);
    });

    test('a group that keeps a test keeps its fixtures', () {
      final selection = TestSelection.fromEnvironment(const {
        'TESTBRIDGE_TEST_ONLY': 'setUpAll once',
      });
      final outer = (selection.select(_suite())!['entries'] as List).single;
      expect((outer as Map)['setUpAll'], isNotNull);
      expect(outer['tearDownAll'], isNotNull);
    });

    test('a filter that matches nothing leaves no tree', () {
      final selection = TestSelection.fromEnvironment(const {
        'TESTBRIDGE_TEST_ONLY': 'no such test',
      });
      expect(selection.narrows, isTrue);
      expect(selection.select(_suite()), isNull);
    });

    test(
      'shards split the tests into contiguous shares, each exactly once',
      () {
        final shards = [
          for (var i = 0; i < 3; i++)
            _names(
              TestSelection.fromEnvironment({
                'TEST_TOTAL_SHARDS': '3',
                'TEST_SHARD_INDEX': '$i',
              }).select(_suite()),
            ),
        ];
        expect(shards.expand((s) => s), _names(_suite()));
        expect(shards.map((s) => s.length), [1, 2, 1]);
      },
    );

    test('a shard with no share has no tree, and passes', () {
      final selection = TestSelection.fromEnvironment(const {
        // Four tests over eight shards: shard 0 takes [0, 1), shard 1 the
        // empty [1, 1).
        'TEST_TOTAL_SHARDS': '8',
        'TEST_SHARD_INDEX': '1',
      });
      expect(selection.narrows, isTrue);
      expect(selection.select(_suite()), isNull);
    });

    test('the filter applies before the shards split what is left', () {
      final shards = [
        for (var i = 0; i < 2; i++)
          _names(
            TestSelection.fromEnvironment({
              'TESTBRIDGE_TEST_ONLY': 'outer',
              'TEST_TOTAL_SHARDS': '2',
              'TEST_SHARD_INDEX': '$i',
            }).select(_suite()),
          ),
      ];
      expect(shards.expand((s) => s), hasLength(3));
      expect(shards.expand((s) => s), everyElement(contains('outer')));
    });

    test('refuses a filter that is not a regular expression', () {
      expect(
        () =>
            TestSelection.fromEnvironment(const {'TESTBRIDGE_TEST_ONLY': '('}),
        throwsFormatException,
      );
    });

    test('refuses shard numbers Bazel would not send', () {
      expect(
        () => TestSelection.fromEnvironment(const {
          'TEST_TOTAL_SHARDS': 'two',
          'TEST_SHARD_INDEX': '0',
        }),
        throwsFormatException,
      );
      expect(
        () => TestSelection.fromEnvironment(const {
          'TEST_TOTAL_SHARDS': '2',
          'TEST_SHARD_INDEX': '2',
        }),
        throwsFormatException,
      );
    });
  });

  group('junitXml', () {
    final xml = junitXml([
      TestCaseResult.passed(
        'adds <two> & "two"',
        const Duration(milliseconds: 1500),
        'printed\n',
      ),
      TestCaseResult.failed(
        'fails',
        Duration.zero,
        '',
        failureType: 'TestFailure',
        message: 'Expected: 1\nActual: 2',
        detail: 'TestFailure: Expected: 1\nActual: 2',
      ),
      TestCaseResult.failed(
        'throws',
        Duration.zero,
        '',
        failureType: 'StateError',
        message: 'bad state',
        detail: 'StateError: bad state',
      ),
      TestCaseResult.skipped('skipped'),
    ], suiteName: 'test/foo_test.dart');

    test('counts each outcome on the suite', () {
      expect(
        xml,
        contains(
          '<testsuite name="test/foo_test.dart" tests="4" failures="1" '
          'errors="1" skipped="1" time="1.500">',
        ),
      );
    });

    test('keeps a failed expectation apart from an error', () {
      expect(xml, contains('<failure message="Expected: 1">'));
      expect(xml, contains('<error message="bad state">'));
    });

    test('escapes names and carries what the case printed', () {
      expect(xml, contains('name="adds &lt;two&gt; &amp; &quot;two&quot;"'));
      expect(xml, contains('<system-out>printed\n</system-out>'));
      expect(xml, contains('<skipped/>'));
    });
  });
}
