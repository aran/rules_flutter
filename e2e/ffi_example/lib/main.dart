import 'dart:io';

import 'package:add_plugin/add_plugin.dart';
import 'package:flutter/material.dart';
import 'package:mul_plugin/mul_plugin.dart';

void main() {
  // Exercise both native-library mechanisms and record the outcome to a file
  // in the app's temp dir: `add` binds via `@Native` asset-id resolution
  // (Native Assets pipeline), `mul` via classic `DynamicLibrary.open` at its
  // conventional path (`native_deps` pipeline). The runtime e2e tests (iOS
  // simulator, macOS) read the file back — a deterministic signal that both
  // libraries actually loaded and the calls returned (more reliable than
  // scraping log output). Success is
  // `ffi_example_result add(3,4)=7 mul(3,4)=12`; a load failure records the
  // error instead.
  String marker;
  int addResult;
  int mulResult;
  try {
    addResult = add(3, 4);
    mulResult = mul(3, 4);
    marker = 'ffi_example_result add(3,4)=$addResult mul(3,4)=$mulResult';
  } catch (e) {
    addResult = -1;
    mulResult = -1;
    marker = 'ffi_example_error $e';
  }
  try {
    File('${Directory.systemTemp.path}/ffi_result.txt')
        .writeAsStringSync(marker);
  } catch (_) {
    // Temp dir unavailable — the test will time out and report it.
  }
  debugPrint(marker);

  runApp(MyApp(addResult: addResult, mulResult: mulResult));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, required this.addResult, required this.mulResult});

  final int addResult;
  final int mulResult;

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
            '3 + 4 = $addResult\n3 × 4 = $mulResult',
            style: const TextStyle(fontSize: 32),
          ),
        ),
      ),
    );
  }
}
