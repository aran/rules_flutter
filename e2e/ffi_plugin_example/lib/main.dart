import 'package:flutter/material.dart';
import 'package:multiply_plugin/multiply_plugin.dart';

void main() {
  final result = MultiplyPlugin.multiply(3, 4);

  runApp(MyApp(result: result));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, required this.result});

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
