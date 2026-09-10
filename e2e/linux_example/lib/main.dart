import 'package:flutter/material.dart';

void main() {
  runApp(const MyApp());
}

/// Root widget of the Linux example: one screen, rendered by the GTK runner
/// that `flutter_linux_app` builds.
class MyApp extends StatelessWidget {
  /// Creates the Linux example's root widget.
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Linux Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: Scaffold(
        appBar: AppBar(
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
          title: const Text('Linux Example'),
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
