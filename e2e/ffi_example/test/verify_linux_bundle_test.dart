/// Verifies the Linux bundle has the expected structure,
/// including the native shared library with the correct filename, and that a
/// code asset that links another finds it beside it in `lib/`, by a runpath
/// of `$ORIGIN` and none of the build tree's paths, as a library that
/// Flutter's build hooks link does; and so does a `native_deps` library that
/// links another.
library;

import 'dart:io';

import 'package:rules_flutter_e2e_testing/desktop_bundle.dart';
import 'package:rules_flutter_e2e_testing/elf.dart';

void main() {
  final bundle = LinuxBundle.fromRunfiles('ffi_linux')..checkStandardLayout();
  final check = bundle.check
    ..exists(
      'Native-asset lib libadd.so',
      bundle.lib('libadd.so'),
      nonEmpty: true,
    )
    ..exists(
      'native_deps lib libmul.so',
      bundle.lib('libmul.so'),
      nonEmpty: true,
    )
    ..exists(
      'curated code-asset lib libsqlite3.so',
      bundle.lib('libsqlite3.so'),
      nonEmpty: true,
    )
    ..exists(
      'combined code-asset lib libcounter.so',
      bundle.lib('libcounter.so'),
      nonEmpty: true,
    )
    ..exists(
      'prebuilt code-asset lib libnegate.so',
      bundle.lib('libnegate.so'),
      nonEmpty: true,
    );
  // The app serves both packages' ids from `libcounter.so`, so the standalone
  // libraries the packages declare for themselves stay out.
  for (final name in ['libcounter_a.so', 'libcounter_b.so']) {
    check.absent('replaced code asset $name', bundle.lib(name));
  }
  // `pick`'s link hook keeps the library of the `Op` the app constructs and
  // drops the other, which neither the bundle nor its manifest carries.
  check
    ..exists(
      'code asset the link hook kept, libpick_kept.so',
      bundle.lib('libpick_kept.so'),
      nonEmpty: true,
    )
    ..absent(
      'code asset the link hook dropped, libpick_dropped.so,',
      bundle.lib('libpick_dropped.so'),
    )
    ..nativeAssetsManifest(
      bundle.flutterAssets,
      shipped: ['package:pick/kept', 'package:add_plugin/add_plugin.dart'],
      dropped: ['package:pick/dropped'],
    );
  final top = ElfImage.fromFile(File(bundle.lib('libchain_top.so')))
      .dynamicNames();
  check
    ..expect(
      'libchain_top.so links libchain_base.so',
      condition: top != null && top.needed.contains('libchain_base.so'),
      detail: '${top?.needed}',
    )
    ..expect(
      r'libchain_top.so finds what it links in lib/, by a runpath of $ORIGIN',
      condition: top?.runpath == r'$ORIGIN',
      detail: '${top?.runpath}',
    );
  // The same of two `native_deps` libraries, which always ship.
  final linkedTop = ElfImage.fromFile(
    File(bundle.lib('liblinked_top.so')),
  ).dynamicNames();
  check
    ..exists(
      'native_deps lib liblinked_base.so',
      bundle.lib('liblinked_base.so'),
      nonEmpty: true,
    )
    ..expect(
      'liblinked_top.so links liblinked_base.so',
      condition:
          linkedTop != null && linkedTop.needed.contains('liblinked_base.so'),
      detail: '${linkedTop?.needed}',
    )
    ..expect(
      r'liblinked_top.so finds what it links in lib/, by a runpath of $ORIGIN',
      condition: linkedTop?.runpath == r'$ORIGIN',
      detail: '${linkedTop?.runpath}',
    );
  bundle.finish();
}
