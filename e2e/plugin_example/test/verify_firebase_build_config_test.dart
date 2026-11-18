/// Verifies the `BuildConfig` fields FlutterFire's plugins read: that
/// `LIBRARY_VERSION` of firebase_core and cloud_firestore is the version
/// pubspec.lock locks each at, `+` as `-`, as Gradle gives it from the
/// plugin's pubspec.yaml, and `LIBRARY_NAME` is the one their
/// `user-agent.gradle` sets. Read from the dex of the APK of `firebase_app`.
library;

import 'dart:io';

import 'package:rules_flutter_e2e_testing/apk.dart';
import 'package:rules_flutter_e2e_testing/bundle_check.dart';
import 'package:rules_flutter_e2e_testing/runfiles_paths.dart';

/// The version pubspec.lock locks [package] at.
String lockedVersion(String lock, String package) {
  final entry = RegExp(
    '^  $package:\\n(?:    .*\\n)*?    version: "([^"]+)"',
    multiLine: true,
  ).firstMatch(lock);
  if (entry == null) {
    stderr.writeln('pubspec.lock has no version of $package');
    exit(1);
  }
  return entry.group(1)!;
}

void main() {
  final lock = File(
    requireRunfile('pubspec.lock', what: 'lock'),
  ).readAsStringSync();
  final check = BundleCheck();
  final apk = Apk.fromRunfiles(
    'firebase_android_arm64.apk',
    prefix: 'firebase_build_config_test',
    check: check,
  );
  try {
    final constants = apk.staticConstants();
    for (final (package, plugin, name) in [
      (
        'io/flutter/plugins/firebase/core',
        'firebase_core',
        'flutter-fire-core',
      ),
      (
        'io/flutter/plugins/firebase/firestore',
        'cloud_firestore',
        'flutter-fire-fst',
      ),
    ]) {
      final fields = constants['L$package/BuildConfig;'] ?? const {};
      final version = lockedVersion(lock, plugin).replaceAll('+', '-');
      check
        ..expect(
          '$plugin: BuildConfig.LIBRARY_VERSION is "$version"',
          condition: fields['LIBRARY_VERSION'] == version,
          detail: 'the class has ${fields.isEmpty ? 'no constants' : fields}',
        )
        ..expect(
          '$plugin: BuildConfig.LIBRARY_NAME is "$name"',
          condition: fields['LIBRARY_NAME'] == name,
          detail: 'the class has ${fields.isEmpty ? 'no constants' : fields}',
        );
    }
  } finally {
    apk.dispose();
  }
  check.finish('\nFlutterFire BuildConfig fields are what Gradle gives them.');
}
