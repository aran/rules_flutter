/// Verifies the macOS .app bundle has the expected structure: each code
/// asset in a framework of its own, `<name>.framework/<name>` with its
/// `Resources/Info.plist`, under the install name
/// `@rpath/<name>.framework/<name>`, which the native-assets manifest names,
/// as `flutter build macos` wraps it; a `native_deps` library as itself.
///
/// rules_apple outputs a .zip — we extract it to a temp dir and verify.
library;

import 'dart:io';

import 'package:rules_flutter_e2e_testing/macos_bundle.dart';

String _otool(String flag, String binary) =>
    Process.runSync('otool', [flag, binary]).stdout as String;

void main() {
  final bundle = MacosBundle.fromRunfiles(
    'ffi_macos.zip',
    appName: 'ffi_macos',
  );
  try {
    final check = bundle.check
      ..exists(
        'native_deps dylib libmul.dylib exists',
        '${bundle.frameworks}/libmul.dylib',
      )
      ..exists(
        'native_deps dylib liblinked_top.dylib exists',
        '${bundle.frameworks}/liblinked_top.dylib',
      )
      // The app names only `linked_top`, which links `linked_base` through
      // `dynamic_deps`.
      ..exists(
        'liblinked_base.dylib, which liblinked_top.dylib links, exists',
        '${bundle.frameworks}/liblinked_base.dylib',
      );
    void framework(String what, String name) {
      final binary = '${bundle.frameworks}/$name.framework/$name';
      check
        ..exists('$what $name.framework', binary)
        ..exists(
          "$what $name.framework's Info.plist",
          '${bundle.frameworks}/$name.framework/Resources/Info.plist',
        );
      if (!File(binary).existsSync()) return;
      final installName = _otool('-D', binary).trim().split('\n').last;
      check.expect(
        '$name ships as @rpath/$name.framework/$name',
        condition: installName == '@rpath/$name.framework/$name',
        detail: installName,
      );
    }

    framework('Native-asset', 'add');
    framework('code-asset', 'sub');
    framework('curated code-asset', 'sqlite3');
    framework('combined code-asset', 'counter');
    framework('prebuilt code-asset', 'negate');
    // A code asset linking another links it by the install name it ships
    // with.
    framework('linking code-asset', 'chain_top');
    framework('linked code-asset', 'chain_base');
    final links = _otool(
      '-L',
      '${bundle.frameworks}/chain_top.framework/chain_top',
    );
    check.expect(
      'chain_top links chain_base by its framework',
      condition: links.contains('\t@rpath/chain_base.framework/chain_base '),
      detail: links,
    );
    for (final name in ['libadd.dylib', 'libsub.dylib', 'libcounter.dylib']) {
      check.absent(
        'code asset $name as a loose library',
        '${bundle.frameworks}/$name',
      );
    }
    // The app serves both packages' ids from `libcounter.dylib`, so the
    // standalone libraries the packages declare for themselves stay out.
    for (final name in ['counter_a', 'counter_b']) {
      check.absent(
        'replaced code asset $name',
        '${bundle.frameworks}/$name.framework',
      );
    }
    // `pick`'s link hook keeps the library of the `Op` the app constructs
    // and drops the other, which neither the bundle nor its manifest carries.
    framework('code asset the link hook kept,', 'pick_kept');
    check
      ..absent(
        'code asset the link hook dropped, pick_dropped,',
        '${bundle.frameworks}/pick_dropped.framework',
      )
      ..nativeAssetsManifest(
        bundle.flutterAssets,
        shipped: ['package:pick/kept', 'package:add_plugin/add_plugin.dart'],
        dropped: ['package:pick/dropped'],
      );
    bundle
      ..checkFlutterLayout(nib: null)
      ..finish('All macOS bundle verification checks passed.');
  } finally {
    bundle.dispose();
  }
}
