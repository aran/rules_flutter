/// Verifies the add-to-app xcframeworks of a release build carry the code
/// asset `pick`'s link hook kept, with its dSYM, and not the one it dropped,
/// that the Swift package lists the same, and that a code asset linking
/// another links it by the install name it ships with. Each is a versioned
/// framework, `@rpath/<name>.framework/<name>`, as `flutter build
/// macos-framework` makes it.
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
      '$release/$kept.xcframework/macos-arm64/dSYMs/$kept.framework.dSYM/'
          'Contents/Resources/DWARF/$kept',
    )
    ..absent(
      'the dropped $dropped.xcframework',
      '$release/$dropped.xcframework',
    );
  final package = File('$release/Package.swift').readAsStringSync();
  String binary(String name) =>
      '$release/$name.xcframework/macos-arm64/$name.framework/Versions/A/$name';
  final topBinary = binary(top);
  final baseBinary = binary(base);
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
      '$base ships as @rpath/$base.framework/$base',
      condition: baseName == '@rpath/$base.framework/$base',
      detail: baseName,
    )
    ..expect(
      '$top links $base by the install name it ships with',
      condition: links.contains('\t$baseName '),
      detail: links,
    )
    ..finish('The add-to-app layout ships what the link hook kept.');
}
