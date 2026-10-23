/// Subpackage app for the Android asset-key proof.
///
/// Lives in Bazel package `//apps/sub`, so its own `assets/sub.txt` must be
/// keyed relative to that package, while the `//libs/brand` dependency's
/// asset is keyed `packages/brand/assets/brand.txt`.
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
