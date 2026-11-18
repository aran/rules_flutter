/// Verifies a release iOS app for a device carries the framework of the code
/// asset `pick`'s link hook kept and not the one it dropped, which its
/// post-processor removed with the list it read, that the app's
/// `NativeAssetsManifest.json` names the same, and that its `dsyms` output
/// group holds the dSYM of the one it kept and not of the one it dropped.
library;

import 'package:rules_flutter_e2e_testing/ios_bundle.dart';
import 'package:rules_flutter_e2e_testing/runfiles_paths.dart';

void main() {
  final bundle = IosBundle.fromRunfiles(
    'ffi_ios_device.ipa',
    appName: 'ffi_ios_device',
  );
  final dsyms = requireRunfile(
    'ffi_ios_native_frameworks_shipped_dsyms',
    what: 'The dSYMs of the libraries the app ships',
  );
  bundle.check
    ..exists(
      'the kept pick_kept.framework',
      '${bundle.path}/Frameworks/pick_kept.framework/pick_kept',
    )
    ..exists(
      'a code asset no hook chose among, add.framework',
      '${bundle.path}/Frameworks/add.framework/add',
    )
    ..absent(
      'the dropped pick_dropped.framework',
      '${bundle.path}/Frameworks/pick_dropped.framework',
    )
    ..absent(
      'the list of frameworks to remove',
      '${bundle.path}/rules_flutter_dropped_frameworks.txt',
    )
    ..exists(
      'the dSYM of the kept pick_kept.framework',
      '$dsyms/pick_kept.framework.dSYM/Contents/Resources/DWARF/pick_kept',
    )
    ..absent(
      'the dSYM of the dropped pick_dropped.framework',
      '$dsyms/pick_dropped.framework.dSYM',
    )
    ..nativeAssetsManifest(
      '${bundle.path}/Frameworks/App.framework/flutter_assets',
      shipped: ['package:pick/kept'],
      dropped: ['package:pick/dropped'],
    );
  bundle.finish('The release iOS app ships what the link hook kept.');
}
