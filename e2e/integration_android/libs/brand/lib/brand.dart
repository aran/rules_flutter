/// First-party brand package for the subpackage asset-key proof.
///
/// `//apps/sub:sub_test` depends on this library for its `assets/brand.txt`,
/// which the Android bundle must key `packages/brand/assets/brand.txt` per
/// flutter_tools.
library;

/// Title shown by the sub app; referencing it proves the package import.
const String brandTitle = 'Sub Brand';
