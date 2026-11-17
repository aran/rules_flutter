/// Verifies an Android app links only the implementation of a federated
/// plugin it registers.
///
/// `federated_app` depends on `fed` and on `fed_alt`, its second Android
/// implementation, so it registers `fed_alt`. `fed` depends on its default
/// implementation, `fed_android`, which reaches the app all the same:
/// `flutter build apk` compiles only the implementations its registrant
/// names, so `fed_android`'s code has no place in the APK.
library;

import 'package:rules_flutter_e2e_testing/apk.dart';
import 'package:rules_flutter_e2e_testing/bundle_check.dart';

void main() {
  final check = BundleCheck();
  final apk = Apk.fromRunfiles(
    'federated_opt.apk',
    prefix: 'federated_test',
    check: check,
  );
  try {
    final defined = apk.definedClasses();
    check
      ..expect(
        'the dex defines classes',
        condition: defined.isNotEmpty,
        detail: 'no class definitions parsed from dex files',
      )
      ..expect(
        'Lcom/example/fed_alt/FedAltPlugin; is in the dex (the chosen '
        'implementation)',
        condition: defined.contains('Lcom/example/fed_alt/FedAltPlugin;'),
        detail: 'the app registers fed_alt, but its code is missing',
      )
      ..expect(
        'Lcom/example/fed_android/FedAndroidPlugin; is not in the dex (the '
        'implementation passed over)',
        condition: !defined.contains(
          'Lcom/example/fed_android/FedAndroidPlugin;',
        ),
        detail:
            'the app registers fed_alt, but the code of fed_android, the '
            'implementation it passes over, is in the APK',
      );
  } finally {
    apk.dispose();
  }
  check.finish('\nThe APK carries the chosen implementation alone.');
}
