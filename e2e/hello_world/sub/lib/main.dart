/// Subpackage app for the asset-key proof.
///
/// Lives in Bazel package `//sub`, so its own `assets/notice.txt` must be
/// keyed relative to that package (`assets/notice.txt`, not
/// `sub/assets/notice.txt`), while the `//brand` dependency's asset is keyed
/// `packages/brand/assets/brand.txt`. The app never runs in the test; the
/// bundle's `flutter_assets/` tree is what the host test asserts on.
library;

import 'package:brand/brand.dart';
import 'package:flutter/material.dart';

/// Entry point of the subpackage app.
void main() {
  runApp(const SubApp());
}

/// Minimal app showing the first-party brand title.
class SubApp extends StatelessWidget {
  /// Creates the subpackage app widget.
  const SubApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(title: brandTitle, home: Text(brandTitle));
  }
}
