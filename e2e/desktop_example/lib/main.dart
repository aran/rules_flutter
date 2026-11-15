import 'package:material_ui/material_ui.dart';

void main() {
  runApp(const MyApp());
}

/// Root widget of the desktop example: one screen, rendered by the runner of
/// whichever platform the app is built for (the GTK runner that
/// `flutter_linux_app` builds, or the Win32 one of `flutter_windows_app`).
class MyApp extends StatelessWidget {
  /// Creates the desktop example's root widget.
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Desktop Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: Scaffold(
        appBar: AppBar(
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
          title: const Text('Desktop Example'),
        ),
        body: const Center(
          child: Text(
            'Hello from rules_flutter!',
            style: TextStyle(fontSize: 32),
          ),
        ),
      ),
    );
  }
}
