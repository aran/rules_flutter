/// Verifies the macOS .app bundle has the expected structure,
/// including the native dylib with the correct filename.
///
/// rules_apple outputs a .zip — we extract it to a temp dir and verify.
library;

import 'package:rules_flutter_e2e_testing/macos_bundle.dart';

void main() {
  final bundle = MacosBundle.fromRunfiles(
    'ffi_macos.zip',
    appName: 'ffi_macos',
  );
  try {
    final check = bundle.check
      ..exists(
        'Native-asset dylib libadd.dylib exists',
        '${bundle.frameworks}/libadd.dylib',
      )
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
      )
      ..exists(
        'code-asset dylib libsub.dylib exists',
        '${bundle.frameworks}/libsub.dylib',
      )
      ..exists(
        'curated code-asset dylib libsqlite3.dylib exists',
        '${bundle.frameworks}/libsqlite3.dylib',
      )
      ..exists(
        'combined code-asset dylib libcounter.dylib exists',
        '${bundle.frameworks}/libcounter.dylib',
      )
      ..exists(
        'prebuilt code-asset dylib libnegate.dylib exists',
        '${bundle.frameworks}/libnegate.dylib',
      );
    // The app serves both packages' ids from `libcounter.dylib`, so the
    // standalone libraries the packages declare for themselves stay out.
    for (final name in ['libcounter_a.dylib', 'libcounter_b.dylib']) {
      check.absent('replaced code asset $name', '${bundle.frameworks}/$name');
    }
    // `pick`'s link hook keeps the library of the `Op` the app constructs
    // and drops the other, which neither the bundle nor its manifest carries.
    check
      ..exists(
        'code asset the link hook kept, libpick_kept.dylib, exists',
        '${bundle.frameworks}/libpick_kept.dylib',
      )
      ..absent(
        'code asset the link hook dropped, libpick_dropped.dylib,',
        '${bundle.frameworks}/libpick_dropped.dylib',
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
