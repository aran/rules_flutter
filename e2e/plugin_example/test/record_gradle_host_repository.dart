/// Records add_to_app_host/android/gradle_repository.json, the lock of
/// `@gradle_host_maven`:
/// `bazel run --config=deep //:record_gradle_host_repository`. See
/// `package:rules_flutter_e2e_testing/gradle_host_record.dart`.
library;

import 'dart:io';

import 'package:rules_flutter_e2e_testing/gradle_host_record.dart';

Future<void> main(List<String> args) async {
  exitCode = await recordGradleHostRepository(args);
}
