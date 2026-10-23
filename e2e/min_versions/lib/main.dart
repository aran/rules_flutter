import 'package:flutter/material.dart';

void main() {
  runApp(const MinVersionsApp());
}

/// Minimal app proving the minimum supported rules_apple/rules_android
/// floors build a working bundle on every native platform.
class MinVersionsApp extends StatelessWidget {
  /// Creates the app.
  const MinVersionsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Text('min_versions'),
    );
  }
}
