import 'package:flutter/material.dart';

void main() {
  runApp(const AndroidNoGoSdkApp());
}

/// Minimal app proving an Android consumer without its own `go_sdk` block
/// builds against rules_flutter's pinned Go SDK.
class AndroidNoGoSdkApp extends StatelessWidget {
  /// Creates the app.
  const AndroidNoGoSdkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Text('android_no_go_sdk'),
    );
  }
}
