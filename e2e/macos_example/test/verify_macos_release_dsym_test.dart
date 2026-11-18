/// Property: a release macOS build leaves dSYMs that symbolicate the shipped
/// `App.framework/App`, the engine, `FlutterMacOS.framework`, and a native
/// library bundled beside them, `libsub.dylib`, as `flutter build macos
/// --release` does.
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

void main() {
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
    bundle.finish(
      'dSYMs match the App, FlutterMacOS and libsub.dylib binaries.',
    );
  } finally {
    bundle.dispose();
  }
}
