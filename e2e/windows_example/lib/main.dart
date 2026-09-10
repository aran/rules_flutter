import 'package:flutter/material.dart';

void main() {
  runApp(const MyApp());
}

/// Root widget of the Windows example: one screen, rendered by the Win32
/// runner that `flutter_windows_app` builds.
class MyApp extends StatelessWidget {
  /// Creates the Windows example's root widget.
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Windows Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: Scaffold(
        appBar: AppBar(
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
          title: const Text('Windows Example'),
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
