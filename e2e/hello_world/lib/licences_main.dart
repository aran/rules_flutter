import 'package:material_ui/material_ui.dart';

void main() {
  runApp(const LicencesApp());
}

/// An app whose one screen opens the licence page, to see that the licences a
/// build bundles are what the framework lists.
class LicencesApp extends StatelessWidget {
  /// Creates the app.
  const LicencesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Licences',
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showLicensePage(
                context: context,
                applicationName: 'Licences',
              ),
              child: const Text('Licenses'),
            ),
          ),
        ),
      ),
    );
  }
}
