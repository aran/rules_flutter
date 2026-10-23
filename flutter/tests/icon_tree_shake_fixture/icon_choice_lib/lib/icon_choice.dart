import 'package:flutter/material.dart';

/// Selected in a dependency `.kmod` so modular web icon tree-shaking must
/// compile dependency modules with `-Ddart.vm.product=true` and active web
/// renderer defines.
const IconData depSelectedIcon =
    (kDebugMode ||
        !(bool.fromEnvironment('FLUTTER_WEB_USE_SKWASM') ||
            bool.fromEnvironment('FLUTTER_WEB_USE_SKIA')))
    ? Icons.a
    : Icons.b;

@staticIconProvider
abstract final class UnusedFamilyIcons {
  static const IconData defaultGlyph = IconData(
    0xe5cd,
    fontFamily: 'UnusedFamily',
    fontPackage: 'unused_icons',
  );
  static const IconData unusedGlyph = IconData(
    0xe047,
    fontFamily: 'UnusedFamily',
    fontPackage: 'unused_icons',
  );
}

/// Simulates a framework widget (like `BackButtonIcon` / `CloseButtonIcon` in
/// `package:flutter/material.dart`) that references one default icon from an
/// icon font family even when the application does not pick icons from that
/// family directly. Upstream `const_finder` sees this reference and subsets
/// the family down to the referenced glyph.
const IconData frameworkDefaultIcon = UnusedFamilyIcons.defaultGlyph;
