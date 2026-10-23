/// Tests for the shared gcloud helpers.
///
/// [waitForSsh] shells out to the real `gcloud` CLI, so this drives the
/// retry loop against a VM name that cannot exist: every probe fails, the
/// wait reports each failure, and the deadline throw is what the test
/// asserts on.
import 'package:test/test.dart';

import 'gcloud.dart';

void main() {
  group('waitForSsh', () {
    test(
      'a VM that never answers reports each probe, then times out',
      () async {
        // Seconds in the test, minutes in production: the probe fails at
        // once (no such VM, and no gcloud project in a test sandbox), the
        // catch reports it and sleeps once, and the expired deadline throws.
        // The timeout cannot be milliseconds — the loop is entered after a
        // synchronous stderr write, and under a test runner that write alone
        // can outlast a millisecond deadline, skipping the loop entirely.
        await expectLater(
          waitForSsh(
            'definitely-not-a-vm-qc-devtool',
            timeout: const Duration(seconds: 5),
          ),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'toString',
              contains('Timeout waiting for'),
            ),
          ),
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
