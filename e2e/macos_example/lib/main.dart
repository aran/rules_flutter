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
      title: 'macOS Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: Scaffold(
        appBar: AppBar(
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
          title: const Text('macOS Example'),
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '3 + 4 = $result',
                style: const TextStyle(fontSize: 32),
              ),
              // Renders the E2E_MESSAGE dart-define (empty without one).
              // dart_defines_e2e_test asserts the value before AND after a
              // hot reload — the reload must not lose the define.
              const Text(
                '${String.fromEnvironment('E2E_MESSAGE')} v1',
                key: ValueKey('e2e_define_label'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
