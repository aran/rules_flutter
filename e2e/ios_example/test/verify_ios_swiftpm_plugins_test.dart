/// Verifies that an Apple plugin is built as its `Package.swift` says.
///
/// `flutter_qjs_next` 1.5.2 compiles QuickJS's C sources, and its manifest
/// sets `CONFIG_VERSION` to `"2026-06-04"`, which QuickJS prints in its memory
/// report, and, in debug builds only, `DUMP_LEAKS`, which compiles in the leak
/// report. The simulator build is a debug build, so the app carries the C
/// code, the version string and the leak report.
///
/// `video_player_avfoundation` 2.12.3's product is its Swift target, which
/// depends on an Objective-C target, which depends on a target for iOS and one
/// for macOS: the app carries the code of each target for iOS, and not the
/// macOS one's.
///
/// `firebase_core` 5.1.0's product is its Swift target and an Objective-C
/// target, and depends on `firebase-ios-sdk`, a remote Swift package that the
/// workspace's rules_swift_package_manager declares: the app carries both
/// targets and the Firebase SDK's code. The app's own Swift code
/// (`native_firebase`) uses FirebaseCore from the same repository, so the app
/// defines FirebaseCore's `FIRApp` once.
///
/// `libremidi_flutter` 0.9.0 is an FFI plugin (`ffiPlugin: true`, no plugin
/// class) whose Swift package compiles its C++: the app carries the functions
/// Dart looks up.
///
/// `script_phase_plugin` (a path package here) has a Package.swift and a
/// podspec that runs a script phase; Flutter builds it from the Package.swift,
/// and so the app carries its plugin class.
///
/// `swift6_plugin` (a path package) is `swift-tools-version: 6.0` and its
/// source does not compile in the Swift 5 language mode: the app carries it.
///
/// `ffi_dynamic_plugin` (a path package) is an FFI plugin whose product is
/// `.dynamic`: the app carries its C function.
///
/// `resource_plugin` (a path package) has a resource, `greeting.txt`, which
/// SwiftPM bundles as `resource_plugin_resource_plugin.bundle`: the app
/// carries the bundle and the file in it. Its Objective-C target
/// `resource_plugin_objc` has a resource of its own, which it reads through
/// `SWIFTPM_MODULE_BUNDLE`: the app carries that bundle and the class too.
library;

import 'dart:convert';
import 'dart:io';

import 'package:rules_flutter_e2e_testing/ios_bundle.dart';
import 'package:rules_flutter_e2e_testing/mach_o.dart';

void main() {
  final bundle = IosBundle.fromRunfiles(
    'swiftpm_plugins_app.ipa',
    prefix: 'ios_swiftpm_plugins_test',
  );
  try {
    final check = bundle.check;
    // A debug build may put the runner's code in a sibling `.debug.dylib`, so
    // look in every Mach-O file at the bundle root.
    final binaries = bundle.rootFiles;
    bool anyContains(String text) {
      final needle = ascii.encode(text);
      return binaries.any((f) => _contains(f.readAsBytesSync(), needle));
    }

    check
      ..expect(
        "a binary in the bundle carries QuickJS's C code",
        condition: binaries.any(
          (f) => MachO(f.path).hasSymbolContaining('JS_NewRuntime'),
        ),
      )
      ..expect(
        'QuickJS was compiled with CONFIG_VERSION from Package.swift',
        condition: anyContains('QuickJS memory usage -- 2026-06-04 version'),
      )
      ..expect(
        "QuickJS was compiled with Package.swift's debug-only DUMP_LEAKS",
        condition: anyContains('string leakage'),
      );
    for (final (target, symbol) in [
      ('video_player_avfoundation', 'VideoPlayerPlugin'),
      ('video_player_avfoundation_objc', 'FVPFrameUpdater'),
      ('video_player_avfoundation_ios', 'FVPNativeVideoView'),
      ('firebase_core', 'FLTFirebaseCorePlugin'),
      ('firebase_core_objc', 'FLTFirebasePluginRegistry'),
      ('firebase-ios-sdk FirebaseCore', 'FIRApp'),
      ('firebase-ios-sdk FirebaseInstallations', 'FIRInstallations'),
      ('libremidi_flutter', 'lrm_observer_new'),
      ('script_phase_plugin', 'ScriptPhasePlugin'),
      ('resource_plugin_objc', 'ResourcePluginObjC'),
      ('swift6_plugin', 'Swift6Plugin'),
      ('ffi_dynamic_plugin', 'ffi_dynamic_plugin_add'),
    ]) {
      check.expect(
        'a binary in the bundle carries the target $target',
        condition: binaries.any(
          (f) => MachO(f.path).hasSymbolContaining(symbol),
        ),
      );
    }
    check
      ..expect(
        "a binary in the bundle carries the app's own NativeFirebase",
        condition: binaries.any(
          (f) => MachO(f.path).hasSymbolContaining('NativeFirebase'),
        ),
      )
      ..expect(
        "the bundle defines FirebaseCore's FIRApp once",
        condition:
            binaries.fold<int>(
              0,
              (n, f) =>
                  n + MachO(f.path).definitionsOf(r'_OBJC_CLASS_$_FIRApp'),
            ) ==
            1,
      )
      ..expect(
        'no binary carries the macOS-only target',
        condition: !binaries.any(
          (f) => MachO(f.path).hasSymbolContaining('FVPCoreVideoDisplayLink'),
        ),
      )
      ..expect(
        "the app carries resource_plugin's resource bundle",
        condition: File(
          '${bundle.path}/resource_plugin_resource_plugin.bundle/greeting.txt',
        ).existsSync(),
      )
      ..expect(
        "the app carries resource_plugin_objc's resource bundle",
        condition: File(
          '${bundle.path}/resource_plugin_resource_plugin_objc.bundle/objc_greeting.txt',
        ).existsSync(),
      );
    bundle.finish('All Swift package plugin checks passed.');
  } finally {
    bundle.dispose();
  }
}

bool _contains(List<int> haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}
