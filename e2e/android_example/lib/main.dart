import 'package:android_example/native_add.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const MyApp());
}

/// Root widget of the Android example, which renders a sum computed by the
/// native library packaged into the APK.
class MyApp extends StatelessWidget {
  /// Creates the Android example's root widget.
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Android Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      home: Scaffold(
        appBar: AppBar(
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
          title: const Text('Android Example'),
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'Hello from Flutter Android!',
                style: TextStyle(fontSize: 32),
              ),
              Text(
                'native add(19, 23) = ${nativeAdd(19, 23)}',
                style: const TextStyle(fontSize: 24),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
