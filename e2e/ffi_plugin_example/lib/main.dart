import 'package:flutter/material.dart';
import 'package:multiply_plugin/multiply_plugin.dart';

void main() {
  final result = MultiplyPlugin.multiply(3, 4);

  runApp(MyApp(result: result));
}

/// Root widget of the FFI plugin example, which displays a product computed
/// by the bundled `multiply_plugin` native library.
class MyApp extends StatelessWidget {
  /// Creates the example's root widget showing [result].
  const MyApp({required this.result, super.key});

  /// The product returned by the plugin's native `multiply`.
  final int result;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FFI Plugin Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.purple),
        useMaterial3: true,
      ),
      home: Scaffold(
        appBar: AppBar(
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
          title: const Text('FFI Plugin Example'),
        ),
        body: Center(
          child: Text(
            '3 × 4 = $result',
            style: const TextStyle(fontSize: 32),
          ),
        ),
      ),
    );
  }
}
