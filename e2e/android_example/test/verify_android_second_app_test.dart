/// Verifies that `:second_app`, which ships this package's `flutter create`
/// runner under an application id of its own, names launch activities its
/// dex actually defines.
///
/// `MainActivity.kt` declares `package com.example.flutterapp`, which the app
/// gives as its `namespace`; the manifest names `.MainActivity`. Android
/// separates the code's package from the application id, and a relative class
/// name belongs to the former. Resolved against the application id instead, the
/// APK names `com.example.flutterapp.second.MainActivity`, which does not
/// exist, and the app dies on launch with a ClassNotFoundException.
library;

// This script's diagnostics are its product: it reports what it found in
// the built artifact to the bazel test log, so `print` is its output
// channel rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:io';

import 'apk_contents.dart';

const _applicationId = 'com.example.flutterapp.second';

void main() {
  final testSrcDir = Platform.environment['TEST_SRCDIR'];
  final testWorkspace = Platform.environment['TEST_WORKSPACE'];
  if (testSrcDir == null || testWorkspace == null) {
    stderr.writeln('Missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }
  final apkPath = '$testSrcDir/$testWorkspace/second_app.apk';

  final tmpDir = Directory.systemTemp.createTempSync('android_second_app');
  try {
    final unzip = Process.runSync('unzip', [
      '-q',
      apkPath,
      'AndroidManifest.xml',
      'classes*.dex',
      '-d',
      tmpDir.path,
    ]);
    if (unzip.exitCode != 0) {
      stderr.writeln('Failed to extract $apkPath: ${unzip.stderr}');
      exit(1);
    }

    final elements = manifestElements(
      File('${tmpDir.path}/AndroidManifest.xml').readAsBytesSync(),
    );
    final package = elements.first.attributes['package'];
    final activities = [
      for (final e in elements)
        if (e.name == 'activity') e.attributes['name']!,
    ];
    final classes = {
      for (final dex in tmpDir.listSync().whereType<File>())
        if (dex.path.endsWith('.dex')) ...definedClassDescriptors(dex),
    };

    print('Application id: $package');
    var failed = package != _applicationId;
    if (failed) {
      stderr.writeln('FAIL: expected application id $_applicationId');
    }
    if (activities.isEmpty) {
      stderr.writeln('FAIL: the manifest declares no activity');
      failed = true;
    }
    for (final activity in activities) {
      final descriptor = 'L${activity.replaceAll('.', '/')};';
      if (classes.contains(descriptor)) {
        print('OK: activity $activity is defined in dex');
      } else {
        stderr.writeln(
          'FAIL: the manifest names activity $activity, which no dex '
          'defines. Dex activities: '
          '${classes.where((c) => c.endsWith('Activity;')).join(', ')}',
        );
        failed = true;
      }
    }
    if (failed) exit(1);
  } finally {
    tmpDir.deleteSync(recursive: true);
  }
}
