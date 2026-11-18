/// Verifies that an add-to-app module gives each module of the Swift packages
/// its plugins depend on an xcframework of its own.
///
/// Usage: `add_to_app_swift_packages_test TARGET MODULE...`, `TARGET` a
/// `flutter_ios_xcframeworks` in the test's runfiles built in release, whose
/// application uses firebase_core, and each `MODULE` a module of the Swift
/// packages firebase_core depends on.
///
/// For each slice: every module is an xcframework, and a binary target of the
/// layout's Swift package; firebase_core's framework links FirebaseCore's
/// rather than carrying its code, which FirebaseCore's framework defines once;
/// and FirebaseCore's resource bundle is in its own framework, where its
/// `Bundle.module` looks.
library;

import 'dart:io';

import 'package:rules_flutter_e2e_testing/add_to_app.dart';
import 'package:rules_flutter_e2e_testing/mach_o.dart';

const _slices = ['ios-arm64', 'ios-arm64-simulator'];

/// A class of FirebaseCore's.
const _firApp = r'_OBJC_CLASS_$_FIRApp';

void main(List<String> args) {
  final [target, ...modules] = args;
  final release = '${exportXcframeworks(target)}/Release';
  final failures = <String>[];

  final package = File('$release/Package.swift').readAsStringSync();
  for (final module in modules) {
    if (!Directory('$release/$module.xcframework').existsSync()) {
      failures.add('$release has no $module.xcframework');
    }
    if (!package.contains(
      '.binaryTarget(name: "$module", path: "$module.xcframework")',
    )) {
      failures.add('Package.swift has no binary target of $module');
    }
  }

  for (final slice in _slices) {
    final plugin =
        '$release/firebase_core.xcframework/$slice/'
        'firebase_core.framework/firebase_core';
    final core =
        '$release/FirebaseCore.xcframework/$slice/'
        'FirebaseCore.framework';
    if (MachO(plugin).definitionsOf(_firApp) != 0) {
      failures.add('$plugin carries FirebaseCore');
    }
    final links = Process.runSync('otool', ['-L', plugin]).stdout.toString();
    if (!links.contains('@rpath/FirebaseCore.framework/FirebaseCore ')) {
      failures.add('$plugin does not link FirebaseCore.framework:\n$links');
    }
    if (MachO('$core/FirebaseCore').definitionsOf(_firApp) != 1) {
      failures.add('$core/FirebaseCore does not define $_firApp once');
    }
    if (MachO('$core/FirebaseCore').installName() !=
        '@rpath/FirebaseCore.framework/FirebaseCore') {
      failures.add('$core/FirebaseCore is not named as its framework');
    }
    if (!File(
      '$core/Firebase_FirebaseCore.bundle/PrivacyInfo.xcprivacy',
    ).existsSync()) {
      failures.add('$core has no Firebase_FirebaseCore.bundle');
    }
    if (!File('$core/Modules/module.modulemap').existsSync() ||
        !File('$core/Headers/FIRApp.h').existsSync()) {
      failures.add('$core has no module of its headers');
    }
  }

  if (failures.isNotEmpty) {
    stderr.writeln(failures.join('\n'));
    exit(1);
  }
  stdout.writeln(
    'Each Swift package module is an xcframework of its own, which '
    'firebase_core links.',
  );
}
