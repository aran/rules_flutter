import 'package:add_plugin/add_plugin.dart';
import 'package:flutter/material.dart';

void main() {
  final result = add(3, 4);

  runApp(MyApp(result: result));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, required this.result});

  final int result;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FFI Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.orange),
        useMaterial3: true,
      ),
      home: Scaffold(
        appBar: AppBar(
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
          title: const Text('FFI Example'),
        ),
        body: Center(
          child: Text(
            '3 + 4 = $result',
            style: const TextStyle(fontSize: 32),
          ),
        ),
      ),
    );
  }
}
