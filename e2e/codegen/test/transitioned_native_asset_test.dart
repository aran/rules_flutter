// Proves a `flutter_test` built under a platform transition runs, and that
// its native code asset, built for the transitioned platform, loads.
import 'package:flutter_test/flutter_test.dart';
import 'package:native_add/native_add.dart';

void main() {
  test('the test was built for the transitioned platform', () {
    // Set only by the platform's flags, so false means the transition did
    // not take effect.
    expect(const bool.fromEnvironment('PLATFORM_TRANSITIONED'), isTrue);
  });

  test('a native code asset built for that platform binds', () {
    expect(nativeAdd(3, 4), 7);
  });
}
