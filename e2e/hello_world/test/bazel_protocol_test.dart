// Bazel's test protocol, as `flutter_test` has to honour it.
//
// Run with no filter this whole suite passes, and each case says why it is
// here. `bazel_protocol_test` runs it as one shard, and
// `bazel_protocol_sharded_test` as three: Bazel 9 fails a sharded test whose
// runner never touches TEST_SHARD_STATUS_FILE.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  var setUpAllRuns = 0;

  group('outer', () {
    setUpAll(() => setUpAllRuns++);

    test('runs its setUpAll once', () {
      expect(setUpAllRuns, 1);
    });

    group('inner', () {
      test('is reached through both groups', () {
        expect(setUpAllRuns, 1);
      });
    });
  });

  testWidgets('a widget test is a case like any other', (tester) async {
    await tester.pumpWidget(const SizedBox());
    expect(find.byType(SizedBox), findsOneWidget);
  });
}
