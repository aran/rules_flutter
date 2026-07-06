import 'dart:io';

import 'package:add_plugin/add_plugin.dart';
import 'package:flutter/material.dart';

void main() {
  // Compute via the native FFI library and record the outcome to a file in the
  // app sandbox. The iOS-simulator e2e test reads it back via
  // `simctl get_app_container` — a deterministic runtime signal that the
  // bundled native-asset framework actually loaded and the call returned
  // (more reliable than scraping iOS log output). Success is
  // `ffi_example_result 3 + 4 = 7`; a load failure records the error instead.
  String marker;
  int result;
  try {
    result = add(3, 4);
    marker = 'ffi_example_result 3 + 4 = $result';
  } catch (e) {
    result = -1;
    marker = 'ffi_example_error $e';
  }
  try {
    File('${Directory.systemTemp.path}/ffi_result.txt')
        .writeAsStringSync(marker);
  } catch (_) {
    // Sandbox temp dir unavailable — the test will time out and report it.
  }
  debugPrint(marker);

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
