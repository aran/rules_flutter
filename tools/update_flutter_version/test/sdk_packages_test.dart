import 'package:test/test.dart';

import '../sdk_packages.dart';

void main() {
  test('packages render as the sorted Starlark entry of versions.bzl', () {
    expect(
      renderPackages('3.47.9', ['integration_test', 'flutter', 'flutter_test']),
      '    "3.47.9": [\n'
      '        "flutter",\n'
      '        "flutter_test",\n'
      '        "integration_test",\n'
      '    ],\n',
    );
  });
}
