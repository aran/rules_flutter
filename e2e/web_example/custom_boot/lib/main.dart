import 'package:flutter/material.dart';

void main() {
  runApp(const CustomBootApp());
}

/// A minimal app: this package exists for the web templates beside it, not for
/// what it draws. It declares no assets, so the page it produces is exactly
/// what the substituted boot path loaded and nothing else.
///
/// Declaring no assets is also what makes this package the discriminator for
/// nested-package entrypoint resolution: the workspace root's app loads
/// `assets/message.txt`, so a run of this target that fetches that file is a
/// run of the wrong program. See `app_main_package_uri`.
class CustomBootApp extends StatelessWidget {
  /// Creates the custom-boot fixture's root widget.
  const CustomBootApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Custom Boot',
      home: Scaffold(
        body: Center(child: Text('custom boot ok')),
      ),
    );
  }
}
