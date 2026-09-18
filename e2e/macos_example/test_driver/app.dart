import 'package:flutter/material.dart';

import 'banner.dart';

/// An entrypoint outside the package's `lib/`: the shape
/// `flutter run -t test_driver/app.dart` runs, and the one the dev loop has to
/// compile and hot reload under a URI with no `package:` form.
///
/// It imports a sibling by relative path so an edit to a second file outside
/// `lib/` is part of what a reload has to deliver.
void main() {
  runApp(const DriverApp());
}

/// The driver entrypoint's app: two labels, one from each file.
class DriverApp extends StatelessWidget {
  /// Creates the driver app.
  const DriverApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('driver entrypoint v1', key: ValueKey('e2e_driver_label')),
              Text(bannerText, key: ValueKey('e2e_driver_banner')),
            ],
          ),
        ),
      ),
    );
  }
}
