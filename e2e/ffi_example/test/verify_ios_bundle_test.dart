/// Verifies the iOS simulator app's code-asset frameworks link each other by
/// the names they ship under: `chain_top` links `chain_base`, which it
/// recorded as `@rpath/libchain_base.dylib` when it was linked and which ships
/// as `chain_base.framework/chain_base`, so the bundle must have rewritten
/// the link, as `flutter build ios` does. The rewrite comes before signing, so
/// the bundle's signature must still hold.
library;

import 'package:rules_flutter_e2e_testing/ios_bundle.dart';
import 'package:rules_flutter_e2e_testing/mach_o.dart';
import 'package:rules_flutter_e2e_testing/signing.dart';

void main() {
  final bundle = IosBundle.fromRunfiles(
    'ffi_ios.ipa',
    prefix: 'ffi_ios_bundle',
  );
  final frameworks = '${bundle.path}/Frameworks';
  final top = MachO('$frameworks/chain_top.framework/chain_top');
  final base = MachO('$frameworks/chain_base.framework/chain_base');
  bundle.check
    ..expect(
      'chain_base is named by its framework',
      condition: base.installName() == '@rpath/chain_base.framework/chain_base',
      detail: base.installName(),
    )
    ..expect(
      'chain_top is named by its framework',
      condition: top.installName() == '@rpath/chain_top.framework/chain_top',
      detail: top.installName(),
    )
    ..expect(
      "chain_top links chain_base by chain_base's framework",
      condition: top.linkedLibraries().contains(
        '@rpath/chain_base.framework/chain_base',
      ),
      detail: '${top.linkedLibraries()}',
    )
    ..expect(
      'chain_top links nothing by the name chain_base was linked as',
      condition: !top.linkedLibraries().any(
        (name) => name.contains('libchain_base'),
      ),
      detail: '${top.linkedLibraries()}',
    );
  CodeSignature(bundle.path).checkValid(bundle.check);
  bundle
    ..finish(
      'The iOS app links its code assets to each other by their frameworks, '
      'and its signature holds.',
    )
    ..dispose();
}
