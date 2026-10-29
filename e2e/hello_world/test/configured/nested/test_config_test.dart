// Passes only if the suite ran through test/configured/flutter_test_config.dart,
// which flutter_test finds walking up from this file.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test("the directory's flutter_test_config.dart wraps the suite", () {
    expect(defaultTargetPlatform, TargetPlatform.fuchsia);
  });
}
