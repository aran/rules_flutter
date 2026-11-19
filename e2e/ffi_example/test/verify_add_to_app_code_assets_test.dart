/// Verifies the add-to-app xcframeworks of a release build carry the code
/// asset `pick`'s link hook kept, with its dSYM, and not the one it dropped,
/// that the Swift package lists the same, and that a code asset linking
/// another links it by the install name it ships with.
///
/// Arguments: the layout target, the kept and the dropped xcframework, then
/// the linking and the linked one, each named without `.xcframework`. The
/// layout is of macOS.
library;

import 'dart:io';

import 'package:rules_flutter_e2e_testing/bundle_check.dart';
import 'package:rules_flutter_e2e_testing/runfiles_paths.dart';

String _otool(String flag, String binary) =>
    Process.runSync('otool', [flag, binary]).stdout as String;

void main(List<String> args) {
  final [layout, kept, dropped, top, base] = args;
  final release = '${requireRunfile(layout, what: 'The layout')}/Release';
  final check = BundleCheck()
    ..exists('the kept $kept.xcframework', '$release/$kept.xcframework')
    ..exists(
      'the dSYM of the kept $kept',
      '$release/$kept.xcframework/macos-arm64/dSYMs/$kept.dylib.dSYM/'
          'Contents/Resources/DWARF/$kept.dylib',
    )
    ..absent(
      'the dropped $dropped.xcframework',
      '$release/$dropped.xcframework',
    );
  final package = File('$release/Package.swift').readAsStringSync();
  final topBinary = '$release/$top.xcframework/macos-arm64/$top.dylib';
  final baseBinary = '$release/$base.xcframework/macos-arm64/$base.dylib';
  final baseName = _otool('-D', baseBinary).trim().split('\n').last;
  final links = _otool('-L', topBinary);
  check
    ..expect(
      'Package.swift names $kept',
      condition: package.contains('.binaryTarget(name: "$kept"'),
      detail: package,
    )
    ..expect(
      'Package.swift leaves out $dropped',
      condition: !package.contains('"$dropped"'),
      detail: package,
    )
    ..expect(
      '$base ships as @rpath/$base.dylib',
      condition: baseName == '@rpath/$base.dylib',
      detail: baseName,
    )
    ..expect(
      '$top links $base by the install name it ships with',
      condition: links.contains('\t$baseName '),
      detail: links,
    )
    ..finish('The add-to-app layout ships what the link hook kept.');
}
