// Runs every suite under test/configured/, as `flutter test` runs the nearest
// flutter_test_config.dart above a test.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.fuchsia);
  tearDown(() => debugDefaultTargetPlatformOverride = null);
  await testMain();
}
