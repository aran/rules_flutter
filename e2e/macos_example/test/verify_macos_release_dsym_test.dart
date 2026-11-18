/// Property: a release macOS build leaves dSYMs that symbolicate the shipped
/// `App.framework/App`, the engine, `FlutterMacOS.framework`, and a native
/// library bundled beside them, `libsub.dylib`, as `flutter build macos
/// --release` does.
///
/// With `--line-tables`, also that the library's dSYM has its line tables,
/// read from the object files the library was linked from, as `flutter build`
/// reads them. Only a build whose link keeps the library's debugging map has
/// them: `-c opt`. In `fastbuild`, Bazel's default `--strip=sometimes` strips
/// it at the link, and the dSYM holds the library's symbol table.
///
/// Built with `--apple_generate_dsym`, the flag a Bazel Apple developer turns
/// on to get dSYMs, the outputs hold a `.dSYM` whose UUID is each binary's. A
/// crash reporter matches reports to dSYMs by that UUID.
///
/// Run once for each `-c` that builds Flutter's release mode (see the BUILD
/// file).
library;

import 'package:rules_flutter_e2e_testing/apple_release.dart';
import 'package:rules_flutter_e2e_testing/macos_bundle.dart';

void main(List<String> args) {
  final lineTables = args.contains('--line-tables');
  final bundle = MacosBundle.fromRunfiles('app.zip', appName: 'Flutter App');
  try {
    final dsyms = runfilesDsyms();
    checkDsymMatches(
      bundle.check,
      '${bundle.frameworks}/App.framework/App',
      dsyms,
    );
    checkDsymMatches(
      bundle.check,
      '${bundle.frameworks}/FlutterMacOS.framework/Versions/A/FlutterMacOS',
      dsyms,
    );
    checkDsymMatches(bundle.check, '${bundle.frameworks}/libsub.dylib', dsyms);
    if (lineTables) {
      // `sub` is lines 3 to 5 of `native/sub.c`.
      checkDsymSourceLine(
        bundle.check,
        '${bundle.frameworks}/libsub.dylib',
        dsyms,
        symbol: '_sub',
        file: 'sub.c',
        lines: {3, 4},
      );
    }
    bundle.finish(
      'dSYMs match the App, FlutterMacOS and libsub.dylib binaries'
      "${lineTables ? ", and libsub.dylib's has its line table" : ''}.",
    );
  } finally {
    bundle.dispose();
  }
}
