// A Dart-only plugin a `flutter_test` depends on is registered before the
// test's `main` runs, as under `flutter test`: the host platform's
// `dartPluginClass`, and only that one, once.
import 'dart:io';

import 'package:dart_plugin/dart_plugin.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Read before any test body runs.
  final registeredBeforeMain = List<String>.of(registrations);

  test("the host platform's Dart plugin class is registered before main", () {
    expect(registeredBeforeMain, [Platform.operatingSystem]);
  });
}
