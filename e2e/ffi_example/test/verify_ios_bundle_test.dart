/// Verifies the iOS simulator app's code-asset frameworks link each other by
/// the names they ship under: `chain_top` links `chain_base`, which it
/// recorded as `@rpath/libchain_base.dylib` when it was linked and which ships
/// as `chain_base.framework/chain_base`, so the bundle must have rewritten
/// the link, as `flutter build ios` does. `linked_top`, the one `native_deps`
/// library the app names, links `linked_base` through `dynamic_deps` in the
/// same way, and `linked_base` ships beside it. The rewrite comes before
/// signing, so the bundle's signature must still hold.
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
  final linkedTop = MachO('$frameworks/linked_top.framework/linked_top');
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
    )
    ..exists(
      'linked_base, which linked_top links, ships',
      '$frameworks/linked_base.framework/linked_base',
    )
    ..expect(
      "linked_top links linked_base by linked_base's framework",
      condition: linkedTop.linkedLibraries().contains(
        '@rpath/linked_base.framework/linked_base',
      ),
      detail: '${linkedTop.linkedLibraries()}',
    );
  CodeSignature(bundle.path).checkValid(bundle.check);
  bundle
    ..finish(
      'The iOS app links its native libraries to each other by their '
      'frameworks, and its signature holds.',
    )
    ..dispose();
}
