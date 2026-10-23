// Entrypoint for `_web_font_fixture` in `flutter/tests/web_test.bzl`.
//
// Exercises:
// 1. `kDebugMode ? Icons.a : Icons.b` (in a dependency library `.kmod`) and
//    `kDebugMode ? Icons.c : Icons.d` (in the app entrypoint `.kmod`),
//    verifying both `fastbuild` and `opt` web builds keep `Icons.b` / `Icons.d`
//    and tree-shake `Icons.a` / `Icons.c`.
// 2. Font families (`Roboto` and `packages/cupertino_icons/CupertinoIcons`)
//    used only through `TextStyle(fontFamily: ...)` with zero `const IconData`
//    usages, verifying they ship whole (unsubsetted).
// 3. A font family (`packages/unused_icons/UnusedFamily`) where only a default
//    icon is reachable, verifying `font-subset` strips all unused glyphs.
import 'package:flutter/material.dart';
import 'package:icon_choice_lib/icon_choice.dart';

const IconData mainSelectedIcon = kDebugMode ? Icons.c : Icons.d;

const IconData bareIconsIcon = IconData(0xe047, fontFamily: 'Icons');
const IconData pkgIconsIcon = IconData(
  0xe145,
  fontFamily: 'Icons',
  fontPackage: 'custom_icons',
);

const TextStyle robotoTextStyle = TextStyle(fontFamily: 'Roboto');
const TextStyle cupertinoTextStyle = TextStyle(
  fontFamily: 'CupertinoIcons',
  package: 'cupertino_icons',
);

@pragma('vm:entry-point')
void main() {
  final keep = <Object?>[
    depSelectedIcon,
    mainSelectedIcon,
    bareIconsIcon,
    pkgIconsIcon,
    robotoTextStyle,
    cupertinoTextStyle,
    frameworkDefaultIcon,
  ];
  if (keep.isEmpty) {
    throw StateError('unreachable');
  }
}
