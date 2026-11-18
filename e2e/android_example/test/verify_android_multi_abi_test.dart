/// Verifies an APK of two ABIs names the code assets of each in its one
/// native-assets manifest, as `flutter build apk` writes it: each ABI's build
/// knows only its own target (`android_arm64`, `android_arm`), and the APK has
/// one `flutter_assets` for every ABI, so a manifest of one target alone
/// leaves the other ABI's devices with no code assets.
library;

import 'dart:convert';

import 'package:rules_flutter_e2e_testing/apk.dart';

/// The native-assets target of each ABI directory under `lib/`.
const _targets = {
  'arm64-v8a': 'android_arm64',
  'armeabi-v7a': 'android_arm',
  'x86_64': 'android_x64',
};

void main() {
  final apk = Apk.fromRunfiles('app.apk', prefix: 'multi_abi_apk');
  final manifest = apk.file('assets/flutter_assets/NativeAssetsManifest.json');
  final sections =
      (json.decode(manifest.readAsStringSync()) as Map)['native-assets'] as Map;
  apk.check.expect(
    'the APK holds the libraries of arm64-v8a and armeabi-v7a',
    condition: apk.abis.join(' ') == 'arm64-v8a armeabi-v7a',
    detail: '${apk.abis}',
  );
  for (final abi in apk.abis) {
    final target = _targets[abi];
    final section = sections[target] as Map?;
    apk.check
      ..expect(
        'the manifest has a section for $abi ($target)',
        condition: section != null,
        detail: '${sections.keys}',
      )
      ..expect(
        'the $abi section names the code asset in lib/$abi/libcounter.so',
        condition:
            section != null &&
            '${section['package:count_a/count_a']}' ==
                '[absolute, libcounter.so]' &&
            apk.file('lib/$abi/libcounter.so').existsSync(),
        detail: '$section',
      );
  }
  apk
    ..finish(
      'The APK of two ABIs names the code assets of each in its manifest.',
    )
    ..dispose();
}
