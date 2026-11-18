/// Verifies that audio_session is built into each iOS app with the code its
/// `Package.swift` selects for the app, as `flutter build` builds it.
///
/// `audio_session` 0.1.x compiles in its record permission code unless
/// `AUDIO_SESSION_MICROPHONE` is 0 in the manifest's environment.
/// `:plugin_ios` sets no environment, so its binary carries that code;
/// `:no_microphone_ios` sets the variable to 0 in `swift_package_environment`,
/// so its binary leaves the code out.
library;

import 'package:rules_flutter_e2e_testing/ios_bundle.dart';
import 'package:rules_flutter_e2e_testing/mach_o.dart';

void main() {
  _check('plugin_ios.ipa', 'ios_plugin_test', microphone: true);
  _check('no_microphone_ios.ipa', 'ios_no_microphone_test', microphone: false);
}

void _check(String ipa, String prefix, {required bool microphone}) {
  final bundle = IosBundle.fromRunfiles(ipa, prefix: prefix);
  try {
    // A debug build may put the runner's code in a sibling `.debug.dylib`.
    final binaries = [for (final f in bundle.rootFiles) MachO(f.path)];
    bundle.check.expect(
      '$ipa carries audio_session',
      condition: binaries.any(
        (b) => b.hasSymbolContaining('DarwinAudioSession'),
      ),
    );
    bundle.check.expect(
      "$ipa ${microphone ? 'carries' : 'leaves out'} audio_session's "
      'record permission code',
      condition:
          binaries.any(
            (b) => b.hasSymbolContaining(
              '-[DarwinAudioSession flutterToRecordPermission:]',
            ),
          ) ==
          microphone,
    );
    bundle.finish('$ipa carries the audio_session code its manifest selects.');
  } finally {
    bundle.dispose();
  }
}
